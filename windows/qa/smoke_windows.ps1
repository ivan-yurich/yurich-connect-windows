param(
  [switch]$SkipBuild,
  [switch]$SkipInstallerPublish
)

$ErrorActionPreference = 'Stop'

function Invoke-Step {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Name,
    [Parameter(Mandatory = $true)]
    [scriptblock]$Script
  )

  Write-Host ""
  Write-Host "== $Name =="
  & $Script
}

$projectRoot = Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')
Set-Location $projectRoot

$runtimeDir = Join-Path $projectRoot 'assets\windows\sing-box'
$releaseDir = Join-Path $projectRoot 'release\windows'
$portableZip = Join-Path $releaseDir 'AurumVPN_Windows_Portable.zip'
$setupExe = Join-Path $releaseDir 'AurumVPN_Setup.exe'
$setupDir = Join-Path $projectRoot 'windows\installer\setup'
$setupPayload = Join-Path $setupDir 'AurumVPN_payload.zip'
$setupIcon = Join-Path $setupDir 'app_icon.ico'
$runnerIcon = Join-Path $projectRoot 'windows\runner\resources\app_icon.ico'
$appDataConfig = Join-Path $env:APPDATA 'Aurum VPN\config.json'

Invoke-Step 'Flutter analyze' {
  flutter analyze
}

Invoke-Step 'Flutter tests' {
  flutter test
}

if (-not $SkipBuild) {
  Invoke-Step 'Windows release build' {
    flutter build windows --release
  }
}

Invoke-Step 'Windows runtime files' {
  foreach ($name in @('sing-box.exe', 'wintun.dll', 'libcronet.dll')) {
    $path = Join-Path $runtimeDir $name
    if (-not (Test-Path -LiteralPath $path)) {
      throw "Missing runtime file: $path"
    }
    $item = Get-Item -LiteralPath $path
    Write-Host ("{0}  {1} bytes  {2}" -f $item.Name, $item.Length, $item.LastWriteTime)
  }
  & (Join-Path $runtimeDir 'sing-box.exe') version
}

Invoke-Step 'Active sing-box config check' {
  if (Test-Path -LiteralPath $appDataConfig) {
    & (Join-Path $runtimeDir 'sing-box.exe') check -c $appDataConfig
  } else {
    Write-Host "No active config found at $appDataConfig"
  }
}

Invoke-Step 'Portable archive contents' {
  if (-not (Test-Path -LiteralPath $portableZip)) {
    throw "Missing portable archive: $portableZip"
  }

  Add-Type -AssemblyName System.IO.Compression.FileSystem
  $requiredEntries = @(
    'AurumVPN.exe',
    'flutter_windows.dll',
    'screen_retriever_windows_plugin.dll',
    'tray_manager_plugin.dll',
    'window_manager_plugin.dll',
    'runtime/sing-box.exe',
    'runtime/wintun.dll',
    'runtime/libcronet.dll',
    'data/flutter_assets/windows/runner/resources/app_icon.ico',
    'START_AURUM_VPN.cmd',
    'uninstall_aurum_vpn.ps1',
    'README_PORTABLE_RU.txt'
  )

  $zip = [IO.Compression.ZipFile]::OpenRead($portableZip)
  try {
    $entries = @($zip.Entries | ForEach-Object { $_.FullName })
    foreach ($entry in $requiredEntries) {
      if ($entries -notcontains $entry) {
        throw "Portable archive is missing: $entry"
      }
    }
    Write-Host "Portable archive OK: $portableZip"
  } finally {
    $zip.Dispose()
  }
}

if (-not $SkipInstallerPublish) {
  Invoke-Step 'Installer publish' {
    Copy-Item -LiteralPath $portableZip -Destination $setupPayload -Force
    Copy-Item -LiteralPath $runnerIcon -Destination $setupIcon -Force
    try {
      dotnet publish (Join-Path $setupDir 'AurumVpnSetup.csproj') -c Release
      $publishedSetup = Join-Path $setupDir 'bin\Release\net9.0-windows\win-x64\publish\AurumVPN_Setup.exe'
      if (-not (Test-Path -LiteralPath $publishedSetup)) {
        throw "Installer publish did not produce $publishedSetup"
      }
      Copy-Item -LiteralPath $publishedSetup -Destination $setupExe -Force
    } finally {
      Remove-Item -LiteralPath $setupPayload, $setupIcon -Force -ErrorAction SilentlyContinue
    }
  }
}

Invoke-Step 'Release hashes' {
  $portableHash = Get-FileHash -Algorithm SHA256 -LiteralPath $portableZip
  Write-Host ("{0}  {1}" -f $portableHash.Hash, $portableHash.Path)
  if (Test-Path -LiteralPath $setupExe) {
    $setupHash = Get-FileHash -Algorithm SHA256 -LiteralPath $setupExe
    Write-Host ("{0}  {1}" -f $setupHash.Hash, $setupHash.Path)
  }
}
