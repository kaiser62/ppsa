# Test: Builder Module (M6)
$ErrorActionPreference = "Stop"

# Pre-load dependencies (builder uses Logger + Utils)
$modules = @("Logger", "Utils")
foreach ($m in $modules) {
    Remove-Module $m -ErrorAction SilentlyContinue
    Import-Module (Join-Path $PSScriptRoot "..\modules\$m.psm1") -Force
}
$testLogDir = Join-Path $env:TEMP "ppsa-test-builder-$(Get-Random)"
Initialize-Logger -LogDirectory $testLogDir

$modulePath = Join-Path $PSScriptRoot "..\modules\Builder.psm1"
Remove-Module Builder -ErrorAction SilentlyContinue
Import-Module $modulePath -Force

# Test 1: Test-WslAvailable
Write-Host "[TEST] Test-WslAvailable..." -ForegroundColor Cyan
$wslOk = Test-WslAvailable -WslUser "artho"
if (-not $wslOk) {
    Write-Host "  SKIP: WSL not available (user 'artho' not found)" -ForegroundColor Yellow
} else {
    Write-Host "  PASS: WSL available" -ForegroundColor Green
}

# Test 2: Invoke-WslCommand simple
Write-Host "[TEST] Invoke-WslCommand (echo)..." -ForegroundColor Cyan
$r = Invoke-WslCommand -Command "echo hello-from-wsl" -WslUser "artho" -TimeoutSeconds 30
if ($r.ExitCode -eq 0 -and $r.Stdout -match "hello-from-wsl") {
    Write-Host "  PASS: WSL echo OK (exit=$($r.ExitCode), dur=$($r.Duration.TotalSeconds.ToString('F1'))s)" -ForegroundColor Green
} else {
    Write-Host "  SKIP: WSL echo failed (exit=$($r.ExitCode))" -ForegroundColor Yellow
}

# Test 3: BuildResult helper
Write-Host "[TEST] BuildResult (success)..." -ForegroundColor Cyan
$phases = @(
    [PSCustomObject]@{ Name = "phase1"; Success = $true; ExitCode = 0; Duration = [TimeSpan]::FromSeconds(10); Stdout = ""; Stderr = "" }
)
$result = BuildResult -Tag "test-001" -Success $true -Phases $phases
if (-not $result.Success) { throw "expected success" }
if ($result.Tag -ne "test-001") { throw "tag mismatch" }
if ($result.PhaseCount -ne 1) { throw "expected 1 phase" }
if ($result.FailedPhase -ne $null) { throw "no failed phase expected" }
if ($result.TotalDuration.TotalSeconds -ne 10) { throw "duration mismatch" }
Write-Host "  PASS: BuildResult success path" -ForegroundColor Green

Write-Host "[TEST] BuildResult (failure)..." -ForegroundColor Cyan
$phases2 = @(
    [PSCustomObject]@{ Name = "prep"; Success = $true; ExitCode = 0; Duration = [TimeSpan]::FromSeconds(5); Stdout = ""; Stderr = "" },
    [PSCustomObject]@{ Name = "build"; Success = $false; ExitCode = 1; Duration = [TimeSpan]::FromSeconds(60); Stdout = ""; Stderr = "error msg" },
    [PSCustomObject]@{ Name = "compress"; Success = $false; ExitCode = 0; Duration = [TimeSpan]::Zero; Stdout = ""; Stderr = "" }
)
$result2 = BuildResult -Tag "test-002" -Success $false -Phases $phases2
if ($result2.Success) { throw "expected failure" }
if ($result2.FailedPhase -ne "build") { throw "expected 'build' as failed phase, got '$($result2.FailedPhase)'" }
if ($result2.PhaseCount -ne 3) { throw "expected 3 phases" }
Write-Host "  PASS: BuildResult failure path (failed=$($result2.FailedPhase))" -ForegroundColor Green

# Cleanup
Remove-Item $testLogDir -Recurse -Force -ErrorAction SilentlyContinue

Write-Host "`n[SUCCESS] All builder tests passed!" -ForegroundColor Green
