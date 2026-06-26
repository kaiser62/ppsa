# Test: Logger Module (M2)
$ErrorActionPreference = "Stop"

$modulePath = Join-Path $PSScriptRoot "..\modules\Logger.psm1"
Remove-Module Logger -ErrorAction SilentlyContinue
Import-Module $modulePath -Force

$testLogDir = Join-Path $env:TEMP "ppsa-test-logger-$(Get-Random)"
try {
    # Test 1: Initialize creates directory and cleans old logs
    Write-Host "[TEST] Initialize-Logger..." -ForegroundColor Cyan
    Initialize-Logger -LogDirectory $testLogDir -Levels @("TRACE","DEBUG","INFO","WARN","ERROR","SUCCESS")
    if (-not (Test-Path $testLogDir)) { throw "Log directory not created" }
    Write-Host "  PASS: Log directory created" -ForegroundColor Green

    # Test 2: Write-LogInfo writes to console and file
    Write-Host "[TEST] Write-LogInfo..." -ForegroundColor Cyan
    Write-LogInfo -Module "Test" -Message "hello info"
    $logFile = Join-Path $testLogDir "build.log"
    if (-not (Test-Path $logFile)) { throw "build.log not created" }
    $content = Get-Content $logFile
    if ($content -notmatch "INFO.*Test.*hello info") { throw "build.log missing expected content" }
    Write-Host "  PASS: build.log contains INFO message" -ForegroundColor Green

    # Test 3: Write-LogError includes extras
    Write-Host "[TEST] Write-LogError with extras..." -ForegroundColor Cyan
    Write-LogError -Module "Test" -Message "something broke" -Command "do-thing" -ExitCode 1 -Location "script.ps1:42" -RecommendedAction "check config"
    $content = Get-Content $logFile
    $last = $content[-1]
    if ($last -notmatch "ERROR.*something broke") { throw "error line missing message" }
    if ($last -notmatch "cmd: do-thing") { throw "error line missing command" }
    if ($last -notmatch "exit: 1") { throw "error line missing exit code" }
    if ($last -notmatch "at: script.ps1:42") { throw "error line missing location" }
    if ($last -notmatch "action: check config") { throw "error line missing recommended action" }
    Write-Host "  PASS: Error log includes all fields" -ForegroundColor Green

    # Test 4: error.log is separate
    Write-Host "[TEST] error.log..." -ForegroundColor Cyan
    $errFile = Join-Path $testLogDir "error.log"
    if (-not (Test-Path $errFile)) { throw "error.log not created" }
    $errContent = Get-Content $errFile
    if ($errContent.Count -lt 1) { throw "error.log is empty" }
    Write-Host "  PASS: error.log created with content" -ForegroundColor Green

    # Test 5: TRACE goes to trace.log
    Write-Host "[TEST] trace.log..." -ForegroundColor Cyan
    Write-LogTrace -Module "Test" -Message "verbose detail"
    $traceFile = Join-Path $testLogDir "trace.log"
    if (-not (Test-Path $traceFile)) { throw "trace.log not created" }
    $traceContent = Get-Content $traceFile
    if ($traceContent -notmatch "TRACE.*verbose detail") { throw "trace.log missing content" }
    Write-Host "  PASS: trace.log created with content" -ForegroundColor Green

    # Test 6: Timing
    Write-Host "[TEST] Start-Timer / Stop-Timer..." -ForegroundColor Cyan
    $sw = Start-Timer
    Start-Sleep -Milliseconds 10
    $elapsed = Stop-Timer -Stopwatch $sw -Module "Test" -Operation "sleep"
    if ($elapsed.TotalMilliseconds -lt 5) { throw "timer reported too little time" }
    Write-Host "  PASS: Timer measured $($elapsed.TotalMilliseconds.ToString('F1'))ms" -ForegroundColor Green

    # Test 7: Measure-Phase success path
    Write-Host "[TEST] Measure-Phase (success)..." -ForegroundColor Cyan
    $result = Measure-Phase -Module "Test" -Name "success-phase" -ScriptBlock { return 42 }
    if ($result -ne 42) { throw "Measure-Phase did not return script block value" }
    Write-Host "  PASS: Measure-Phase returned correct value" -ForegroundColor Green

    # Test 8: Measure-Phase error path
    Write-Host "[TEST] Measure-Phase (error)..." -ForegroundColor Cyan
    $caught = $false
    try {
        Measure-Phase -Module "Test" -Name "fail-phase" -ScriptBlock { throw "intentional failure" }
    } catch {
        $caught = $true
        if ($_ -notmatch "intentional failure") { throw "unexpected error message" }
    }
    if (-not $caught) { throw "Measure-Phase did not propagate error" }
    Write-Host "  PASS: Measure-Phase propagated error" -ForegroundColor Green

    Write-Host "`n[SUCCESS] All logger tests passed!" -ForegroundColor Green
} finally {
    Remove-Item $testLogDir -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Module Logger -ErrorAction SilentlyContinue
}
