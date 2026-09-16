param(
    [string]$Device = 'chrome',
    [string]$ApiBaseUrl = ''
)
$ErrorActionPreference = 'Stop'
$appRoot = Split-Path -Parent $PSScriptRoot
$taskRoot = Split-Path -Parent (Split-Path -Parent $appRoot)
$bundledFlutter = Join-Path $taskRoot 'output/tooling/flutter/bin/flutter.bat'
$installedFlutter = Get-Command flutter -ErrorAction SilentlyContinue
if ($installedFlutter) {
    $flutterExecutable = $installedFlutter.Source
} elseif (Test-Path -LiteralPath $bundledFlutter) {
    $flutterExecutable = $bundledFlutter
} else {
    throw 'Flutter SDK를 설치하고 PATH에 추가해 주세요.'
}
if (-not $ApiBaseUrl) {
    $ApiBaseUrl = if ($Device -in @('chrome', 'edge', 'web-server')) {
        'http://localhost:8090/api/v1'
    } else {
        'http://10.0.2.2:8090/api/v1'
    }
}
$runArguments = @('run', '-d', $Device, '--dart-define=USE_MOCK=false', "--dart-define=API_BASE_URL=$($ApiBaseUrl.TrimEnd('/'))")
if ($Device -in @('chrome', 'edge', 'web-server')) {
    $runArguments += @('--web-hostname=localhost', '--web-port=3000')
}
Push-Location -LiteralPath $appRoot
try {
    & $flutterExecutable pub get
    if ($LASTEXITCODE -ne 0) { throw 'flutter pub get 실패' }
    & $flutterExecutable @runArguments
    if ($LASTEXITCODE -ne 0) { throw 'Flutter 실행 실패' }
} finally {
    Pop-Location
}
