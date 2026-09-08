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
//   Install Posaba.exe            download the full bundle, extract, set up
//   Install Posaba.exe --lite     download a small core, fetch the Android
//                                 emulator + tools from Google, assemble
//   (exe name starts "Uninstall") | --uninstall | --quiet : remove
//
// Unsigned - SmartScreen will show "More info -> Run anyway".

static class PosabaWebInstaller
{
    const string AppName   = "Posaba Android Emulator";
    const string RegKey    = @"Software\Microsoft\Windows\CurrentVersion\Uninstall\PosabaEmulator";
    const string FolderName = "PosabaEmulator";
    const string StartExe  = "Start Posaba.exe";
    const string UninstExe = "Uninstall Posaba.exe";

    // Full bundle (single download from GitHub).
    const string FULL_URL  = "https://github.com/qualitystreamzmedia-netizen/posaba-emulator/releases/download/v1/PosabaEmulator.zip";
    // Lite: small core from GitHub + Android SDK bits from Google.
    const string CORE_URL  = "https://github.com/qualitystreamzmedia-netizen/posaba-emulator/releases/download/v1/PosabaEmulator-core.zip";
    const string SDK_REPO  = "https://dl.google.com/android/repository/";
    const string PLATFORM_TOOLS = SDK_REPO + "platform-tools-latest-windows.zip";
    const string SYSIMG_XML = SDK_REPO + "sys-img/google_apis/sys-img2-3.xml";
    const string REPO_XML   = SDK_REPO + "repository2-3.xml";

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
        bool lite = args.Any(a => a.Equals("--lite", StringComparison.OrdinalIgnoreCase));

