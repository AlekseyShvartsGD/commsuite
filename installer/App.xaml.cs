using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;

namespace CommsuiteInstaller
{
    public partial class App : Application
    {
        protected override void OnStartup(StartupEventArgs e)
        {
            base.OnStartup(e);
            var args = e.Args ?? new string[0];

            // Same command line contract as the old NSIS installer:
            //   /S              silent (used by the app's in-place auto-update)
            //   /D=<folder>     install folder (NSIS-style, silent installs)
            //   /uninstall      run the uninstaller that was copied to the
            //                   install folder
            bool uninstall = HasFlag(args, "/uninstall") || HasFlag(args, "--uninstall");
            bool silent = HasFlag(args, "/S") || HasFlag(args, "/silent")
                          || HasFlag(args, "--silent");
            string dirArg = ParseDirArg(args);

            var dir = dirArg ?? InstallEngine.ReadInstalledDir() ?? InstallEngine.DefaultInstallDir;

            if (uninstall)
            {
                if (dirArg == null && !Directory.Exists(dir))
                {
                    Shutdown(0);
                    return;
                }
                // A running exe cannot delete the folder it lives in, so when
                // this uninstaller is running from inside the install folder,
                // hand off to a copy in %TEMP% (which can remove the whole
                // folder, including the original Uninstall.exe) and exit.
                if (RelaunchFromTempIfNeeded(args, dir, silent))
                    return;
                if (silent)
                {
                    try
                    {
                        // Run on the thread pool and block: this happens before
                        // any window exists, and keeping the engine off the UI
                        // thread guarantees its awaits never need the (here,
                        // blocked) dispatcher to resume.
                        Task.Run(() => InstallEngine.UninstallAsync(dir, null, CancellationToken.None))
                            .GetAwaiter().GetResult();
                        Shutdown(0);
                    }
                    catch
                    {
                        Shutdown(1);
                    }
                    return;
                }
                var removeWindow = new UninstallWindow(dir);
                MainWindow = removeWindow;
                removeWindow.Show();
                return;
            }

            if (silent)
            {
                try
                {
                    // Thread pool + block (see the uninstall branch above).
                    Task.Run(() => InstallEngine.InstallAsync(dir, null, CancellationToken.None))
                        .GetAwaiter().GetResult();
                    // Silent installs come from the running app's auto-update,
                    // which has already exited; reopen the fresh build (the
                    // NSIS script did the same for ${Silent}).
                    InstallEngine.LaunchApp(dir);
                    Shutdown(0);
                }
                catch
                {
                    Shutdown(1);
                }
                return;
            }

            var setupWindow = new InstallerWindow(dir);
            MainWindow = setupWindow;
            setupWindow.Show();
        }

        private static bool HasFlag(IEnumerable<string> args, string flag) =>
            args.Any(a => a != null && a.Equals(flag, StringComparison.OrdinalIgnoreCase));

        /// <summary>
        /// When the uninstaller runs from inside the folder being removed, copy
        /// it to %TEMP% and start that copy with the same arguments (plus
        /// --from-temp); the copy is then free to delete the whole install
        /// folder, including the original Uninstall.exe. Returns true when the
        /// handoff happened (the caller must stop; this process is shutting
        /// down). Falls back to in-place removal if the copy cannot be made.
        /// </summary>
        private bool RelaunchFromTempIfNeeded(string[] args, string dir, bool silent)
        {
            if (HasFlag(args, "--from-temp")) return false;
            string self;
            try { self = Process.GetCurrentProcess().MainModule?.FileName; }
            catch { return false; }
            if (string.IsNullOrEmpty(self)) return false;

            var selfDir = Path.GetDirectoryName(self);
            var targetDir = Path.GetDirectoryName(Path.Combine(
                Path.GetFullPath(dir), "x")); // normalise trailing separators
            if (!string.Equals(selfDir?.TrimEnd('\\', '/'), targetDir?.TrimEnd('\\', '/'),
                    StringComparison.OrdinalIgnoreCase))
                return false;

            try
            {
                var tempDir = Path.Combine(Path.GetTempPath(), "commsuite-uninstall");
                Directory.CreateDirectory(tempDir);
                var tempExe = Path.Combine(tempDir, "Uninstall.exe");
                File.Copy(self, tempExe, overwrite: true);

                var parts = new List<string> { "--from-temp", "/uninstall", "/D=" + Quote(dir) };
                if (silent) parts.Add("/S");
                Process.Start(new ProcessStartInfo(tempExe, string.Join(" ", parts)));
                Shutdown(0);
                return true;
            }
            catch
            {
                return false; // best-effort: remove what we can in place
            }
        }

        private static string Quote(string value) =>
            value.IndexOf(' ') >= 0 ? "\"" + value + "\"" : value;

        /// <summary>NSIS-style folder override: "/D=C:\path" or "/D C:\path".</summary>
        private static string ParseDirArg(string[] args)
        {
            for (var i = 0; i < args.Length; i++)
            {
                var a = args[i];
                if (a == null) continue;
                if (a.StartsWith("/D=", StringComparison.OrdinalIgnoreCase))
                    return a.Substring(3).Trim().Trim('"');
                if ((a.Equals("/D", StringComparison.OrdinalIgnoreCase)
                     || a.Equals("--dir", StringComparison.OrdinalIgnoreCase))
                    && i + 1 < args.Length)
                    return args[i + 1].Trim().Trim('"');
            }
            return null;
        }
    }
}
