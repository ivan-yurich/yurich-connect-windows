using System.Diagnostics;
using System.IO.Compression;
using System.Reflection;
using System.Runtime.InteropServices;
using Microsoft.Win32;

namespace AurumVpnSetup;

internal static class Program
{
    private const string AppName = "Aurum VPN";
    private const string StartupTaskName = "Aurum VPN";

    [STAThread]
    private static int Main()
    {
        ApplicationConfiguration.Initialize();

        try
        {
            var exePath = Install();
            MessageBox.Show(
                $"{AppName} установлен. Сейчас откроется приложение.",
                $"{AppName} Setup",
                MessageBoxButtons.OK,
                MessageBoxIcon.Information);
            LaunchApp(exePath);
            return 0;
        }
        catch (Exception ex)
        {
            MessageBox.Show(
                ex.Message,
                $"{AppName} Setup",
                MessageBoxButtons.OK,
                MessageBoxIcon.Error);
            return 1;
        }
    }

    private static string Install()
    {
        var installDir = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles),
            AppName);
        var tempDir = Path.Combine(Path.GetTempPath(), "AurumVPNInstall_" + Guid.NewGuid().ToString("N"));
        var payloadPath = Path.Combine(tempDir, "AurumVPN_payload.zip");

        Directory.CreateDirectory(tempDir);
        try
        {
            ExtractPayload(payloadPath);

            foreach (var process in Process.GetProcessesByName("AurumVPN"))
            {
                try
                {
                    process.Kill(true);
                    process.WaitForExit(5000);
                }
                catch
                {
                    // Best-effort shutdown before replacing files.
                }
            }

            if (Directory.Exists(installDir))
            {
                Directory.Delete(installDir, recursive: true);
            }

            Directory.CreateDirectory(installDir);
            ZipFile.ExtractToDirectory(payloadPath, installDir, overwriteFiles: true);

            var exePath = Path.Combine(installDir, "AurumVPN.exe");
            if (!File.Exists(exePath))
            {
                throw new FileNotFoundException("AurumVPN.exe was not installed.", exePath);
            }

            CreateShortcut(
                Path.Combine(
                    Environment.GetFolderPath(Environment.SpecialFolder.CommonStartMenu),
                    "Programs",
                    "Aurum VPN.lnk"),
                exePath,
                installDir);
            CreateShortcut(
                Path.Combine(
                    Environment.GetFolderPath(Environment.SpecialFolder.CommonDesktopDirectory),
                    "Aurum VPN.lnk"),
                exePath,
                installDir);
            RegisterUninstall(installDir, exePath);
            RepairStartupTaskIfEnabled(exePath);
            return exePath;
        }
        finally
        {
            try
            {
                Directory.Delete(tempDir, recursive: true);
            }
            catch
            {
                // Temp cleanup should never fail the install.
            }
        }
    }

    private static void LaunchApp(string exePath)
    {
        Process.Start(new ProcessStartInfo
        {
            FileName = exePath,
            WorkingDirectory = Path.GetDirectoryName(exePath)!,
            UseShellExecute = true,
        });
    }

    private static void ExtractPayload(string payloadPath)
    {
        var assembly = Assembly.GetExecutingAssembly();
        var resource = assembly
            .GetManifestResourceNames()
            .FirstOrDefault(name => name.EndsWith("AurumVPN_payload.zip", StringComparison.Ordinal));

        if (resource is null)
        {
            throw new InvalidOperationException("Installer payload is missing.");
        }

        using var input = assembly.GetManifestResourceStream(resource)
            ?? throw new InvalidOperationException("Installer payload could not be opened.");
        using var output = File.Create(payloadPath);
        input.CopyTo(output);
    }

    private static void CreateShortcut(string shortcutPath, string targetPath, string workingDirectory)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(shortcutPath)!);

        var shellType = Type.GetTypeFromProgID("WScript.Shell")
            ?? throw new InvalidOperationException("Windows Script Host is unavailable.");
        dynamic shell = Activator.CreateInstance(shellType)
            ?? throw new InvalidOperationException("Could not create shortcut helper.");
        dynamic shortcut = shell.CreateShortcut(shortcutPath);
        shortcut.TargetPath = targetPath;
        shortcut.WorkingDirectory = workingDirectory;
        shortcut.IconLocation = targetPath + ",0";
        shortcut.Save();

        Marshal.FinalReleaseComObject(shortcut);
        Marshal.FinalReleaseComObject(shell);
    }

    private static void RegisterUninstall(string installDir, string exePath)
    {
        using var key = Registry.LocalMachine.CreateSubKey(
            @"Software\Microsoft\Windows\CurrentVersion\Uninstall\Aurum VPN");
        if (key is null)
        {
            return;
        }

        var uninstallScript = Path.Combine(installDir, "uninstall_aurum_vpn.ps1");
        key.SetValue("DisplayName", "Aurum VPN");
        key.SetValue("DisplayVersion", "1.0.13");
        key.SetValue("Publisher", "ivan-it.net");
        key.SetValue("InstallLocation", installDir);
        key.SetValue("DisplayIcon", exePath);
        key.SetValue(
            "UninstallString",
            $"powershell.exe -NoProfile -ExecutionPolicy Bypass -File \"{uninstallScript}\"");
    }

    private static void RepairStartupTaskIfEnabled(string exePath)
    {
        try
        {
            using var query = Process.Start(new ProcessStartInfo
            {
                FileName = "schtasks.exe",
                Arguments = $"/Query /TN \"{StartupTaskName}\" /XML",
                UseShellExecute = false,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                CreateNoWindow = true,
            });
            if (query is null)
            {
                return;
            }

            var xml = query.StandardOutput.ReadToEnd();
            query.WaitForExit(5000);
            if (query.ExitCode != 0 ||
                !xml.Contains("<RunLevel>HighestAvailable</RunLevel>", StringComparison.OrdinalIgnoreCase))
            {
                return;
            }

            var script = $"""
                $ErrorActionPreference = 'Stop'
                $action = New-ScheduledTaskAction -Execute {PowerShellQuote(exePath)}
                $trigger = New-ScheduledTaskTrigger -AtLogOn
                $trigger.Delay = 'PT30S'
                $principal = New-ScheduledTaskPrincipal -UserId ([System.Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogonType Interactive -RunLevel Highest
                $settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
                Register-ScheduledTask -TaskName {PowerShellQuote(StartupTaskName)} -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
                """;

            using var repair = Process.Start(new ProcessStartInfo
            {
                FileName = "powershell.exe",
                ArgumentList =
                {
                    "-NoProfile",
                    "-ExecutionPolicy",
                    "Bypass",
                    "-Command",
                    script,
                },
                UseShellExecute = false,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                CreateNoWindow = true,
            });
            repair?.WaitForExit(10000);
        }
        catch
        {
            // Startup repair is best-effort. Install should still complete.
        }
    }

    private static string PowerShellQuote(string value)
    {
        return "'" + value.Replace("'", "''", StringComparison.Ordinal) + "'";
    }
}
