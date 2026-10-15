using System;
using System.ComponentModel;
using System.IO;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using Forms = System.Windows.Forms;

namespace CommsuiteInstaller
{
    public partial class InstallerWindow : Window
    {
        private bool _installing;
        private bool _done;

        public InstallerWindow(string installDir)
        {
            InitializeComponent();
            VersionText.Text = "Version " + InstallEngine.ProductVersion;
            FolderBox.Text = installDir;
        }

        private void Browse_Click(object sender, RoutedEventArgs e)
        {
            using (var dialog = new Forms.FolderBrowserDialog())
            {
                dialog.Description = "Choose the folder Commsuite will be installed to.";
                dialog.ShowNewFolderButton = true;
                try
                {
                    if (Directory.Exists(FolderBox.Text))
                        dialog.SelectedPath = FolderBox.Text;
                }
                catch { }
                if (dialog.ShowDialog() == Forms.DialogResult.OK)
                    FolderBox.Text = dialog.SelectedPath;
            }
        }

        private void Cancel_Click(object sender, RoutedEventArgs e)
        {
            if (_installing) return; // files are being written; keep it simple and safe
            Close();
        }

        private async void MainButton_Click(object sender, RoutedEventArgs e)
        {
            if (_done)
            {
                Close();
                return;
            }

            var dir = (FolderBox.Text ?? string.Empty).Trim().Trim('"');
            if (dir.Length == 0)
            {
                MessageBox.Show(this, "Choose a folder to install Commsuite to.",
                    "Commsuite Setup", MessageBoxButton.OK, MessageBoxImage.Warning);
                return;
            }
            try
            {
                dir = Path.GetFullPath(dir);
            }
            catch
            {
                MessageBox.Show(this, "\"" + dir + "\" is not a valid folder path.",
                    "Commsuite Setup", MessageBoxButton.OK, MessageBoxImage.Warning);
                return;
            }

            _installing = true;
            SetBusyUI();

            var progress = new Progress<InstallProgress>(p =>
            {
                if (p.Fraction >= 0 && p.Fraction <= 1) Progress.Value = p.Fraction;
                if (!string.IsNullOrEmpty(p.Status)) StatusText.Text = p.Status;
            });

            try
            {
                await InstallEngine.InstallAsync(dir, progress, CancellationToken.None);
                SetDoneUI();
            }
            catch (Exception ex)
            {
                MessageBox.Show(this, "Installation failed:\n" + ex.Message,
                    "Commsuite Setup", MessageBoxButton.OK, MessageBoxImage.Error);
                StatusText.Text = "Installation failed.";
                SetReadyUI();
            }
            finally
            {
                _installing = false;
            }
        }

        private void SetBusyUI()
        {
            FolderBox.IsEnabled = false;
            BrowseButton.IsEnabled = false;
            CancelButton.IsEnabled = false;
            MainButton.IsEnabled = false;
            MainButton.Content = "Installing…";
            StatusText.Text = "Installing…";
        }

        private void SetReadyUI()
        {
            FolderBox.IsEnabled = true;
            BrowseButton.IsEnabled = true;
            CancelButton.IsEnabled = true;
            MainButton.IsEnabled = true;
            MainButton.Content = "Install";
        }

        private void SetDoneUI()
        {
            _done = true;
            Progress.Value = 1;
            StatusText.Text = "Commsuite was installed successfully.";
            LaunchBox.Visibility = Visibility.Visible;
            CancelButton.Visibility = Visibility.Collapsed;
            MainButton.Content = "Close";
            MainButton.IsEnabled = true;
            MainButton.IsDefault = true;
            MainButton.IsCancel = true;
        }

        protected override void OnClosing(CancelEventArgs e)
        {
            if (_installing)
            {
                e.Cancel = true;
                return;
            }
            if (_done && LaunchBox.IsChecked == true)
            {
                var dir = Path.GetFullPath(FolderBox.Text.Trim().Trim('"'));
                InstallEngine.LaunchApp(dir);
            }
            base.OnClosing(e);
        }
    }
}
