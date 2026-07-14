param(
  [int]$DurationMinutes = 60,
  [int]$Concurrency = 12,
  [int]$SampleIntervalSeconds = 10,
  [string]$Proxy = 'http://127.0.0.1:20808',
  [double]$MaxErrorRatePercent = 1.0,
  [int]$MaxP99Milliseconds = 5000,
  [int]$MaxMemoryGrowthMb = 256,
  [switch]$NoFailOnThreshold
)

$ErrorActionPreference = 'Stop'

if ($DurationMinutes -lt 1) {
  throw 'DurationMinutes must be at least 1.'
}
if ($Concurrency -lt 1 -or $Concurrency -gt 128) {
  throw 'Concurrency must be between 1 and 128.'
}
if ($SampleIntervalSeconds -lt 2 -or $SampleIntervalSeconds -gt 300) {
  throw 'SampleIntervalSeconds must be between 2 and 300.'
}

$proxyUri = [Uri]$Proxy
if ($proxyUri.Scheme -notin @('http', 'https') -or $proxyUri.Port -le 0) {
  throw "Unsupported proxy address: $Proxy"
}

function Get-ListeningProcessId {
  param([int]$Port)

  $pattern = "^\s*TCP\s+\S+:$Port\s+\S+\s+LISTENING\s+(\d+)\s*$"
  foreach ($line in @(netstat -ano -p tcp)) {
    if ($line -match $pattern) {
      return [int]$Matches[1]
    }
  }
  return $null
}

$loadTest = Join-Path $PSScriptRoot 'load_test_windows.ps1'
if (-not (Test-Path -LiteralPath $loadTest)) {
  throw "Base load test script not found: $loadTest"
}

$appData = if ([string]::IsNullOrWhiteSpace($env:APPDATA)) {
  Join-Path $env:USERPROFILE '.yurich_connect'
} else {
  Join-Path $env:APPDATA 'Yurich Connect'
}
$diagnosticsDir = Join-Path $appData 'diagnostics'
New-Item -ItemType Directory -Path $diagnosticsDir -Force | Out-Null

$coreProcessId = Get-ListeningProcessId -Port $proxyUri.Port
if ($null -eq $coreProcessId) {
  throw "No Yurich Core listener found on port $($proxyUri.Port). Connect VPN before running the soak test."
}

$appProcess = Get-Process -Name 'YurichConnect' -ErrorAction SilentlyContinue |
  Sort-Object StartTime -Descending |
  Select-Object -First 1
$appProcessId = if ($null -eq $appProcess) { 0 } else { $appProcess.Id }
$startedAt = Get-Date
$durationSeconds = $DurationMinutes * 60
$deadlineText = $startedAt.ToUniversalTime().AddSeconds($durationSeconds).ToString('o')

Write-Host 'Yurich Connect soak test started.'
Write-Host "Duration: $DurationMinutes minute(s), concurrency: $Concurrency"
Write-Host "Proxy: $Proxy, core PID: $coreProcessId, app PID: $appProcessId"

$monitorJob = Start-Job -ArgumentList @(
  $deadlineText,
  $SampleIntervalSeconds,
  $proxyUri.Host,
  $proxyUri.Port,
  $coreProcessId,
  $appProcessId
) -ScriptBlock {
  param(
    [string]$Deadline,
    [int]$IntervalSeconds,
    [string]$ProxyHost,
    [int]$ProxyPort,
    [int]$CorePid,
    [int]$AppPid
  )

  $deadlineUtc = [DateTime]::Parse(
    $Deadline,
    [Globalization.CultureInfo]::InvariantCulture,
    [Globalization.DateTimeStyles]::RoundtripKind
  )

  while ([DateTime]::UtcNow -lt $deadlineUtc) {
    $portOk = $false
    $client = [Net.Sockets.TcpClient]::new()
    try {
      $connect = $client.ConnectAsync($ProxyHost, $ProxyPort)
      $portOk = $connect.Wait([TimeSpan]::FromSeconds(2)) -and $client.Connected
    } catch {
      $portOk = $false
    } finally {
      $client.Dispose()
    }

    $core = Get-Process -Id $CorePid -ErrorAction SilentlyContinue
    $app = if ($AppPid -gt 0) {
      Get-Process -Id $AppPid -ErrorAction SilentlyContinue
    } else {
      $null
    }

    [pscustomobject]@{
      timestamp = [DateTime]::UtcNow.ToString('o')
      portOk = $portOk
      coreAlive = ($null -ne $core)
      coreWorkingSetMb = if ($null -eq $core) { $null } else { [Math]::Round($core.WorkingSet64 / 1MB, 2) }
      corePrivateMb = if ($null -eq $core) { $null } else { [Math]::Round($core.PrivateMemorySize64 / 1MB, 2) }
      coreHandles = if ($null -eq $core) { $null } else { $core.HandleCount }
      coreCpuSeconds = if ($null -eq $core) { $null } else { [Math]::Round($core.CPU, 2) }
      appTracked = ($AppPid -gt 0)
      appAlive = ($AppPid -le 0 -or $null -ne $app)
      appWorkingSetMb = if ($null -eq $app) { $null } else { [Math]::Round($app.WorkingSet64 / 1MB, 2) }
      appPrivateMb = if ($null -eq $app) { $null } else { [Math]::Round($app.PrivateMemorySize64 / 1MB, 2) }
      appHandles = if ($null -eq $app) { $null } else { $app.HandleCount }
      appCpuSeconds = if ($null -eq $app) { $null } else { [Math]::Round($app.CPU, 2) }
    }

    Start-Sleep -Seconds $IntervalSeconds
  }
}

