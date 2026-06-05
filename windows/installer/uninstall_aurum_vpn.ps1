$ErrorActionPreference = 'Stop'

function Test-IsAdmin {
  $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
  $principal = New-Object Security.Principal.WindowsPrincipal($identity)
  return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-FullPathSafe([string]$Path) {
  return [System.IO.Path]::GetFullPath($Path).TrimEnd('\')
}

function Test-SafeInstallPath([string]$Path) {
  $full = Get-FullPathSafe $Path
  $expectedProgramFiles = Get-FullPathSafe (Join-Path $env:ProgramFiles 'Aurum VPN')
  $expectedLocalAppData = if ($env:LOCALAPPDATA) {
    Get-FullPathSafe (Join-Path $env:LOCALAPPDATA 'Aurum VPN')
  } else {
    $null
  }

  $forbidden = @(
    (Get-FullPathSafe 'C:\'),
    (Get-FullPathSafe ([Environment]::GetFolderPath('Desktop'))),
    (Get-FullPathSafe ([Environment]::GetFolderPath('CommonDesktopDirectory'))),
    (Get-FullPathSafe ([Environment]::GetFolderPath('MyDocuments'))),
    (Get-FullPathSafe (Join-Path $env:USERPROFILE 'Downloads'))
  ) | Where-Object { $_ }

  if ($forbidden -contains $full) {
    return $false
  }

  if ($full -ieq $expectedProgramFiles) {
    return $true
  }

  if ($expectedLocalAppData -and $full -ieq $expectedLocalAppData) {
    return $true
  }

  return (Split-Path -Leaf $full) -ieq 'Aurum VPN'
}

function Stop-AurumProcessFromPath([string]$InstallDir) {
  $prefix = (Get-FullPathSafe $InstallDir) + '\'
  $names = @('AurumVPN.exe', 'sing-box.exe', 'naive.exe')

  Get-CimInstance Win32_Process |
    Where-Object {
      $names -contains $_.Name -and
      $_.ExecutablePath -and
      $_.ExecutablePath.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)
    } |
    ForEach-Object {
      try {
        Stop-Process -Id $_.ProcessId -Force -ErrorAction Stop
      } catch {
        Write-Warning "Не удалось остановить процесс $($_.Name) PID=$($_.ProcessId): $($_.Exception.Message)"
      }
    }
}

if (-not (Test-IsAdmin)) {
  $arguments = '-NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $PSCommandPath
  try {
    $process = Start-Process -FilePath 'powershell.exe' -ArgumentList $arguments -Verb RunAs -Wait -PassThru -ErrorAction Stop
    exit $process.ExitCode
  } catch {
    Write-Host 'Удаление отменено: нужны права администратора.'
    exit 1223
  }
}

$installDir = Get-FullPathSafe (Split-Path -Parent $PSCommandPath)
if (-not (Test-SafeInstallPath $installDir)) {
  throw "Небезопасный путь удаления: $installDir. Скрипт удаляет только папку Aurum VPN."
}

$answer = Read-Host "Удалить Aurum VPN из '$installDir'? Введите YES для подтверждения"
if ($answer -cne 'YES') {
  Write-Host 'Удаление отменено.'
  exit 0
}

$startShortcut = Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\Aurum VPN.lnk'
$desktopShortcut = Join-Path ([Environment]::GetFolderPath('CommonDesktopDirectory')) 'Aurum VPN.lnk'

Stop-AurumProcessFromPath $installDir
Remove-Item -LiteralPath $startShortcut -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $desktopShortcut -Force -ErrorAction SilentlyContinue
Remove-Item -Path 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\Aurum VPN' -Recurse -Force -ErrorAction SilentlyContinue

$cleanup = Join-Path $env:TEMP ('AurumVPN_uninstall_cleanup_' + [guid]::NewGuid().ToString('N') + '.cmd')
$command = '@echo off' + [Environment]::NewLine +
  'timeout /t 2 /nobreak >nul' + [Environment]::NewLine +
  'rmdir /s /q "' + $installDir + '"' + [Environment]::NewLine +
  'del "%~f0"'
Set-Content -LiteralPath $cleanup -Value $command -Encoding ASCII
Start-Process -FilePath 'cmd.exe' -ArgumentList "/c `"$cleanup`"" -WindowStyle Hidden

Write-Host 'Aurum VPN удаляется. Окно можно закрыть.'
