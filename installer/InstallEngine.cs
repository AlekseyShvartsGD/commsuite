using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Reflection;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.Win32;

namespace CommsuiteInstaller
{
    internal sealed class InstallProgress
    {
        public double Fraction { get; set; }
        public string Status { get; set; }
    }

    /// <summary>
    /// Everything the installer does, shared by the setup and uninstaller
    /// roles and by the GUI and silent modes. Mirrors the behaviour of the
    /// old NSIS script (dist/commsuite.nsi) one-for-one.
    /// </summary>
    internal static class InstallEngine
    {
        public const string ProductName = "Commsuite";
        public const string ExeName = "commsuite.exe";
        public const string SetupExeName = "CommsuiteSetup.exe";
        public const string UninstallExeName = "Uninstall.exe";

        private const string RunKeyPath = @"Software\Microsoft\Windows\CurrentVersion\Run";
        private const string UninstallKeyPath = @"SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Commsuite";
        private const string AppKeyPath = @"Software\Commsuite";

        /// <summary>Display version, e.g. "1.0.37" from the file version 1.0.37.0.</summary>
        public static string ProductVersion
        {
            get
            {
                var v = Assembly.GetExecutingAssembly()
                    .GetCustomAttribute<AssemblyFileVersionAttribute>()?.Version ?? "0.0.0.0";
                var parts = v.Split('.');
                return parts.Length >= 3 ? parts[0] + "." + parts[1] + "." + parts[2] : v;
            }
        }

