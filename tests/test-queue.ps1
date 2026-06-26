# Test: Queue Module (M5)
$ErrorActionPreference = "Stop"

$modulePath = Join-Path $PSScriptRoot "..\modules\Queue.psm1"
Remove-Module Queue -ErrorAction SilentlyContinue
Import-Module $modulePath -Force

# Test 1: Initial state is idle
Write-Host "[TEST] Initial state..." -ForegroundColor Cyan
$status = Get-QueueStatus
if ($status.State -ne "idle") { throw "expected idle, got $($status.State)" }
if ($status.PendingCount -ne 0) { throw "expected 0 pending" }
if ($status.TotalCompleted -ne 0) { throw "expected 0 completed" }
Write-Host "  PASS: idle, 0 pending, 0 completed" -ForegroundColor Green

# Test 2: Add a job
Write-Host "[TEST] Add-BuildJob..." -ForegroundColor Cyan
$j1 = Add-BuildJob -TriggerId "comment-123" -TriggerUser "tester" -TriggerBody "test results attached" -Tag "build-001"
if (-not $j1) { throw "job not created" }
if ($j1.TriggerId -ne "comment-123") { throw "trigger id mismatch" }
$status = Get-QueueStatus
if ($status.PendingCount -ne 1) { throw "expected 1 pending" }
Write-Host "  PASS: job added, pending=1" -ForegroundColor Green

# Test 3: Duplicate trigger ID is rejected
Write-Host "[TEST] Duplicate dedup..." -ForegroundColor Cyan
$j2 = Add-BuildJob -TriggerId "comment-123" -TriggerUser "tester" -TriggerBody "dup"
if ($j2 -ne $null) { throw "duplicate should be rejected" }
$status = Get-QueueStatus
if ($status.PendingCount -ne 1) { throw "pending should still be 1" }
Write-Host "  PASS: duplicate rejected" -ForegroundColor Green

# Test 4: Get-NextBuildJob
Write-Host "[TEST] Get-NextBuildJob..." -ForegroundColor Cyan
$next = Get-NextBuildJob
if (-not $next) { throw "expected a job" }
if ($next.Tag -ne "build-001") { throw "wrong job" }
$status = Get-QueueStatus
if ($status.State -ne "building") { throw "expected building state" }
$status.PendingCount -eq 0 | Out-Null
Write-Host "  PASS: job dequeued, state=building" -ForegroundColor Green

# Test 5: Cannot get next while building
Write-Host "[TEST] No concurrent build..." -ForegroundColor Cyan
$nullShouldBe = Get-NextBuildJob
if ($nullShouldBe -ne $null) { throw "should not return job while building" }
Write-Host "  PASS: concurrent build prevented" -ForegroundColor Green

# Test 6: Complete-BuildJob
Write-Host "[TEST] Complete-BuildJob..." -ForegroundColor Cyan
Complete-BuildJob -Job $next -Success $true -LogPath "C:\logs\build-001.log"
$status = Get-QueueStatus
if ($status.State -ne "idle") { throw "expected idle after completion" }
if ($status.TotalCompleted -ne 1) { throw "expected 1 completed" }
if ($status.LastBuild.Success -ne $true) { throw "expected success" }
if ($status.LastBuild.Duration -le 0) { throw "expected duration > 0" }
Write-Host "  PASS: job completed, state=idle, history updated" -ForegroundColor Green

# Test 7: BuildHistory
Write-Host "[TEST] Get-BuildHistory..." -ForegroundColor Cyan
$history = Get-BuildHistory
if ($history.Count -ne 1) { throw "expected 1 history entry" }
$history2 = Get-BuildHistory -Last 5
if ($history2.Count -ne 1) { throw "expected 1 entry with -Last 5" }
Write-Host "  PASS: history correct" -ForegroundColor Green

# Test 8: Full cycle with multiple jobs
Write-Host "[TEST] Multi-job cycle..." -ForegroundColor Cyan
$null = Add-BuildJob -TriggerId "c1" -Tag "b1"
$null = Add-BuildJob -TriggerId "c2" -Tag "b2"
$null = Add-BuildJob -TriggerId "c3" -Tag "b3"
$status = Get-QueueStatus
if ($status.PendingCount -ne 3) { throw "expected 3 pending" }

$j = Get-NextBuildJob; Complete-BuildJob -Job $j -Success $true
$j = Get-NextBuildJob; Complete-BuildJob -Job $j -Success $false
$j = Get-NextBuildJob; Complete-BuildJob -Job $j -Success $true

$status = Get-QueueStatus
if ($status.TotalCompleted -ne 4) { throw "expected 4 total completed" }
if ($status.PendingCount -ne 0) { throw "expected 0 pending" }

# Verify dedup against completed IDs BEFORE reset
$dup = Add-BuildJob -TriggerId "c1"
if ($dup -ne $null) { throw "historical duplicate should be rejected" }
Write-Host "  PASS: 3 jobs processed, historical dedup verified" -ForegroundColor Green

# Test 9: Reset
Write-Host "[TEST] Reset-BuildQueue..." -ForegroundColor Cyan
Reset-BuildQueue
$status = Get-QueueStatus
if ($status.State -ne "idle") { throw "expected idle after reset" }
if ($status.TotalCompleted -ne 0) { throw "expected 0 after reset" }
if ($status.PendingCount -ne 0) { throw "expected 0 after reset" }
Write-Host "  PASS: queue reset" -ForegroundColor Green

# Test 10: After reset, c1 can be added again
Write-Host "[TEST] Post-reset re-add..." -ForegroundColor Cyan
$jAfterReset = Add-BuildJob -TriggerId "c1" -Tag "after-reset"
if (-not $jAfterReset) { throw "should be able to re-add after reset" }
$status = Get-QueueStatus
if ($status.PendingCount -ne 1) { throw "expected 1 pending after reset" }
Write-Host "  PASS: c1 re-added after reset" -ForegroundColor Green

Write-Host "`n[SUCCESS] All queue tests passed!" -ForegroundColor Green
