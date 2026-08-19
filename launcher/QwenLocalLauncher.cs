using System;
using System.Diagnostics;
using System.IO;
using System.Windows.Forms;

internal static class Program
{
    [STAThread]
    private static int Main()
    {
        try
        {
            string root = AppDomain.CurrentDomain.BaseDirectory.TrimEnd(Path.DirectorySeparatorChar);
            string script = Path.Combine(root, "scripts", "launch-hidden.vbs");
            if (!File.Exists(script))
                throw new FileNotFoundException("Launcher script not found.", script);

            string wscript = Path.Combine(Environment.SystemDirectory, "wscript.exe");
            var psi = new ProcessStartInfo
            {
                FileName = wscript,
                Arguments = "\"" + script + "\"",
                WorkingDirectory = root,
                UseShellExecute = false,
                CreateNoWindow = true,
                WindowStyle = ProcessWindowStyle.Hidden
            };
            Process.Start(psi);
            return 0;
        }
        catch (Exception ex)
        {
            MessageBox.Show(
                "Qwen Local Launcher could not start.\r\n\r\n" + ex.Message,
                "Qwen Local Launcher",
                MessageBoxButtons.OK,
                MessageBoxIcon.Error);
            return 1;
        }
    }
}
