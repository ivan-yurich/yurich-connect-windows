$ErrorActionPreference = 'Stop'

function Test-IsAdmin {
  $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
  $principal = New-Object Security.Principal.WindowsPrincipal($identity)
  return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-IsAdmin)) {
  $arguments = '-NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $PSCommandPath
  $process = Start-Process -FilePath 'powershell.exe' -ArgumentList $arguments -Verb RunAs -Wait -PassThru
  exit $process.ExitCode
}

$installDir = Split-Path -Parent $PSCommandPath
$startShortcut = Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\Aurum VPN.lnk'
$desktopShortcut = Join-Path ([Environment]::GetFolderPath('CommonDesktopDirectory')) 'Aurum VPN.lnk'

Get-Process -Name 'AurumVPN' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $startShortcut -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $desktopShortcut -Force -ErrorAction SilentlyContinue
Remove-Item -Path 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\Aurum VPN' -Recurse -Force -ErrorAction SilentlyContinue

$cleanup = Join-Path $env:TEMP 'AurumVPN_uninstall_cleanup.cmd'
$command = '@echo off' + [Environment]::NewLine +
  'timeout /t 2 /nobreak >nul' + [Environment]::NewLine +
  'rmdir /s /q "' + $installDir + '"' + [Environment]::NewLine +
  'del "%~f0"'
Set-Content -LiteralPath $cleanup -Value $command -Encoding ASCII
Start-Process -FilePath 'cmd.exe' -ArgumentList "/c `"$cleanup`"" -WindowStyle Hidden
