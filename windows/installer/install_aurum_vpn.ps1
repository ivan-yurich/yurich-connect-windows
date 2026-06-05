param(
  [Parameter(Mandatory = $true)]
  [string]$Payload
)

$ErrorActionPreference = 'Stop'

function Test-IsAdmin {
  $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
  $principal = New-Object Security.Principal.WindowsPrincipal($identity)
  return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-IsAdmin)) {
  $arguments = @(
    '-NoProfile',
    '-ExecutionPolicy', 'Bypass',
    '-File', "`"$PSCommandPath`"",
    '-Payload', "`"$Payload`""
  ) -join ' '
  $process = Start-Process -FilePath 'powershell.exe' -ArgumentList $arguments -Verb RunAs -Wait -PassThru
  exit $process.ExitCode
}

if (-not (Test-Path -LiteralPath $Payload)) {
  throw "Payload not found: $Payload"
}

$appName = 'Aurum VPN'
$installDir = Join-Path $env:ProgramFiles $appName
$startMenuDir = Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs'
$desktopDir = [Environment]::GetFolderPath('CommonDesktopDirectory')
$tempDir = Join-Path $env:TEMP ("AurumVPNInstall_" + [guid]::NewGuid().ToString('N'))

Write-Host "Installing $appName..."

Get-Process -Name 'AurumVPN' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue

if (Test-Path -LiteralPath $installDir) {
  Remove-Item -LiteralPath $installDir -Recurse -Force
}

New-Item -ItemType Directory -Path $installDir -Force | Out-Null
New-Item -ItemType Directory -Path $tempDir -Force | Out-Null

Expand-Archive -LiteralPath $Payload -DestinationPath $tempDir -Force
Copy-Item -Path (Join-Path $tempDir '*') -Destination $installDir -Recurse -Force

$exePath = Join-Path $installDir 'AurumVPN.exe'
if (-not (Test-Path -LiteralPath $exePath)) {
  throw "AurumVPN.exe was not installed."
}

$wsh = New-Object -ComObject WScript.Shell

$startShortcut = $wsh.CreateShortcut((Join-Path $startMenuDir 'Aurum VPN.lnk'))
$startShortcut.TargetPath = $exePath
$startShortcut.WorkingDirectory = $installDir
$startShortcut.IconLocation = "$exePath,0"
$startShortcut.Save()

$desktopShortcut = $wsh.CreateShortcut((Join-Path $desktopDir 'Aurum VPN.lnk'))
$desktopShortcut.TargetPath = $exePath
$desktopShortcut.WorkingDirectory = $installDir
$desktopShortcut.IconLocation = "$exePath,0"
$desktopShortcut.Save()

$uninstallKey = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\Aurum VPN'
New-Item -Path $uninstallKey -Force | Out-Null
New-ItemProperty -Path $uninstallKey -Name 'DisplayName' -Value 'Aurum VPN' -PropertyType String -Force | Out-Null
New-ItemProperty -Path $uninstallKey -Name 'DisplayVersion' -Value '1.0.15' -PropertyType String -Force | Out-Null
New-ItemProperty -Path $uninstallKey -Name 'Publisher' -Value 'Ivan Yurievich / Aurum VPN' -PropertyType String -Force | Out-Null
New-ItemProperty -Path $uninstallKey -Name 'InstallLocation' -Value $installDir -PropertyType String -Force | Out-Null
New-ItemProperty -Path $uninstallKey -Name 'DisplayIcon' -Value $exePath -PropertyType String -Force | Out-Null
New-ItemProperty -Path $uninstallKey -Name 'UninstallString' -Value "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$installDir\uninstall_aurum_vpn.ps1`"" -PropertyType String -Force | Out-Null
New-ItemProperty -Path $uninstallKey -Name 'QuietUninstallString' -Value "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$installDir\uninstall_aurum_vpn.ps1`"" -PropertyType String -Force | Out-Null

Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue

Write-Host "$appName installed successfully."
Write-Host "Launching $appName..."
Start-Process -FilePath $exePath -WorkingDirectory $installDir
