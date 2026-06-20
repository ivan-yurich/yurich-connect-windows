param(
  [int]$DurationSeconds = 300,
  [int]$Concurrency = 24,
  [string]$Proxy = 'http://127.0.0.1:20808'
)

$ErrorActionPreference = 'Stop'

$loadTest = Join-Path $PSScriptRoot 'load_test_windows.ps1'
if (-not (Test-Path -LiteralPath $loadTest)) {
  throw "Base load test script not found: $loadTest"
}

Write-Host 'Yurich Connect VLESS load test.'
Write-Host 'Before running, connect a VLESS profile in Yurich Connect.'

& $loadTest `
  -DurationSeconds $DurationSeconds `
  -Concurrency $Concurrency `
  -Proxy $Proxy `
  -Urls @(
    'https://cp.cloudflare.com/generate_204',
    'https://connectivitycheck.gstatic.com/generate_204',
    'https://www.msftconnecttest.com/connecttest.txt',
    'https://chatgpt.com/',
    'https://www.cloudflare.com/cdn-cgi/trace'
  )