$loadFailure = $null
try {
  & $loadTest `
    -DurationSeconds $durationSeconds `
    -Concurrency $Concurrency `
    -Proxy $Proxy
} catch {
  $loadFailure = $_.Exception.Message
} finally {
  if ($null -ne $loadFailure) {
    Stop-Job -Job $monitorJob -ErrorAction SilentlyContinue
  }
  Wait-Job -Job $monitorJob | Out-Null
}

$samples = @(Receive-Job -Job $monitorJob)
Remove-Job -Job $monitorJob -Force

$loadSummaryFile = Get-ChildItem -LiteralPath $diagnosticsDir -Filter 'load-test-*-summary.json' -File |
  Where-Object { $_.LastWriteTime -ge $startedAt.AddSeconds(-5) } |
  Sort-Object LastWriteTime -Descending |
  Select-Object -First 1
if ($null -eq $loadSummaryFile) {
  throw 'Load test summary was not produced.'
}
$loadSummary = Get-Content -LiteralPath $loadSummaryFile.FullName -Raw | ConvertFrom-Json

function Get-MemoryStats {
  param(
    [object[]]$Rows,
    [string]$Property
  )

  $values = @($Rows | ForEach-Object { $_.$Property } | Where-Object { $null -ne $_ })
  if ($values.Count -eq 0) {
    return [pscustomobject]@{ first = 0; last = 0; peak = 0; growth = 0 }
  }
  return [pscustomobject]@{
    first = [double]$values[0]
    last = [double]$values[-1]
    peak = [double](($values | Measure-Object -Maximum).Maximum)
    growth = [Math]::Round(([double]$values[-1] - [double]$values[0]), 2)
  }
}

$coreMemory = Get-MemoryStats -Rows $samples -Property 'corePrivateMb'
$appMemory = Get-MemoryStats -Rows $samples -Property 'appPrivateMb'
$portDownSamples = @($samples | Where-Object { -not $_.portOk }).Count
$coreExitSamples = @($samples | Where-Object { -not $_.coreAlive }).Count
$appExitSamples = @($samples | Where-Object { $_.appTracked -and -not $_.appAlive }).Count
$requests = [int64]$loadSummary.requests
$errors = [int64]$loadSummary.errors
$errorRatePercent = if ($requests -eq 0) {
  100.0
} else {
  [Math]::Round(($errors * 100.0 / $requests), 4)
}

$passed =
  $null -eq $loadFailure -and
  $requests -gt 0 -and
  $errorRatePercent -le $MaxErrorRatePercent -and
  [int]$loadSummary.p99ms -le $MaxP99Milliseconds -and
  $portDownSamples -eq 0 -and
  $coreExitSamples -eq 0 -and
  $appExitSamples -eq 0 -and
  $coreMemory.growth -le $MaxMemoryGrowthMb -and
  ($appProcessId -eq 0 -or $appMemory.growth -le $MaxMemoryGrowthMb)

$summary = [ordered]@{
  passed = $passed
  startedAt = $startedAt.ToString('o')
  finishedAt = (Get-Date).ToString('o')
  durationMinutes = $DurationMinutes
  concurrency = $Concurrency
  proxy = $Proxy
  coreProcessId = $coreProcessId
  appProcessId = $appProcessId
  samples = $samples.Count
  requests = $requests
  ok = [int64]$loadSummary.ok
  errors = $errors
  errorRatePercent = $errorRatePercent
  p50ms = [int]$loadSummary.p50ms
  p95ms = [int]$loadSummary.p95ms
  p99ms = [int]$loadSummary.p99ms
  portDownSamples = $portDownSamples
  coreExitSamples = $coreExitSamples
  appExitSamples = $appExitSamples
  corePrivateMemory = $coreMemory
  appPrivateMemory = $appMemory
  loadFailure = $loadFailure
  thresholds = [ordered]@{
    maxErrorRatePercent = $MaxErrorRatePercent
    maxP99Milliseconds = $MaxP99Milliseconds
    maxMemoryGrowthMb = $MaxMemoryGrowthMb
  }
}

$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$samplesPath = Join-Path $diagnosticsDir "soak-test-$timestamp-samples.csv"
$summaryPath = Join-Path $diagnosticsDir "soak-test-$timestamp-summary.json"
$zipPath = Join-Path $diagnosticsDir 'soak-report.zip'
$samples | Export-Csv -LiteralPath $samplesPath -NoTypeInformation -Encoding UTF8
$summary | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $summaryPath -Encoding UTF8
Compress-Archive -Path @(
  $samplesPath,
  $summaryPath,
  $loadSummaryFile.FullName
) -DestinationPath $zipPath -Force

Write-Host "Yurich Connect soak test result: $(if ($passed) { 'PASS' } else { 'FAIL' })"
Write-Host "Requests: $requests, errors: $errors ($errorRatePercent%), p95=$($summary.p95ms)ms, p99=$($summary.p99ms)ms"
Write-Host "Port down samples: $portDownSamples, core exit samples: $coreExitSamples, app exit samples: $appExitSamples"
Write-Host "Core private memory: $($coreMemory.first)MB -> $($coreMemory.last)MB, peak=$($coreMemory.peak)MB"
if ($appProcessId -gt 0) {
  Write-Host "App private memory: $($appMemory.first)MB -> $($appMemory.last)MB, peak=$($appMemory.peak)MB"
}
Write-Host "Report: $zipPath"

if (-not $passed -and -not $NoFailOnThreshold) {
  throw "Soak test thresholds failed. See $summaryPath"
}