        if (uninstall) { RunUninstall(args.Any(a => a.Equals("--quiet", StringComparison.OrdinalIgnoreCase))); return; }
        RunInstall(lite);
    }

    // ---- install --------------------------------------------------------

    static void RunInstall(bool lite)
    {
        string target;
        using (var fbd = new FolderBrowserDialog
        {
            Description = "Choose where to install " + AppName +
                          " (a \"" + FolderName + "\" folder is created inside).",
            ShowNewFolderButton = true,
        })
        {
            if (fbd.ShowDialog() != DialogResult.OK) return;
            target = Path.Combine(fbd.SelectedPath, FolderName);
        }
        Directory.CreateDirectory(target);

        BuildForm("Installing " + AppName + "...");
        var t = new Thread(() =>
        {
            try
            {
                if (lite) InstallLite(target);
                else InstallFull(target);

                Finish(target);
            }
            catch (Exception ex)
            {
                _form.Invoke((Action)(() =>
                {
                    MessageBox.Show(_form, "Install failed:\n\n" + ex.Message, AppName,
                        MessageBoxButtons.OK, MessageBoxIcon.Error);
                    Application.Exit();
                }));
            }
        }) { IsBackground = true };
        _form.Shown += (s, e) => t.Start();
        Application.Run(_form);
    }

    static void InstallFull(string target)
    {
        string zip = Path.Combine(Path.GetTempPath(), "PosabaEmulator.zip");
        Download(FULL_URL, zip, "Downloading the emulator (~1.9 GB)...");
        Status("Extracting...");
        ExtractFlatten(zip, target);
        File.Delete(zip);
    }

    static void InstallLite(string target)
    {
        string tmp = Path.Combine(Path.GetTempPath(), "PosabaLite");
        if (Directory.Exists(tmp)) Directory.Delete(tmp, true);
        Directory.CreateDirectory(tmp);

        string core = Path.Combine(tmp, "core.zip");
        Download(CORE_URL, core, "Downloading Posaba (~150 MB)...");
        Status("Extracting...");
        ExtractFlatten(core, target);

        string sdk = Path.Combine(target, "sdk");
        Directory.CreateDirectory(sdk);

        // platform-tools (stable URL)
        string pt = Path.Combine(tmp, "platform-tools.zip");
        Download(PLATFORM_TOOLS, pt, "Downloading adb from Google...");
        Status("Extracting adb...");
        SafeExtract(pt, sdk);   // creates sdk\platform-tools\

        // emulator (URL from the SDK repo manifest; relative to SDK_REPO)
        string emuUrl = FindUrl(REPO_XML, "emulator", null, "windows", SDK_REPO);
        string emu = Path.Combine(tmp, "emulator.zip");
        Download(emuUrl, emu, "Downloading the Android emulator from Google (~1 GB)...");
        Status("Extracting emulator...");
        SafeExtract(emu, sdk);  // creates sdk\emulator\

        // system image (URLs are relative to the sys-img/google_apis/ folder)
        string imgUrl = FindUrl(SYSIMG_XML, "system-images;android-34;google_apis;x86_64", "34",
                                null, SDK_REPO + "sys-img/google_apis/");
        string img = Path.Combine(tmp, "sysimg.zip");
        Download(imgUrl, img, "Downloading Android 14 from Google (~1.5 GB)...");
        Status("Extracting Android...");
        // the zip's top folder is "x86_64" -> lands at google_apis\x86_64\
        SafeExtract(img, Path.Combine(sdk, "system-images", "android-34", "google_apis"));

        Directory.Delete(tmp, true);
    }

    // First <url> (namespace-agnostic) under a <remotePackage path="..."> that
    // matches pathContains (+ apiLevel + urlContains when given). Prefers the
    // stable channel (channel-0). base_ is prepended to relative hrefs.
    static string FindUrl(string xmlUrl, string pathContains, string apiLevel, string urlContains, string base_)
    {
        string xml;
        using (var wc = NewClient()) xml = wc.DownloadString(xmlUrl);
        var doc = new System.Xml.XmlDocument();
        doc.LoadXml(xml);

        string best = null;
        foreach (System.Xml.XmlNode pkg in doc.GetElementsByTagName("remotePackage"))
        {
            string path = "";
            if (pkg.Attributes != null && pkg.Attributes["path"] != null)
                path = pkg.Attributes["path"].Value;
            if (!path.Contains(pathContains)) continue;
            if (apiLevel != null && !path.Contains(apiLevel)) continue;

            bool stable = false;
            var ch = pkg.SelectSingleNode(".//*[local-name()='channelRef']");
            if (ch != null && ch.Attributes != null && ch.Attributes["ref"] != null)
                stable = ch.Attributes["ref"].Value == "channel-0";

            foreach (System.Xml.XmlNode u in pkg.SelectNodes(".//*[local-name()='url']"))
            {
                string href = u.InnerText.Trim();
                if (urlContains != null && !href.Contains(urlContains)) continue;
                string full = href.StartsWith("http") ? href : base_ + href;
                if (stable) return full;
                if (best == null) best = full;
            }
        }
        if (best != null) return best;
        throw new Exception("No download URL found in " + xmlUrl);
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
                _form.BeginInvoke((Action)(() => _bar.Value = e.ProgressPercentage));
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
        if (Directory.Exists(tmp)) Directory.Delete(tmp, true);
        ZipFile.ExtractToDirectory(zip, tmp);
        var roots = Directory.GetDirectories(tmp);
        var files = Directory.GetFiles(tmp);
        string from = (roots.Length == 1 && files.Length == 0) ? roots[0] : tmp;
        foreach (var d in Directory.GetDirectories(from))
            MoveMerge(d, Path.Combine(target, Path.GetFileName(d)));
        foreach (var f in Directory.GetFiles(from))
            File.Copy(f, Path.Combine(target, Path.GetFileName(f)), true);
        Directory.Delete(tmp, true);
    }

    static void SafeExtract(string zip, string dest)
    {
        string tmp = Path.Combine(Path.GetTempPath(), "px_" + Guid.NewGuid().ToString("N").Substring(0, 8));
        ZipFile.ExtractToDirectory(zip, tmp);
        foreach (var d in Directory.GetDirectories(tmp))
            MoveMerge(d, Path.Combine(dest, Path.GetFileName(d)));
        foreach (var f in Directory.GetFiles(tmp))
            File.Copy(f, Path.Combine(dest, Path.GetFileName(f)), true);
        Directory.Delete(tmp, true);
    }

    static void FlattenIfSingleChild(string parent, string childName)
    {
        string child = Path.Combine(parent, childName);
        string x86 = Path.Combine(child, "x86_64");
        if (Directory.Exists(x86))
        {
            foreach (var f in Directory.GetFiles(x86)) File.Copy(f, Path.Combine(child, Path.GetFileName(f)), true);
            Directory.Delete(x86, true);
        }
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