        public static string DefaultInstallDir =>
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), ProductName);

        public static string PayloadResourceName => "Commsuite.Payload.zip";
        public static string UninstallerResourceName => "Commsuite.Uninstaller.exe";

        public static bool HasPayload =>
            Assembly.GetExecutingAssembly().GetManifestResourceNames().Contains(PayloadResourceName);

        /// <summary>Previous install location from HKLM, if any (NSIS InstallDirRegKey).</summary>
        public static string ReadInstalledDir()
        {
            try
            {
                using (var key = RegistryKey.OpenBaseKey(RegistryHive.LocalMachine, RegistryView.Registry64)
                    .OpenSubKey(AppKeyPath))
                {
                    var dir = key?.GetValue("InstallDir") as string;
                    if (!string.IsNullOrWhiteSpace(dir)) return dir.Trim().Trim('"');
                }
            }
            catch { }
            return null;
        }

        public static void KillRunningApp()
        {
            try
            {
                var running = Process.GetProcessesByName(Path.GetFileNameWithoutExtension(ExeName));
                foreach (var p in running)
                {
                    try { p.Kill(); } catch { }
                    try { p.WaitForExit(3000); } catch { }
                    p.Dispose();
                }
                // Fallback for orphaned/hung processes, same as NSIS nsExec taskkill.
                var psi = new ProcessStartInfo("taskkill", "/F /IM " + ExeName)
                {
                    CreateNoWindow = true,
                    UseShellExecute = false,
                    WindowStyle = ProcessWindowStyle.Hidden,
                };
                using (var t = Process.Start(psi))
                {
                    t?.WaitForExit(3000);
                }
                Thread.Sleep(400);
            }
            catch { }
        }

        public static async Task InstallAsync(string dir, IProgress<InstallProgress> progress,
            CancellationToken ct)
        {
            if (!HasPayload)
                throw new InvalidOperationException("This setup build carries no application payload.");
            dir = Path.GetFullPath(dir);
            progress?.Report(new InstallProgress { Fraction = 0.0, Status = "Stopping " + ExeName + "…" });
            KillRunningApp();

            progress?.Report(new InstallProgress { Fraction = 0.02, Status = "Extracting files…" });
            await Task.Run(() => ExtractPayload(dir, progress, ct), ct).ConfigureAwait(false);

            ct.ThrowIfCancellationRequested();

            // The uninstaller rides inside the setup exe; drop it in place so
            // Apps & Features has something to run later.
            progress?.Report(new InstallProgress { Fraction = 0.85, Status = "Writing uninstaller…" });
            await Task.Run(() => WriteEmbeddedResource(UninstallerResourceName,
                Path.Combine(dir, UninstallExeName)), ct).ConfigureAwait(false);

            progress?.Report(new InstallProgress { Fraction = 0.88, Status = "Registering application…" });
            await Task.Run(() =>
            {
                WriteUninstallEntry(dir);
                CreateShortcuts(dir);
                SeedAutostart(dir);
                CleanLegacyUpdaterArtifacts();
            }, ct).ConfigureAwait(false);

            progress?.Report(new InstallProgress { Fraction = 1.0, Status = "Done" });
        }

        public static async Task UninstallAsync(string dir, IProgress<InstallProgress> progress,
            CancellationToken ct)
        {
            dir = Path.GetFullPath(dir);
            progress?.Report(new InstallProgress { Fraction = 0.05, Status = "Stopping " + ExeName + "…" });
            await Task.Run(KillRunningApp, ct).ConfigureAwait(false);

            progress?.Report(new InstallProgress { Fraction = 0.2, Status = "Removing files…" });
            await Task.Run(() =>
            {
                if (Directory.Exists(dir))
                {
                    // NSIS RMDir /r /REBOOTOK; a few retries cover transient
                    // locks (search indexer, Defender, an exiting process).
                    for (var attempt = 0; attempt < 5; attempt++)
                    {
                        try
                        {
                            Directory.Delete(dir, recursive: true);
                            break;
                        }
                        catch (IOException) { Thread.Sleep(500); }
                        catch (UnauthorizedAccessException) { Thread.Sleep(500); }
                    }
                }
            }, ct).ConfigureAwait(false);

            progress?.Report(new InstallProgress { Fraction = 0.6, Status = "Removing shortcuts and registrations…" });
            await Task.Run(() =>
            {
                RemoveShortcuts();
                RemoveRegistry();
                RemoveAutostart();
                CleanLegacyUpdaterArtifacts();
            }, ct).ConfigureAwait(false);

            progress?.Report(new InstallProgress { Fraction = 1.0, Status = "Done" });
        }

        public static void LaunchApp(string dir)
        {
            var exe = Path.Combine(dir, ExeName);
            if (!File.Exists(exe)) return;
            Process.Start(new ProcessStartInfo(exe) { WorkingDirectory = dir, UseShellExecute = true });
        }

        // ----- payload -------------------------------------------------------

        private static void ExtractPayload(string dir, IProgress<InstallProgress> progress,
            CancellationToken ct)
        {
            using (var stream = Assembly.GetExecutingAssembly()
                .GetManifestResourceStream(PayloadResourceName))
            {
                if (stream == null)
                    throw new InvalidOperationException("Embedded payload is missing.");
                using (var zip = new ZipArchive(stream, ZipArchiveMode.Read))
                {
                    var entries = zip.Entries.Where(e => !string.IsNullOrEmpty(e.Name)).ToList();
                    long totalBytes = entries.Sum(e => e.Length);
                    if (totalBytes <= 0) totalBytes = 1;
                    long doneBytes = 0;
                    var written = new HashSet<string>(StringComparer.OrdinalIgnoreCase);

                    Directory.CreateDirectory(dir);
                    foreach (var entry in entries)
                    {
                        ct.ThrowIfCancellationRequested();
                        var target = Path.GetFullPath(Path.Combine(dir, entry.FullName.Replace('/', Path.DirectorySeparatorChar)));
                        if (!target.StartsWith(dir + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase))
                            throw new IOException("Payload entry escapes the install folder: " + entry.FullName);

                        Directory.CreateDirectory(Path.GetDirectoryName(target));
                        using (var input = entry.Open())
                        using (var output = File.Create(target))
                        {
                            input.CopyTo(output);
                        }
                        written.Add(target);

                        doneBytes += entry.Length;
                        progress?.Report(new InstallProgress
                        {
                            Fraction = 0.02 + 0.80 * Math.Min(1.0, doneBytes / (double)totalBytes),
                            Status = "Extracting " + entry.FullName,
                        });
                    }
                    PruneStaleFiles(dir, written);
                }
            }
        }

        /// <summary>
        /// Deletes files left over from a previous version so the install dir
        /// matches the payload exactly, but never touches the per-machine
        /// WebView2 browser state (the old NSIS script explicitly kept it out
        /// of the payload: shipping a stale profile breaks the in-app
        /// browser) or the uninstaller currently being rewritten.
        /// </summary>
        private static void PruneStaleFiles(string dir, HashSet<string> shipped)
        {
            string uninstaller;
            try { uninstaller = Path.GetFullPath(Path.Combine(dir, UninstallExeName)); }
            catch { uninstaller = null; }

            foreach (var file in Directory.EnumerateFiles(dir, "*", SearchOption.AllDirectories))
            {
                if (shipped.Contains(file)) continue;
                if (uninstaller != null && file.Equals(uninstaller, StringComparison.OrdinalIgnoreCase)) continue;
                if (file.IndexOf(".WebView2", StringComparison.OrdinalIgnoreCase) >= 0) continue;
                try { File.Delete(file); } catch { }
            }
            foreach (var sub in Directory.EnumerateDirectories(dir).ToList())
            {
                if (sub.IndexOf(".WebView2", StringComparison.OrdinalIgnoreCase) >= 0) continue;
                try
                {
                    if (!Directory.EnumerateFileSystemEntries(sub).Any())
                        Directory.Delete(sub);
                }
                catch { }
            }
        }

        private static void WriteEmbeddedResource(string resourceName, string target)
        {
            using (var input = Assembly.GetExecutingAssembly().GetManifestResourceStream(resourceName))
            {
                if (input == null)
                    throw new InvalidOperationException("Embedded resource missing: " + resourceName);
                using (var output = File.Create(target))
                {
                    input.CopyTo(output);
                }
            }
        }

        // ----- registry, shortcuts, autostart --------------------------------

        private static void WriteUninstallEntry(string dir)
        {
            var exe = Path.Combine(dir, UninstallExeName);
            var sizeKb = (int)Math.Min(int.MaxValue,
                new DirectoryInfo(dir).EnumerateFiles("*", SearchOption.AllDirectories)
                    .Sum(f => f.Length) / 1024);

            using (var baseKey = RegistryKey.OpenBaseKey(RegistryHive.LocalMachine, RegistryView.Registry64))
            {
                using (var appKey = baseKey.CreateSubKey(AppKeyPath))
                {
                    appKey?.SetValue("InstallDir", dir);
                }
                using (var key = baseKey.CreateSubKey(UninstallKeyPath))
                {
                    if (key == null)
                        throw new InvalidOperationException("Could not open the uninstall registry key.");
                    key.SetValue("DisplayName", ProductName);
                    key.SetValue("DisplayVersion", ProductVersion);
                    key.SetValue("Publisher", ProductName);
                    key.SetValue("DisplayIcon", Path.Combine(dir, ExeName));
                    key.SetValue("UninstallString", "\"" + exe + "\" /uninstall");
                    key.SetValue("QuietUninstallString", "\"" + exe + "\" /uninstall /S");
                    key.SetValue("InstallLocation", dir);
                    key.SetValue("EstimatedSize", sizeKb, RegistryValueKind.DWord);
                    key.SetValue("NoModify", 1, RegistryValueKind.DWord);
                    key.SetValue("NoRepair", 1, RegistryValueKind.DWord);
                }
            }
        }

        private static void RemoveRegistry()
        {
            try
            {
                using (var baseKey = RegistryKey.OpenBaseKey(RegistryHive.LocalMachine, RegistryView.Registry64))
                {
                    baseKey.DeleteSubKeyTree(AppKeyPath, throwOnMissingSubKey: false);
                    baseKey.DeleteSubKeyTree(UninstallKeyPath, throwOnMissingSubKey: false);
                }
            }
            catch { }
        }

        private static void CreateShortcuts(string dir)
        {
            var exe = Path.Combine(dir, ExeName);
            var programs = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData),
                "Microsoft", "Windows", "Start Menu", "Programs", ProductName);
            Directory.CreateDirectory(programs);
            CreateShortcut(Path.Combine(programs, ProductName + ".lnk"), exe, dir);
            CreateShortcut(Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory),
                ProductName + ".lnk"), exe, dir);
        }

        private static void CreateShortcut(string linkPath, string target, string workingDir)
        {
            var shellType = Type.GetTypeFromProgID("WScript.Shell");
            if (shellType == null) return;
            dynamic shell = Activator.CreateInstance(shellType);
            try
            {
                dynamic lnk = shell.CreateShortcut(linkPath);
                lnk.TargetPath = target;
                lnk.WorkingDirectory = workingDir;
                lnk.IconLocation = target + ",0";
                lnk.Description = ProductName;
                lnk.Save();
            }
            catch { }
            finally
            {
                (shell as IDisposable)?.Dispose();
            }
        }

        private static void RemoveShortcuts()
        {
            var programs = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData),
                "Microsoft", "Windows", "Start Menu", "Programs", ProductName);
            try
            {
                if (Directory.Exists(programs)) Directory.Delete(programs, recursive: true);
            }
            catch { }
            try
            {
                var desktopLnk = Path.Combine(
                    Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory),
                    ProductName + ".lnk");
                if (File.Exists(desktopLnk)) File.Delete(desktopLnk);
            }
            catch { }
        }

        /// <summary>Start with Windows, hidden in the system tray (HKCU, same as NSIS).</summary>
        private static void SeedAutostart(string dir)
        {
            using (var key = Registry.CurrentUser.CreateSubKey(RunKeyPath))
            {
                key?.SetValue(ProductName, "\"" + Path.Combine(dir, ExeName) + "\" --background");
            }
        }

        private static void RemoveAutostart()
        {
            try
            {
                using (var key = Registry.CurrentUser.OpenSubKey(RunKeyPath, writable: true))
                {
                    key?.DeleteValue(ProductName, throwOnMissingValue: false);
                }
            }
            catch { }
        }

        /// <summary>
        /// The scheduled-task auto-updater was removed (it killed the running
        /// app mid-session); drop its leftovers so old installs stop carrying
        /// them, exactly like the NSIS script did.
        /// </summary>
        private static void CleanLegacyUpdaterArtifacts()
        {
            try
            {
                var psi = new ProcessStartInfo("schtasks", "/delete /f /tn CommsuiteAutoUpdater")
                {
                    CreateNoWindow = true,
                    UseShellExecute = false,
                    WindowStyle = ProcessWindowStyle.Hidden,
                };
                using (var t = Process.Start(psi))
                {
                    t?.WaitForExit(3000);
                }
            }
            catch { }
            try
            {
                var local = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
                File.Delete(Path.Combine(local, ProductName, "pending-update.json"));
                File.Delete(Path.Combine(local, ProductName, "last-updated.json"));
            }
            catch { }
            try
            {
                var temp = Path.Combine(
                    Environment.GetFolderPath(Environment.SpecialFolder.Windows), "Temp", "commsuite");
                File.Delete(Path.Combine(temp, "auto-update.ps1"));
                File.Delete(Path.Combine(temp, "create-updater-task.ps1"));
                if (Directory.Exists(temp)) Directory.Delete(temp);
            }
            catch { }
        }
    }
}
