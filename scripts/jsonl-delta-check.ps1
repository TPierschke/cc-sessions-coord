param(
  [string]$BasePath = (Join-Path $env:USERPROFILE '.claude\projects'),
  [int]$Seconds = 60
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path -LiteralPath $BasePath)) {
  throw "BasePath not found: $BasePath"
}

Write-Host "JSONL Delta Check" -ForegroundColor Yellow
Write-Host "Path: $BasePath"
Write-Host "Window: $Seconds seconds"

$t1 = Get-Date
$c1 = (Get-ChildItem -Path $BasePath -Recurse -File -Filter "*.jsonl" -ErrorAction Stop | Measure-Object).Count

Start-Sleep -Seconds $Seconds

$t2 = Get-Date
$c2 = (Get-ChildItem -Path $BasePath -Recurse -File -Filter "*.jsonl" -ErrorAction Stop | Measure-Object).Count
$delta = $c2 - $c1

Write-Host ""
Write-Host ("T1={0:HH:mm:ss} COUNT1={1}" -f $t1, $c1)
Write-Host ("T2={0:HH:mm:ss} COUNT2={1}" -f $t2, $c2)
Write-Host ("DELTA_{0}S={1}" -f $Seconds, $delta) -ForegroundColor Cyan

if ($delta -eq 0) {
  Write-Host "OK: Kein Wachstum in diesem Zeitfenster." -ForegroundColor Green
} else {
  Write-Host "WARNUNG: Neue JSONL-Dateien erkannt." -ForegroundColor Red
}
