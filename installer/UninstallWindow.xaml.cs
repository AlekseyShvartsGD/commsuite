using System;
using System.ComponentModel;
using System.IO;
using System.Windows;

namespace CommsuiteInstaller
{
    public partial class UninstallWindow : Window
    {
        private readonly string _dir;
        private bool _removing;
        private bool _done;

        public UninstallWindow(string dir)
        {
            InitializeComponent();
            _dir = dir;
            StatusText.Text = "Will remove: " + dir;
        }

        private void Cancel_Click(object sender, RoutedEventArgs e)
        {
            if (_removing) return;
            Close();
        }

        private async void Remove_Click(object sender, RoutedEventArgs e)
        {
            if (_done)
            {
                Close();
                return;
            }

            _removing = true;
            RemoveButton.IsEnabled = false;
            CancelButton.IsEnabled = false;
            RemoveButton.Content = "Removing…";

            var progress = new Progress<InstallProgress>(p =>
            {
                if (p.Fraction >= 0 && p.Fraction <= 1) Progress.Value = p.Fraction;
                if (!string.IsNullOrEmpty(p.Status)) StatusText.Text = p.Status;
            });

            try
            {
                await InstallEngine.UninstallAsync(_dir, progress, System.Threading.CancellationToken.None);
                _done = true;
                Progress.Value = 1;
                StatusText.Text = "Commsuite was removed.";
                RemoveButton.Content = "Close";
                RemoveButton.IsEnabled = true;
                RemoveButton.IsDefault = true;
                CancelButton.Visibility = Visibility.Collapsed;
            }
            catch (Exception ex)
            {
                MessageBox.Show(this, "Removal failed:\n" + ex.Message,
                    "Remove Commsuite", MessageBoxButton.OK, MessageBoxImage.Error);
                StatusText.Text = "Removal failed.";
                RemoveButton.Content = "Remove";
                RemoveButton.IsEnabled = true;
                CancelButton.IsEnabled = true;
            }
            finally
            {
                _removing = false;
            }
        }

        protected override void OnClosing(CancelEventArgs e)
        {
            if (_removing)
            {
                e.Cancel = true;
                return;
            }
            base.OnClosing(e);
        }
    }
}
