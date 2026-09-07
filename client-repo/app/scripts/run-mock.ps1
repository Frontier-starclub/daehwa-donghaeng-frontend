param(
    [string]$Device = 'chrome',
    [ValidateSet('success', 'empty', 'error', 'timeout')]
    [string]$Scenario = 'success'
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
Push-Location -LiteralPath $appRoot
try {
    & $flutterExecutable pub get
    if ($LASTEXITCODE -ne 0) { throw 'flutter pub get 실패' }
    & $flutterExecutable run -d $Device '--dart-define=USE_MOCK=true' "--dart-define=MOCK_OCR_SCENARIO=$Scenario"
    if ($LASTEXITCODE -ne 0) { throw 'Flutter 실행 실패' }
} finally {
    Pop-Location
}
