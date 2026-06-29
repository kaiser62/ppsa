# Test: SmokeTest Module (M10)
$ErrorActionPreference = "Stop"

$modules = @("Logger", "Utils", "VirtualBox")
foreach ($m in $modules) {
    Remove-Module $m -ErrorAction SilentlyContinue
    Import-Module (Join-Path $PSScriptRoot "..\modules\$m.psm1") -Force
}
$testLogDir = Join-Path $env:TEMP "ppsa-test-smoke-$(Get-Random)"
Initialize-Logger -LogDirectory $testLogDir

$modulePath = Join-Path $PSScriptRoot "..\modules\SmokeTest.psm1"
Remove-Module SmokeTest -ErrorAction SilentlyContinue
Import-Module $modulePath -Force

# Unit tests (no VBox/VDI required)
Write-Host "[TEST] Test-VmBootHealthy (clean)..." -ForegroundColor Cyan
$h = Test-VmBootHealthy -ConsoleText "Debian GNU/Linux 13 ppsa ttyS0`nppsa login:"
if (-not $h.Healthy) { throw "Healthy boot was flagged unhealthy: $($h.Reason)" }
Write-Host "  PASS" -ForegroundColor Green

Write-Host "[TEST] Test-VmBootHealthy (kernel panic)..." -ForegroundColor Cyan
$h = Test-VmBootHealthy -ConsoleText "Kernel panic - not syncing: VFS: Unable to mount root fs"
if ($h.Healthy) { throw "Kernel panic was not detected" }
if ($h.Reason -notmatch "Kernel panic") { throw "Wrong reason: $($h.Reason)" }
Write-Host "  PASS" -ForegroundColor Green

Write-Host "[TEST] Test-VmBootHealthy (OOM)..." -ForegroundColor Cyan
$h = Test-VmBootHealthy -ConsoleText "Out of memory: Killed process 1 (systemd) total-vm"
if ($h.Healthy) { throw "OOM was not detected" }
Write-Host "  PASS" -ForegroundColor Green

Write-Host "[TEST] Test-VmBootHealthy (empty)..." -ForegroundColor Cyan
$h = Test-VmBootHealthy -ConsoleText ""
if ($h.Healthy) { throw "Empty log should be unhealthy" }
Write-Host "  PASS" -ForegroundColor Green

Write-Host "[TEST] Test-VmWebUiReachable (unreachable)..." -ForegroundColor Cyan
$p = Test-VmWebUiReachable -Url "http://127.0.0.1:1" -ProbePath "/" -TimeoutSeconds 2
if ($p.Reachable) { throw "Port 1 should be unreachable" }
if (-not $p.Error) { throw "Error message missing" }
Write-Host "  PASS (error captured: $($p.Error.Substring(0, [Math]::Min(60, $p.Error.Length)))...)" -ForegroundColor Green

# Integration test requires VirtualBox + a VDI
if (-not (Test-VBoxManageAvailable)) {
    Write-Host "`n[SKIP] VBoxManage not installed, skipping integration test" -ForegroundColor Yellow
    Write-Host "`n[Success] All SmokeTest unit tests passed!" -ForegroundColor Green
    return
}

# Make a tiny throwaway VDI if needed
$tmpVdi = Join-Path $env:TEMP "ppsa-smoke-$(Get-Random).vdi"
try {
    Write-Host "[TEST] Creating scratch VDI..." -ForegroundColor Cyan
    $null = Invoke-VBoxManage -Arguments @("createmedium", "disk", "--filename", $tmpVdi, "--size", "10", "--format", "VDI")
    if (-not (Test-Path $tmpVdi)) { throw "scratch VDI not created" }
    Write-Host "  PASS" -ForegroundColor Green

    $cfg = Get-Content (Join-Path $PSScriptRoot "..\builder.json") -Raw | ConvertFrom-Json
    $cfg.virtualbox.vm_name = "ppsa-smoke-$(Get-Random -Minimum 1000 -Maximum 9999)"
    $cfg.smoke_test.boot_timeout_seconds = 30   # tiny scratch VDI will not boot a real OS
    $cfg.smoke_test.webui_url = $null
    $cfg.smoke_test.auto_shutdown = $true

    Write-Host "[TEST] Invoke-SmokeTest (scratch VDI, expect boot-timeout fail)..." -ForegroundColor Cyan
    $r = Invoke-SmokeTest -Config $cfg -VdiPath $tmpVdi
    if ($r.Phases.Count -lt 3) { throw "Phase count too low: $($r.Phases.Count)" }
    $shutdown = $r.Phases | Where-Object { $_.Name -eq "shutdown" } | Select-Object -First 1
    if (-not $shutdown -or -not $shutdown.Success) { throw "Shutdown phase missing or failed" }
    Write-Host "  PASS (phases=$($r.Phases.Count), success=$($r.Success))" -ForegroundColor Green

    Write-Host "[TEST] Save-SmokeTestResult..." -ForegroundColor Cyan
    $outDir = Join-Path $env:TEMP "ppsa-smoke-out-$(Get-Random)"
    $path = Save-SmokeTestResult -Result $r -OutputDir $outDir
    if (-not (Test-Path $path)) { throw "smoke-test.json not written" }
    $loaded = Get-Content $path -Raw | ConvertFrom-Json
    if (-not $loaded.VmName) { throw "smoke-test.json missing VmName" }
    Remove-Item $outDir -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host "  PASS" -ForegroundColor Green
} finally {
    Remove-Item $tmpVdi -Force -ErrorAction SilentlyContinue
    $vmName = (Get-Content (Join-Path $PSScriptRoot "..\builder.json") -Raw | ConvertFrom-Json).virtualbox.vm_name
    Remove-TestVm -Name $vmName -Force -ErrorAction SilentlyContinue
}

Write-Host "`n[Success] All SmokeTest tests passed!" -ForegroundColor Green
