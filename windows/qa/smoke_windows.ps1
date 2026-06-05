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
$windowsBuildDir = Join-Path $projectRoot 'build\windows'
$buildOutputDir = Join-Path $projectRoot 'build\windows\x64\runner\Release'
$releaseDir = Join-Path $projectRoot 'release\windows'
$portableDir = Join-Path $releaseDir 'YurichConnect_Windows_Portable'
$portableZip = Join-Path $releaseDir 'YurichConnect_Windows_Portable.zip'
$setupExe = Join-Path $releaseDir 'YurichConnect_Setup.exe'
$setupDir = Join-Path $projectRoot 'windows\installer\setup'
$setupPayload = Join-Path $setupDir 'YurichConnect_payload.zip'
$setupIcon = Join-Path $setupDir 'app_icon.ico'
$runnerIcon = Join-Path $projectRoot 'windows\runner\resources\app_icon.ico'
$appDataConfig = Join-Path $env:APPDATA 'Yurich Connect\config.json'

Invoke-Step 'Flutter analyze' {
  flutter analyze
}

Invoke-Step 'Flutter tests' {
  flutter test
}

if (-not $SkipBuild) {
  Invoke-Step 'Windows release build' {
    Remove-Item -LiteralPath $windowsBuildDir -Recurse -Force -ErrorAction SilentlyContinue
    flutter build windows --release --split-debug-info=build\symbols\windows
  }
}

