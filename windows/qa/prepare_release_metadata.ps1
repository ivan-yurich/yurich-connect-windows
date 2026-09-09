param(
  [ValidatePattern('^\d+\.\d+\.\d+$')]
  [string]$Version = '',
  [switch]$ValidateOnly
)

$ErrorActionPreference = 'Stop'
$projectRoot = Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')
$releaseDir = Join-Path $projectRoot 'release\windows'
$changelogPath = Join-Path $projectRoot 'CHANGELOG.md'
$pubspecPath = Join-Path $projectRoot 'pubspec.yaml'
$versionMatch = Select-String -Path $pubspecPath -Pattern '^version:\s*(\d+\.\d+\.\d+)(?:\+(\d+))?\s*$'
if ($null -eq $versionMatch) {
  throw 'Could not read the Windows version from pubspec.yaml.'
}
$pubspecVersion = $versionMatch.Matches[0].Groups[1].Value
if ([string]::IsNullOrWhiteSpace($Version)) {
  $Version = $pubspecVersion
} elseif ($Version -ne $pubspecVersion) {
  throw "Requested release version $Version does not match pubspec.yaml version $pubspecVersion."
}

$requiredMetadata = @(
  @{ Path = 'lib\src\screens\home_screen.dart'; Value = "const _appVersion = '$Version';" },
  @{ Path = 'lib\src\services\profile_importer.dart'; Value = "YurichConnect-Windows/$Version " },
  @{ Path = 'windows\installer\install_yurich_connect.ps1'; Value = "'DisplayVersion' -Value '$Version'" },
  @{ Path = 'windows\installer\setup\Program.cs'; Value = "AppVersion = `"$Version`"" },
  @{ Path = 'windows\installer\setup\YurichConnectSetup.csproj'; Value = "<Version>$Version</Version>" },
  @{ Path = 'windows\installer\setup\YurichConnectSetup.csproj'; Value = "<FileVersion>$Version.0</FileVersion>" }
)

foreach ($metadata in $requiredMetadata) {
  $path = Join-Path $projectRoot $metadata.Path
  if (-not (Test-Path -LiteralPath $path)) {
    throw "Version metadata file is missing: $path"
  }
  $content = Get-Content -LiteralPath $path -Raw
  if (-not $content.Contains($metadata.Value)) {
    throw "Version $Version is not synchronized in $($metadata.Path): expected '$($metadata.Value)'"
  }
}

$changelog = Get-Content -LiteralPath $changelogPath -Raw
$escapedVersion = [regex]::Escape($Version)
$sectionMatch = [regex]::Match(
  $changelog,
  "(?ms)^##\s+$escapedVersion(?:\s+-[^\r\n]+)?\s*\r?\n.*?(?=^##\s+|\z)"
)
if (-not $sectionMatch.Success) {
  throw "CHANGELOG.md has no section for version $Version."
}

Write-Host "Version metadata is synchronized for $Version."
if ($ValidateOnly) {
  return
}

if (-not (Test-Path -LiteralPath $releaseDir)) {
  throw "Release directory is missing: $releaseDir"
}

$artifacts = @(
  (Join-Path $releaseDir 'YurichConnect_Setup.exe')
  (Join-Path $releaseDir 'YurichConnect_Windows_Portable.zip')
)
$hashLines = foreach ($artifact in $artifacts) {
  if (-not (Test-Path -LiteralPath $artifact)) {
    throw "Release artifact is missing: $artifact"
  }
  $hash = (Get-FileHash -LiteralPath $artifact -Algorithm SHA256).Hash.ToUpperInvariant()
  $line = "$hash  $([IO.Path]::GetFileName($artifact))"
  Set-Content -LiteralPath "$artifact.sha256" -Value $line -Encoding ASCII
  $line
}

$checksumPath = Join-Path $releaseDir 'SHA256SUMS.txt'
Set-Content -LiteralPath $checksumPath -Value $hashLines -Encoding ASCII

$releaseNotesPath = Join-Path $releaseDir 'RELEASE_NOTES.md'
$hashBlock = ($hashLines | ForEach-Object { "    $_" }) -join [Environment]::NewLine
$releaseNotes = @"
# Yurich Connect for Windows v$Version

**Статус:** Public Beta / Release Candidate.

$($sectionMatch.Value.Trim())

## SHA-256

$hashBlock

Сборка пока не подписана цифровой подписью, поэтому Windows SmartScreen может показать предупреждение. Скачивайте файлы только из официального репозитория Yurich Connect и сверяйте SHA-256.
"@
Set-Content -LiteralPath $releaseNotesPath -Value $releaseNotes -Encoding UTF8

foreach ($path in @(
  $artifacts[0],
  "$($artifacts[0]).sha256",
  $artifacts[1],
  "$($artifacts[1]).sha256",
  $checksumPath,
  $releaseNotesPath
)) {
  $item = Get-Item -LiteralPath $path
  Write-Host ("Prepared {0} ({1} bytes)" -f $item.Name, $item.Length)
}
