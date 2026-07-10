param(
  [int]$DurationSeconds = 300,
  [int]$Concurrency = 16,
  [string]$Proxy = 'http://127.0.0.1:20808',
  [string[]]$Urls = @(
    'https://cp.cloudflare.com/generate_204',
    'https://connectivitycheck.gstatic.com/generate_204',
    'http://www.msftconnecttest.com/connecttest.txt',
    'https://chatgpt.com/'
  )
)

$ErrorActionPreference = 'Stop'

if ($DurationSeconds -lt 10) {
  throw 'DurationSeconds must be at least 10.'
}
if ($Concurrency -lt 1 -or $Concurrency -gt 128) {
  throw 'Concurrency must be between 1 and 128.'
}

$appData = if ([string]::IsNullOrWhiteSpace($env:APPDATA)) {
  Join-Path $env:USERPROFILE '.yurich_connect'
} else {
  Join-Path $env:APPDATA 'Yurich Connect'
}
$diagnosticsDir = Join-Path $appData 'diagnostics'
New-Item -ItemType Directory -Path $diagnosticsDir -Force | Out-Null

$startedAt = Get-Date
$deadline = $startedAt.ToUniversalTime().AddSeconds($DurationSeconds).ToString('o')

$jobs = for ($worker = 0; $worker -lt $Concurrency; $worker++) {
  Start-Job -ArgumentList $worker, $deadline, $Proxy, $Urls -ScriptBlock {
    param(
      [int]$WorkerId,
      [string]$DeadlineText,
      [string]$ProxyText,
      [string[]]$WorkerUrls
    )

    Add-Type -AssemblyName System.Net.Http
    $deadlineUtc = [DateTime]::Parse(
      $DeadlineText,
      [Globalization.CultureInfo]::InvariantCulture,
      [Globalization.DateTimeStyles]::RoundtripKind
    )
    $handler = [System.Net.Http.HttpClientHandler]::new()
    $handler.Proxy = [System.Net.WebProxy]::new([Uri]$ProxyText)
    $handler.UseProxy = $true
    $handler.AllowAutoRedirect = $false
    $client = [System.Net.Http.HttpClient]::new($handler)
    $client.Timeout = [TimeSpan]::FromSeconds(12)
    $client.DefaultRequestHeaders.UserAgent.ParseAdd('YurichConnectLoadTest/1.0')
    $random = [System.Random]::new($WorkerId + [Environment]::TickCount)

    try {
      while ([DateTime]::UtcNow -lt $deadlineUtc) {
        $url = $WorkerUrls[$random.Next(0, $WorkerUrls.Length)]
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $status = 0
        $errorText = $null
        try {
          $response = $client.GetAsync($url).GetAwaiter().GetResult()
          $status = [int]$response.StatusCode
          $response.Dispose()
        } catch {
          $errorText = $_.Exception.Message
        } finally {
          $sw.Stop()
          [pscustomobject]@{
            time = [DateTime]::UtcNow.ToString('o')
            worker = $WorkerId
            url = $url
            status = $status
            ms = $sw.ElapsedMilliseconds
            ok = ($status -ge 200 -and $status -lt 500 -and $null -eq $errorText)
            error = $errorText
          }
        }
      }
    } finally {
      $client.Dispose()
    }
  }
}

Wait-Job -Job $jobs | Out-Null
$rows = @(Receive-Job -Job $jobs | Sort-Object time)
Remove-Job -Job $jobs -Force
$latencies = @($rows | Where-Object { $_.ok } | ForEach-Object { [int64]$_.ms } | Sort-Object)
$errors = @($rows | Where-Object { -not $_.ok })

function Percentile {
  param(
    [long[]]$Values,
    [int]$Percentile
  )
  if ($Values.Count -eq 0) {
    return 0
  }
  $index = [Math]::Round(($Values.Count - 1) * $Percentile / 100)
  return $Values[[int]$index]
}

$summary = [ordered]@{
  startedAt = $startedAt.ToString('o')
  finishedAt = (Get-Date).ToString('o')
  durationSeconds = $DurationSeconds
  concurrency = $Concurrency
  proxy = $Proxy
  requests = $rows.Count
  ok = ($rows.Count - $errors.Count)
  errors = $errors.Count
  p50ms = Percentile -Values $latencies -Percentile 50
  p95ms = Percentile -Values $latencies -Percentile 95
  p99ms = Percentile -Values $latencies -Percentile 99
  urls = $Urls
}

$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$jsonPath = Join-Path $diagnosticsDir "load-test-$timestamp.json"
$csvPath = Join-Path $diagnosticsDir "load-test-$timestamp.csv"
$summaryPath = Join-Path $diagnosticsDir "load-test-$timestamp-summary.json"
$zipPath = Join-Path $diagnosticsDir 'report.zip'

$rows | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $jsonPath -Encoding UTF8
$rows | Export-Csv -LiteralPath $csvPath -NoTypeInformation -Encoding UTF8
$summary | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $summaryPath -Encoding UTF8
Compress-Archive -Path @($jsonPath, $csvPath, $summaryPath) -DestinationPath $zipPath -Force

Write-Host "Yurich Connect load test complete."
Write-Host "Requests: $($summary.requests), ok: $($summary.ok), errors: $($summary.errors)"
Write-Host "Latency: p50=$($summary.p50ms)ms p95=$($summary.p95ms)ms p99=$($summary.p99ms)ms"
Write-Host "Report: $zipPath"
