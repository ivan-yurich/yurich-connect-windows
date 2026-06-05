using System.Diagnostics;
using System.IO.Compression;
using System.Reflection;
using System.Runtime.InteropServices;
using Microsoft.Win32;

namespace AurumVpnSetup;

internal static class Program
{
    private const string AppName = "Aurum VPN";
    private const string Publisher = "Ivan Yurievich / Aurum VPN";
    private const string AppVersion = "1.0.15";
    private const string StartupTaskName = "Aurum VPN";
    private const string UninstallKeyPath = @"Software\Microsoft\Windows\CurrentVersion\Uninstall\Aurum VPN";
    private static readonly string[] AppProcessNames = ["AurumVPN", "sing-box", "naive"];
    private static readonly string[] VisualRuntimeDlls =
    [
        "MSVCP140.dll",
        "VCRUNTIME140.dll",
        "VCRUNTIME140_1.dll",
    ];

    [STAThread]
    private static int Main()
    {
        ApplicationConfiguration.Initialize();

        try
        {
            var exePath = Install();
            var answer = MessageBox.Show(
                $"{AppName} установлен.\n\nЗапустить приложение сейчас?",
                $"{AppName} Setup",
                MessageBoxButtons.YesNo,
                MessageBoxIcon.Information);
            if (answer == DialogResult.Yes)
            {
                LaunchApp(exePath);
            }

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
        var installDir = InstallDir();
        var tempDir = Path.Combine(Path.GetTempPath(), "AurumVPNInstall_" + Guid.NewGuid().ToString("N"));
        var payloadPath = Path.Combine(tempDir, "AurumVPN_payload.zip");

        Directory.CreateDirectory(tempDir);
        try
        {
            ExtractPayload(payloadPath);

            var oldVersion = GetExistingVersion();
            if (Directory.Exists(installDir) || !string.IsNullOrWhiteSpace(oldVersion))
            {
                StopAppProcessesFromInstallDir(installDir);
            }

            ReplaceInstallDirectory(installDir, payloadPath);

            var exePath = Path.Combine(installDir, "AurumVPN.exe");
            if (!File.Exists(exePath))
            {
                throw new FileNotFoundException("AurumVPN.exe не был установлен.", exePath);
            }

            EnsureVisualRuntimePayload(installDir);
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

    private static string InstallDir()
    {
        return Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles),
            AppName);
    }

    private static string? GetExistingVersion()
    {
        using var key = Registry.LocalMachine.OpenSubKey(UninstallKeyPath);
        return key?.GetValue("DisplayVersion") as string;
    }

    private static void ReplaceInstallDirectory(string installDir, string payloadPath)
    {
        var expected = Path.GetFullPath(InstallDir()).TrimEnd('\\');
        var actual = Path.GetFullPath(installDir).TrimEnd('\\');
        if (!actual.Equals(expected, StringComparison.OrdinalIgnoreCase))
        {
            throw new InvalidOperationException($"Небезопасный путь установки: {actual}");
        }

        if (Directory.Exists(installDir))
        {
            Directory.Delete(installDir, recursive: true);
        }

        Directory.CreateDirectory(installDir);
        ZipFile.ExtractToDirectory(payloadPath, installDir, overwriteFiles: true);
    }

    private static void StopAppProcessesFromInstallDir(string installDir)
    {
        var installPrefix = Path.GetFullPath(installDir).TrimEnd('\\') + "\\";
        foreach (var processName in AppProcessNames)
        {
            foreach (var process in Process.GetProcessesByName(processName))
            {
                try
                {
                    var modulePath = process.MainModule?.FileName;
                    if (modulePath != null &&
                        modulePath.StartsWith(installPrefix, StringComparison.OrdinalIgnoreCase))
                    {
                        process.Kill(true);
                        process.WaitForExit(5000);
                    }
                }
                catch
                {
                    // Best-effort shutdown before replacing files.
                }
                finally
                {
                    process.Dispose();
                }
            }
        }
    }

    private static void EnsureVisualRuntimePayload(string installDir)
    {
        var missing = VisualRuntimeDlls
            .Where(name => !File.Exists(Path.Combine(installDir, name)))
            .ToArray();
        if (missing.Length == 0)
        {
            return;
        }

        throw new InvalidOperationException(
            "В установочном пакете отсутствуют DLL Microsoft Visual C++ Runtime: " +
            string.Join(", ", missing) +
            "\n\nПереустанови свежий AurumVPN_Setup.exe или установи Microsoft Visual C++ Redistributable 2015-2022 x64: https://aka.ms/vs/17/release/vc_redist.x64.exe");
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
        using var key = Registry.LocalMachine.CreateSubKey(UninstallKeyPath);
        if (key is null)
        {
            return;
        }

        var uninstallScript = Path.Combine(installDir, "uninstall_aurum_vpn.ps1");
        var uninstallCommand =
            $"powershell.exe -NoProfile -ExecutionPolicy Bypass -File \"{uninstallScript}\"";
        key.SetValue("DisplayName", AppName);
        key.SetValue("DisplayVersion", AppVersion);
        key.SetValue("Publisher", Publisher);
        key.SetValue("InstallLocation", installDir);
        key.SetValue("DisplayIcon", exePath);
        key.SetValue("UninstallString", uninstallCommand);
        key.SetValue("QuietUninstallString", uninstallCommand);
        key.SetValue("InstallDate", DateTime.Now.ToString("yyyyMMdd"));
        key.SetValue("NoModify", 1, RegistryValueKind.DWord);
        key.SetValue("NoRepair", 1, RegistryValueKind.DWord);
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
