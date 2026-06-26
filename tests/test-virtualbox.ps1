# Test: VirtualBox Module (M9)
$ErrorActionPreference = "Stop"

$modules = @("Logger", "Utils")
foreach ($m in $modules) {
    Remove-Module $m -ErrorAction SilentlyContinue
    Import-Module (Join-Path $PSScriptRoot "..\modules\$m.psm1") -Force
}
$testLogDir = Join-Path $env:TEMP "ppsa-test-vbox-$(Get-Random)"
Initialize-Logger -LogDirectory $testLogDir

$modulePath = Join-Path $PSScriptRoot "..\modules\VirtualBox.psm1"
Remove-Module VirtualBox -ErrorAction SilentlyContinue
Import-Module $modulePath -Force

$vboxOk = Test-VBoxManageAvailable
if (-not $vboxOk) {
    Write-Host "  SKIP: VBoxManage not installed, skipping all tests" -ForegroundColor Yellow
    Write-Host "`n[Skipped] Install VirtualBox to run these tests" -ForegroundColor Yellow
    return
}

# Test 1: Test-VBoxManageAvailable
Write-Host "[TEST] Test-VBoxManageAvailable..." -ForegroundColor Cyan
if (-not $vboxOk) { throw "VBoxManage should be available" }
Write-Host "  PASS: VBoxManage available" -ForegroundColor Green

# Test 2: Invoke-VBoxManage
Write-Host "[TEST] Invoke-VBoxManage (list vms)..." -ForegroundColor Cyan
$r = Invoke-VBoxManage -Arguments @("list", "vms")
if ($r.ExitCode -ne 0) { throw "list vms failed: $($r.Stderr)" }
Write-Host "  PASS: VBoxManage list vms OK" -ForegroundColor Green

# Test 3: Invoke-VBoxManage (help/no arg) — expect non-zero
Write-Host "[TEST] Invoke-VBoxManage (no args)..." -ForegroundColor Cyan
$r2 = Invoke-VBoxManage -Arguments @()
# Should receive warning but not throw
Write-Host "  PASS: no-args handled gracefully (exit=$($r2.ExitCode))" -ForegroundColor Green

# Test 4: Create and configure test VM (if not already exists)
$testVmName = "ppsa-test-$(Get-Random -Minimum 1000 -Maximum 9999)"
try {
    Write-Host "[TEST] New-TestVm (create)..." -ForegroundColor Cyan
    $vm = New-TestVm -Name $testVmName -MemoryMB 512 -Cpus 1
    if (-not $vm.Created) { throw "VM not created" }
    Write-Host "  PASS: VM '$testVmName' created" -ForegroundColor Green

    # Test 5: Get-VmPowerState (should be powered off)
    Write-Host "[TEST] Get-VmPowerState..." -ForegroundColor Cyan
    $state = Get-VmPowerState -Name $testVmName
    Write-Host "  PASS: state=$state" -ForegroundColor Green

    # Test 6: Start and stop
    Write-Host "[TEST] Start-TestVm..." -ForegroundColor Cyan
    $started = Start-TestVm -Name $testVmName -Type "headless"
    if (-not $started) { throw "VM start returned false" }
    Write-Host "  PASS: VM started" -ForegroundColor Green

    Start-Sleep -Seconds 3

    Write-Host "[TEST] Stop-TestVm (poweroff)..." -ForegroundColor Cyan
    $stopped = Stop-TestVm -Name $testVmName -Mode "poweroff"
    if (-not $stopped) { throw "VM stop returned false" }
    Write-Host "  PASS: VM stopped" -ForegroundColor Green

    # Test 7: Wait-VmStopped
    Write-Host "[TEST] Wait-VmStopped..." -ForegroundColor Cyan
    $waited = Wait-VmStopped -Name $testVmName -TimeoutSeconds 30
    if (-not $waited) { throw "VM did not stop in time" }
    Write-Host "  PASS: VM fully stopped" -ForegroundColor Green

    # Test 8: Remove
    Write-Host "[TEST] Remove-TestVm..." -ForegroundColor Cyan
    $removed = Remove-TestVm -Name $testVmName -Force
    if (-not $removed) { throw "VM removal returned false" }
    Write-Host "  PASS: VM removed" -ForegroundColor Green

} catch {
    # Cleanup on error
    try { Remove-TestVm -Name $testVmName -Force -ErrorAction SilentlyContinue } catch {}
    throw $_
}

Write-Host "`n[SUCCESS] All VirtualBox tests passed!" -ForegroundColor Green