Invoke-Step 'Repack portable archive' {
  if (-not (Test-Path -LiteralPath $buildOutputDir)) {
    throw "Missing Flutter release output: $buildOutputDir"
  }

  New-Item -ItemType Directory -Path $releaseDir -Force | Out-Null
  Remove-Item -LiteralPath $portableDir -Recurse -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $portableZip -Force -ErrorAction SilentlyContinue
  Copy-Item -LiteralPath $buildOutputDir -Destination $portableDir -Recurse -Force

  $pdbFiles = @(Get-ChildItem -LiteralPath $portableDir -Recurse -Filter '*.pdb' -ErrorAction SilentlyContinue)
  if ($pdbFiles.Count -gt 0) {
    throw "Release payload contains PDB files: $($pdbFiles.FullName -join ', ')"
  }

  Compress-Archive -Path (Join-Path $portableDir '*') -DestinationPath $portableZip -CompressionLevel Optimal -Force
  Write-Host "Portable archive repacked: $portableZip"
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
  foreach ($name in @('naive.exe', 'NAIVE_LICENSE.txt', 'NAIVE_USAGE.txt')) {
    $path = Join-Path $runtimeDir $name
    if (-not (Test-Path -LiteralPath $path)) {
      throw "Missing NaiveProxy runtime file: $path"
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
    'YurichConnect.exe',
    'flutter_windows.dll',
    'screen_retriever_windows_plugin.dll',
    'tray_manager_plugin.dll',
    'window_manager_plugin.dll',
    'runtime/sing-box.exe',
    'runtime/naive.exe',
    'runtime/NAIVE_LICENSE.txt',
    'runtime/wintun.dll',
    'runtime/libcronet.dll',
    'MSVCP140.dll',
    'VCRUNTIME140.dll',
    'VCRUNTIME140_1.dll',
    'data/flutter_assets/windows/runner/resources/app_icon.ico',
    'START_YURICH_CONNECT.cmd',
    'uninstall_yurich_connect.ps1',
    'README_PORTABLE_RU.txt'
  )

  $zip = [IO.Compression.ZipFile]::OpenRead($portableZip)
  try {
    $entries = @($zip.Entries | ForEach-Object { $_.FullName.Replace('\', '/') })
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

Invoke-Step 'Installer payload safety scan' {
  foreach ($name in @(
    'YurichConnect.exe',
    'flutter_windows.dll',
    'runtime/sing-box.exe',
    'runtime/naive.exe',
    'runtime/wintun.dll',
    'runtime/libcronet.dll',
    'MSVCP140.dll',
    'VCRUNTIME140.dll',
    'VCRUNTIME140_1.dll',
    'README_PORTABLE_RU.txt',
    'START_YURICH_CONNECT.cmd',
    'uninstall_yurich_connect.ps1'
  )) {
    $path = Join-Path $portableDir $name
    if (-not (Test-Path -LiteralPath $path)) {
      throw "Payload missing required file: $name"
    }
  }

  $forbiddenExtensions = @('.pdb', '.ilk', '.exp', '.lib')
  $forbiddenFiles = @(Get-ChildItem -LiteralPath $portableDir -Recurse -File -ErrorAction SilentlyContinue |
    Where-Object { $forbiddenExtensions -contains $_.Extension.ToLowerInvariant() })
  if ($forbiddenFiles.Count -gt 0) {
    throw "Payload contains debug/build files: $($forbiddenFiles.FullName -join ', ')"
  }

  $patterns = @(
    'C:\\Users\\ivan-',
    'AndroidStudioProjects\\aurum_vpn_windows_repo',
    '-----BEGIN (?:RSA |OPENSSH |EC |DSA )?PRIVATE KEY-----',
    'vless://[0-9a-fA-F-]{32,}@',
    'naive\+https://[^:\s]+:[^@\s]+@',
    'hysteria2://[^@\s]+@',
    'hy2://[^@\s]+@',
    'access_token["=:\s]+[A-Za-z0-9._-]{20,}',
    'refresh_token["=:\s]+[A-Za-z0-9._-]{20,}',
    '(?:Remnawave|Yurich ID)[^\r\n]+https?://'
  )
  $pattern = ($patterns -join '|')
  $matches = @(rg -a -n --hidden --glob '!data/flutter_assets/NOTICES.Z' --glob '!runtime/LICENSE' --glob '!runtime/NAIVE_LICENSE.txt' --glob '!runtime/WINTUN_LICENSE.txt' $pattern $portableDir 2>$null)
  if ($matches.Count -gt 0) {
    throw "Payload safety scan found sensitive/dev data in $portableDir`n$($matches -join [Environment]::NewLine)"
  }
  Write-Host "Payload safety scan OK"
}

if (-not $SkipInstallerPublish) {
  Invoke-Step 'Installer publish' {
    Copy-Item -LiteralPath $portableZip -Destination $setupPayload -Force
    Copy-Item -LiteralPath $runnerIcon -Destination $setupIcon -Force
    try {
      Remove-Item -LiteralPath (Join-Path $setupDir 'bin'), (Join-Path $setupDir 'obj') -Recurse -Force -ErrorAction SilentlyContinue
      dotnet publish (Join-Path $setupDir 'YurichConnectSetup.csproj') -c Release
      $publishedSetup = Join-Path $setupDir 'bin\Release\net9.0-windows\win-x64\publish\YurichConnect_Setup.exe'
      if (-not (Test-Path -LiteralPath $publishedSetup)) {
        throw "Installer publish did not produce $publishedSetup"
      }
      Copy-Item -LiteralPath $publishedSetup -Destination $setupExe -Force
    } finally {
      Remove-Item -LiteralPath $setupPayload, $setupIcon -Force -ErrorAction SilentlyContinue
    }
  }
}

Invoke-Step 'Installer safety scan' {
  if (-not (Test-Path -LiteralPath $setupExe)) {
    throw "Missing installer: $setupExe"
  }
  $pattern = 'C:\\Users\\ivan-|AndroidStudioProjects\\aurum_vpn_windows_repo|-----BEGIN (?:RSA |OPENSSH |EC |DSA )?PRIVATE KEY-----|vless://[0-9a-fA-F-]{32,}@|naive\+https://[^:\s]+:[^@\s]+@|hysteria2://[^@\s]+@|hy2://[^@\s]+@|access_token["=:\s]+[A-Za-z0-9._-]{20,}|refresh_token["=:\s]+[A-Za-z0-9._-]{20,}|(?:Remnawave|Yurich ID)[^\r\n]+https?://'
  $matches = @(rg -a -n $pattern $setupExe 2>$null)
  if ($matches.Count -gt 0) {
    throw "Installer safety scan found sensitive/dev data:`n$($matches -join [Environment]::NewLine)"
  }
  Write-Host "Installer safety scan OK"
}

Invoke-Step 'Release hashes' {
  $portableHash = Get-FileHash -Algorithm SHA256 -LiteralPath $portableZip
  Write-Host ("{0}  {1}" -f $portableHash.Hash, $portableHash.Path)
  if (Test-Path -LiteralPath $setupExe) {
    $setupHash = Get-FileHash -Algorithm SHA256 -LiteralPath $setupExe
    Write-Host ("{0}  {1}" -f $setupHash.Hash, $setupHash.Path)
  }
}
