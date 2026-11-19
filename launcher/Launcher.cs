// SalamatYar.exe: a tiny launcher. It starts SalamatYar.ps1 (in the same folder)
// with Windows PowerShell, without showing a console window. All app logic is in the script.
using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Windows.Forms;

[assembly: AssemblyTitle("SalamatYar")]
[assembly: AssemblyProduct("SalamatYar")]
[assembly: AssemblyDescription("Health reminder for computer work")]
[assembly: AssemblyCompany("Seyed Hamidreza Alavifar")]
[assembly: AssemblyCopyright("Copyright (c) 2026 Seyed Hamidreza Alavifar. MIT License.")]
[assembly: AssemblyVersion("1.3.0.0")]
[assembly: AssemblyFileVersion("1.3.0.0")]

static class Launcher
{
    [STAThread]
    static void Main(string[] args)
    {
        string dir = Path.GetDirectoryName(Assembly.GetExecutingAssembly().Location);
        string script = Path.Combine(dir, "SalamatYar.ps1");
        if (!File.Exists(script) || !File.Exists(Path.Combine(dir, "lang.json")))
        {
            MessageBox.Show(
                "SalamatYar.ps1 and lang.json must be next to SalamatYar.exe.\n\nPlease extract the whole ZIP folder first, then run SalamatYar.exe from the extracted folder.",
                "SalamatYar", MessageBoxButtons.OK, MessageBoxIcon.Information);
            return;
        }
        string ps = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), @"WindowsPowerShell\v1.0\powershell.exe");
        string extra = args.Length > 0 ? " " + string.Join(" ", args) : "";
        ProcessStartInfo si = new ProcessStartInfo(ps,
            "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File \"" + script + "\"" + extra);
        si.UseShellExecute = false;
        si.CreateNoWindow = true;
        si.WorkingDirectory = dir;
        try { Process.Start(si); }
        catch (Exception ex)
        {
            MessageBox.Show("Could not start Windows PowerShell:\n" + ex.Message, "SalamatYar", MessageBoxButtons.OK, MessageBoxIcon.Error);
        }
    }
}
