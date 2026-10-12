using System;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Reflection;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Forms;

[assembly: AssemblyTitle("TLC Toolbox")]
[assembly: AssemblyDescription("Teams Log Collection Toolbox launcher")]
[assembly: AssemblyProduct("TLC Toolbox")]
[assembly: AssemblyVersion("0.1.59.0")]
[assembly: AssemblyFileVersion("0.1.59.0")]

internal static class TlcLauncher
{
    [STAThread]
    private static int Main(string[] arguments)
    {
        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);
        try
        {
            if (arguments.Length != 0) throw new ArgumentException("This launcher takes no arguments. Use the PowerShell entry point for command-line collection.");
            string source = Path.GetDirectoryName(Assembly.GetExecutingAssembly().Location);
            string installed = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Programs", "TLC-Toolbox");
            RequirePayload(source);
            using (Form progress = CreateProgress())
            {
                Label label = (Label)progress.Controls["Status"];
                progress.Show();
                if (!String.Equals(source.TrimEnd('\\'), installed.TrimEnd('\\'), StringComparison.OrdinalIgnoreCase))
                {
                    label.Text = "Preparing TLC Toolbox for this user...\r\nYour Start menu entry and pins will use a stable application folder.";
                    Install(source, progress);
                    RequirePayload(installed);
                }
                label.Text = "Opening TLC Toolbox...";
                OpenWizard(installed, progress);
                progress.Close();
            }
            return 0;
        }
        catch (Exception error)
        {
            string message = error.Message;
            try
            {
                string folder = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "TLC-Toolbox");
                Directory.CreateDirectory(folder);
                string log = Path.Combine(folder, "Launcher.log");
                File.AppendAllText(log, DateTime.UtcNow.ToString("o") + " " + error + Environment.NewLine);
                message += "\r\n\r\nDetails: " + log;
            }
            catch (Exception logError)
            {
                message += "\r\n\r\nThe launcher log could not be written: " + logError.Message;
            }
            MessageBox.Show(message, "TLC Toolbox could not start", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 1;
        }
    }

    private static void RequirePayload(string root)
    {
        foreach (string name in new[] { "Tlc.psd1", "Start-TlcToolbox.ps1", "TLC-Toolbox.exe" })
            if (!File.Exists(Path.Combine(root, name)))
                throw new FileNotFoundException("Extract the whole toolbox ZIP before opening TLC Toolbox.exe. A required file is missing: " + name);
    }

    private static Form CreateProgress()
    {
        Form window = new Form();
        window.Text = "TLC Toolbox";
        window.Icon = Icon.ExtractAssociatedIcon(Assembly.GetExecutingAssembly().Location);
        window.ClientSize = new Size(440, 105);
        window.FormBorderStyle = FormBorderStyle.FixedDialog;
        window.StartPosition = FormStartPosition.CenterScreen;
        window.ControlBox = false;
        window.ShowInTaskbar = false;
        window.Font = new Font("Segoe UI", 10);
        Label status = new Label();
        status.Name = "Status";
        status.SetBounds(18, 15, 404, 48);
        window.Controls.Add(status);
        ProgressBar bar = new ProgressBar();
        bar.SetBounds(18, 76, 404, 10);
        bar.Style = ProgressBarStyle.Marquee;
        window.Controls.Add(bar);
        return window;
    }

    private static ProcessStartInfo Command(string root, bool install)
    {
        ProcessStartInfo command = new ProcessStartInfo();
        command.FileName = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "WindowsPowerShell", "v1.0", "powershell.exe");
        command.Arguments = "-NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File \"" +
            Path.Combine(root, "Start-TlcToolbox.ps1") + "\" -NoRelaunch" + (install ? " -Install" : "");
        command.WorkingDirectory = root;
        command.UseShellExecute = false;
        command.CreateNoWindow = true;
        return command;
    }

    private static void Install(string source, Form progress)
    {
        ProcessStartInfo command = Command(source, true);
        command.RedirectStandardOutput = true;
        command.RedirectStandardError = true;
        using (Process installer = Process.Start(command))
        {
            Task<string> output = installer.StandardOutput.ReadToEndAsync();
            Task<string> errors = installer.StandardError.ReadToEndAsync();
            while (!installer.HasExited)
            {
                Application.DoEvents();
                Thread.Sleep(50);
            }
            installer.WaitForExit();
            string detail = errors.Result;
            if (installer.ExitCode != 0)
            {
                if (String.IsNullOrWhiteSpace(detail)) detail = output.Result;
                if (detail.Length > 2000) detail = detail.Substring(0, 2000);
                throw new InvalidOperationException("TLC Toolbox installation did not complete. No collection was started.\r\n\r\n" + detail);
            }
        }
    }

    private static void OpenWizard(string root, Form progress)
    {
        using (Process wizard = Process.Start(Command(root, false)))
        {
            DateTime deadline = DateTime.UtcNow.AddMinutes(2);
            while (DateTime.UtcNow < deadline)
            {
                wizard.Refresh();
                if (wizard.HasExited)
                    throw new InvalidOperationException("TLC Toolbox exited before opening. Check Launcher.log and your organization's application-control policy. Do not bypass corporate policy.");
                if (wizard.MainWindowHandle != IntPtr.Zero && HasWizardTitle(wizard.MainWindowTitle))
                    return;
                Application.DoEvents();
                Thread.Sleep(100);
            }
            throw new TimeoutException("TLC Toolbox is still starting after two minutes. Its process was left running; check startup diagnostics before launching another copy.");
        }
    }

    private static bool HasWizardTitle(string title)
    {
        return title != null && title.StartsWith("TLC Toolbox - Teams Log Collection", StringComparison.Ordinal);
    }
}
