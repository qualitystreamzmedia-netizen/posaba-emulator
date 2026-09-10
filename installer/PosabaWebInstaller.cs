using System;
using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Net;
using System.Reflection;
using System.Threading;
using System.Windows.Forms;
using Microsoft.Win32;

// Posaba Android Emulator - web installer / uninstaller.
//
//   Install Posaba.exe            download the bundle, extract, set up shortcuts
//   (exe name starts "Uninstall") | --uninstall | --quiet : remove
//
// The download is a single zip pulled from the GitHub release. Unsigned -
// SmartScreen will show "More info -> Run anyway".

static class PosabaWebInstaller
{
    const string AppName    = "Posaba Android Emulator";
    const string RegKey     = @"Software\Microsoft\Windows\CurrentVersion\Uninstall\PosabaEmulator";
    const string FolderName = "PosabaEmulator";
    const string StartExe   = "Start Posaba.exe";
    const string UninstExe  = "Uninstall Posaba.exe";

    const string BUNDLE_URL =
        "https://github.com/qualitystreamzmedia-netizen/posaba-emulator/releases/download/v1/PosabaEmulator.zip";

    static Form _form;
    static ProgressBar _bar;
    static Label _msg;
    static WebClient _wc;

    [STAThread]
    static void Main(string[] args)
    {
        Application.EnableVisualStyles();
        ServicePointManager.SecurityProtocol =
            SecurityProtocolType.Tls12 | SecurityProtocolType.Tls11 | SecurityProtocolType.Tls;

        string self = Path.GetFileName(Assembly.GetExecutingAssembly().Location);
        bool uninstall = args.Any(a => a.Equals("--uninstall", StringComparison.OrdinalIgnoreCase)
                                    || a.Equals("--quiet", StringComparison.OrdinalIgnoreCase))
                         || self.StartsWith("Uninstall", StringComparison.OrdinalIgnoreCase);

        if (uninstall) { RunUninstall(args.Any(a => a.Equals("--quiet", StringComparison.OrdinalIgnoreCase))); return; }
        RunInstall();
    }

    // ---- install --------------------------------------------------------

    static void RunInstall()
    {
        string target = null;
        while (true)
        {
            using (var fbd = new FolderBrowserDialog
            {
                Description = "Choose where to install " + AppName + "  (a \"" + FolderName +
                              "\" folder is made inside).\r\n" +
                              "Use a local folder - NOT OneDrive, Dropbox or Program Files.",
                ShowNewFolderButton = true,
                SelectedPath = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
            })
            {
                if (fbd.ShowDialog() != DialogResult.OK) return;
                string why = BadLocation(fbd.SelectedPath);
                if (why != null)
                {
                    MessageBox.Show(why + "\r\n\r\nGood choices: your Downloads folder, or a new " +
                        "folder you\r\nmake on the C: drive (for example  C:\\Apps).",
                        AppName, MessageBoxButtons.OK, MessageBoxIcon.Warning);
                    continue;
                }
                target = Path.Combine(fbd.SelectedPath, FolderName);
            }
            break;
        }
        Directory.CreateDirectory(target);

        BuildForm("Installing " + AppName + "...");
        var t = new Thread(() =>
        {
            string zip = null;
            try
            {
                zip = EnsureZip(BUNDLE_URL);
                Status("Extracting...");
                ExtractFlatten(zip, target);
                try { File.Delete(zip); } catch { }
                Finish(target);
            }
            catch (Exception ex)
            {
                bool locky = ex is UnauthorizedAccessException || ex is IOException;
                string extra = locky
                    ? "\r\n\r\nThis usually means the folder is locked by cloud sync " +
                      "(OneDrive / Dropbox)\r\nor needs administrator rights. Install into your " +
                      "Downloads folder\r\nor a new folder on C: instead."
                    : "";
                // keep the downloaded zip so a retry doesn't re-download 1 GB
                _form.Invoke((Action)(() =>
                {
                    MessageBox.Show(_form, "Install failed:\r\n\r\n" + ex.Message + extra, AppName,
                        MessageBoxButtons.OK, MessageBoxIcon.Error);
                    Application.Exit();
                }));
            }
        }) { IsBackground = true };
        _form.Shown += (s, e) => t.Start();
        Application.Run(_form);
    }

    // Reject cloud-synced folders (sync locks files mid-extract and would upload
    // the whole ~3 GB bundle) and protected system folders, and check we can write.
    static string BadLocation(string path)
    {
        string p;
        try { p = Path.GetFullPath(path); } catch { return "That path is not valid."; }
        string low = p.ToLowerInvariant();

        string[] synced = { "onedrive", "dropbox", "google drive", "\\my drive",
                            "\\box\\", "\\box sync", "icloud", "creative cloud files" };
        foreach (var s in synced)
            if (low.Contains(s))
                return "That folder is inside a cloud-sync folder (" + s.Trim('\\') + ").\r\n" +
                       "Sync locks files while uploading, which breaks the install.";

        foreach (var ev in new[] { "OneDrive", "OneDriveCommercial", "OneDriveConsumer" })
            if (UnderOrIs(low, Environment.GetEnvironmentVariable(ev)))
                return "That folder is inside OneDrive.";

        foreach (var sf in new[] { Environment.SpecialFolder.ProgramFiles,
                                   Environment.SpecialFolder.ProgramFilesX86,
                                   Environment.SpecialFolder.Windows })
            if (UnderOrIs(low, Environment.GetFolderPath(sf)))
                return "That is a protected system folder (it needs administrator rights).";

        try
        {
            Directory.CreateDirectory(p);
            string probe = Path.Combine(p, ".posaba_write_test");
            File.WriteAllText(probe, "ok");
            File.Delete(probe);
        }
        catch { return "This folder can't be written to (try Downloads, or a folder you make on C:)."; }

        return null;
    }

