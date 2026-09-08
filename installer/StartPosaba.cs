using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;

// Start Posaba.exe - GUI subsystem, no console flash. Launches _run.cmd hidden
// from this exe's own folder, then exits.
static class StartPosaba
{
    static void Main()
    {
        string dir = Path.GetDirectoryName(Assembly.GetExecutingAssembly().Location);
        string cmd = Path.Combine(dir, "_run.cmd");
        if (!File.Exists(cmd)) return;

        var psi = new ProcessStartInfo
        {
            FileName = "cmd.exe",
            Arguments = "/c \"\"" + cmd + "\"\"",
            WorkingDirectory = dir,
            UseShellExecute = false,
            CreateNoWindow = true,
            WindowStyle = ProcessWindowStyle.Hidden,
        };
        try { Process.Start(psi); } catch { }
    }
}