    static bool UnderOrIs(string lowFullPath, string baseDir)
    {
        if (string.IsNullOrEmpty(baseDir)) return false;
        string b = baseDir.ToLowerInvariant().TrimEnd('\\');
        return lowFullPath == b || lowFullPath.StartsWith(b + "\\");
    }

    // Use an already-downloaded %TEMP%\PosabaEmulator.zip if it is the right size.
    static string EnsureZip(string url)
    {
        string zip = Path.Combine(Path.GetTempPath(), "PosabaEmulator.zip");
        long remote = RemoteSize(url);
        if (remote > 0 && File.Exists(zip) && new FileInfo(zip).Length == remote)
        {
            Status("Using the copy already downloaded...");
            if (_form != null) _form.BeginInvoke((Action)(() => _bar.Value = 100));
            return zip;
        }
        Download(url, zip, "Downloading...");
        return zip;
    }

    static long RemoteSize(string url)
    {
        try
        {
            var r = (HttpWebRequest)WebRequest.Create(url);
            r.Method = "HEAD";
            r.AllowAutoRedirect = true;
            r.UserAgent = "PosabaInstaller";
            r.Proxy = null;
            using (var resp = (HttpWebResponse)r.GetResponse())
                return resp.ContentLength;
        }
        catch { return -1; }
    }

    // ---- helpers -------------------------------------------------------

    static WebClient NewClient()
    {
        var wc = new WebClient { Proxy = null };
        wc.Headers.Add("User-Agent", "PosabaInstaller");
        return wc;
    }

    static void Download(string url, string dest, string label)
    {
        Status(label);
        _wc = NewClient();
        long lastPct = -1;
        _wc.DownloadProgressChanged += (s, e) =>
        {
            if (e.ProgressPercentage != lastPct)
            {
                lastPct = e.ProgressPercentage;
                _form.BeginInvoke((Action)(() =>
                {
                    _bar.Value = e.ProgressPercentage;
                    _msg.Text = "Downloading... " + e.ProgressPercentage + "%";
                }));
            }
        };
        var done = new ManualResetEvent(false);
        Exception err = null;
        _wc.DownloadFileCompleted += (s, e) => { err = e.Error; done.Set(); };
        _wc.DownloadFileAsync(new Uri(url), dest);
        done.WaitOne();
        _wc.Dispose(); _wc = null;
        if (err != null) throw err;
    }

    // Extract, collapsing a single top-level folder in the zip so files land
    // directly under 'target'.
    static void ExtractFlatten(string zip, string target)
    {
        string tmp = target + "__x";
        try
        {
            if (Directory.Exists(tmp)) Directory.Delete(tmp, true);
            ZipFile.ExtractToDirectory(zip, tmp);
            var roots = Directory.GetDirectories(tmp);
            var files = Directory.GetFiles(tmp);
            string from = (roots.Length == 1 && files.Length == 0) ? roots[0] : tmp;
            foreach (var d in Directory.GetDirectories(from))
                MoveMerge(d, Path.Combine(target, Path.GetFileName(d)));
            foreach (var f in Directory.GetFiles(from))
                File.Copy(f, Path.Combine(target, Path.GetFileName(f)), true);
        }
        finally { try { if (Directory.Exists(tmp)) Directory.Delete(tmp, true); } catch { } }
    }

    static void MoveMerge(string from, string to)
    {
        Directory.CreateDirectory(to);
        foreach (var d in Directory.GetDirectories(from))
            MoveMerge(d, Path.Combine(to, Path.GetFileName(d)));
        foreach (var f in Directory.GetFiles(from))
            File.Copy(f, Path.Combine(to, Path.GetFileName(f)), true);
    }

    static void Finish(string target)
    {
        Status("Finishing...");

        // self-copy as the uninstaller
        string unin = Path.Combine(target, UninstExe);
        try { File.Copy(Assembly.GetExecutingAssembly().Location, unin, true); } catch { }

        // Apps & features entry
        try
        {
            using (var k = Registry.CurrentUser.CreateSubKey(RegKey))
            {
                k.SetValue("DisplayName", AppName);
                k.SetValue("DisplayIcon", Path.Combine(target, "posaba.ico"));
                k.SetValue("InstallLocation", target);
                k.SetValue("UninstallString", "\"" + unin + "\" --uninstall");
                k.SetValue("QuietUninstallString", "\"" + unin + "\" --quiet");
                k.SetValue("Publisher", "Posaba");
                k.SetValue("NoModify", 1); k.SetValue("NoRepair", 1);
            }
        }
        catch { }

        // shortcuts (Desktop + Start Menu folder), via WScript.Shell COM
        try
        {
            dynamic sh = Activator.CreateInstance(Type.GetTypeFromProgID("WScript.Shell"));
            string desktop = Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory);
            MakeLnk(sh, Path.Combine(desktop, "Posaba Emulator.lnk"),
                    Path.Combine(target, StartExe), target, Path.Combine(target, "posaba.ico"));

            string sm = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Programs), AppName);
            Directory.CreateDirectory(sm);
            MakeLnk(sh, Path.Combine(sm, "Posaba Emulator.lnk"),
                    Path.Combine(target, StartExe), target, Path.Combine(target, "posaba.ico"));
            MakeLnk(sh, Path.Combine(sm, "Uninstall Posaba Emulator.lnk"),
                    unin, target, Path.Combine(target, "posaba.ico"), "--uninstall");
        }
        catch { }

        _form.Invoke((Action)(() =>
        {
            _bar.Value = 100;
            var run = MessageBox.Show(_form,
                AppName + " is installed.\n\nStart it now?", AppName,
                MessageBoxButtons.YesNo, MessageBoxIcon.Information);
            if (run == DialogResult.Yes)
            {
                try
                {
                    Process.Start(new ProcessStartInfo(Path.Combine(target, StartExe))
                    { WorkingDirectory = target, UseShellExecute = true });
                }
                catch { }
            }
            Application.Exit();
        }));
    }

    static void MakeLnk(dynamic sh, string lnk, string targetPath, string wd, string icon, string args = null)
    {
        var s = sh.CreateShortcut(lnk);
        s.TargetPath = targetPath;
        s.WorkingDirectory = wd;
        if (File.Exists(icon)) s.IconLocation = icon + ",0";
        if (args != null) s.Arguments = args;
        s.Description = AppName;
        s.Save();
    }

    // ---- uninstall ----------------------------------------------------

    static void RunUninstall(bool quiet)
    {
        string dir = Path.GetDirectoryName(Assembly.GetExecutingAssembly().Location);
        int selfPid = Process.GetCurrentProcess().Id;

        if (!quiet)
        {
            var ok = MessageBox.Show("Remove " + AppName + "?\n\n" + dir, AppName,
                MessageBoxButtons.YesNo, MessageBoxIcon.Warning);
            if (ok != DialogResult.Yes) return;
        }

        // kill anything running from inside the folder (but never this process)
        foreach (var p in Process.GetProcesses())
        {
            if (p.Id == selfPid) continue;
            try
            {
                var m = p.MainModule;
                string mm = (m != null) ? m.FileName : null;
                if (mm != null && mm.StartsWith(dir, StringComparison.OrdinalIgnoreCase))
                { try { p.Kill(); } catch { } }
            }
            catch { }
        }
        try { foreach (var n in new[] { "qemu-system-x86_64", "emulator", "adb", "crashpad_handler" })
              foreach (var p in Process.GetProcessesByName(n)) { try { p.Kill(); } catch { } } } catch { }

        Thread.Sleep(1200);

        try { Registry.CurrentUser.DeleteSubKeyTree(RegKey, false); } catch { }

        try
        {
            string desktop = Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory);
            File.Delete(Path.Combine(desktop, "Posaba Emulator.lnk"));
            string sm = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Programs), AppName);
            if (Directory.Exists(sm)) Directory.Delete(sm, true);
        }
        catch { }

        // hand the folder to a detached shell (can't delete our own running exe)
        try
        {
            Process.Start(new ProcessStartInfo("cmd.exe",
                "/c ping -n 3 127.0.0.1 >nul & rmdir /s /q \"" + dir + "\"")
            { CreateNoWindow = true, UseShellExecute = false });
        }
        catch { }

        if (!quiet)
            MessageBox.Show(AppName + " has been removed.", AppName,
                MessageBoxButtons.OK, MessageBoxIcon.Information);
    }

    // ---- UI ----------------------------------------------------------

    static void BuildForm(string title)
    {
        _form = new Form
        {
            Text = AppName,
            FormBorderStyle = FormBorderStyle.FixedDialog,
            StartPosition = FormStartPosition.CenterScreen,
            MaximizeBox = false, MinimizeBox = false,
            ClientSize = new System.Drawing.Size(440, 110),
        };
        _msg = new Label { Left = 16, Top = 16, Width = 408, Text = title };
        _bar = new ProgressBar { Left = 16, Top = 44, Width = 408, Height = 22, Maximum = 100 };
        _form.Controls.Add(_msg); _form.Controls.Add(_bar);
        try
        {
            string ico = Path.Combine(Path.GetDirectoryName(Assembly.GetExecutingAssembly().Location), "posaba.ico");
            if (File.Exists(ico)) _form.Icon = new System.Drawing.Icon(ico);
        }
        catch { }
    }

    static void Status(string s)
    {
        if (_form != null && _form.IsHandleCreated)
            _form.BeginInvoke((Action)(() => _msg.Text = s));
    }
}
