# Test: Status Module (M8)
$ErrorActionPreference = "Stop"

$modules = @("Logger", "Utils")
foreach ($m in $modules) {
    Remove-Module $m -ErrorAction SilentlyContinue
    Import-Module (Join-Path $PSScriptRoot "..\modules\$m.psm1") -Force
}
$testLogDir = Join-Path $env:TEMP "ppsa-test-status-$(Get-Random)"
Initialize-Logger -LogDirectory $testLogDir

$modulePath = Join-Path $PSScriptRoot "..\modules\Status.psm1"
Remove-Module Status -ErrorAction SilentlyContinue
Import-Module $modulePath -Force

$testDir = Join-Path $env:TEMP "ppsa-status-test-$(Get-Random)"
New-Item -ItemType Directory -Path $testDir -Force | Out-Null

try {
    # Test 1: New-BuildStatus basic
    Write-Host "[TEST] New-BuildStatus..." -ForegroundColor Cyan
    $status = New-BuildStatus -Tag "build-001" -Success $true -DurationSeconds 125 -ExitCode 0 -TriggerId "c1" -TriggerUser "tester"
    if ($status.BuildId -ne "build-001") { throw "BuildId mismatch" }
    if (-not $status.Success) { throw "expected success" }
    if ($status.Duration -ne 125) { throw "duration mismatch" }
    if ($status.DurationHuman -ne "2.1min") { throw "human duration mismatch: $($status.DurationHuman)" }
    if ($status.TriggerId -ne "c1") { throw "trigger id mismatch" }
    Write-Host "  PASS: BuildId=$($status.BuildId) Success=$($status.Success) Duration=$($status.DurationHuman)" -ForegroundColor Green

    # Test 2: New-BuildStatus with artifacts
    Write-Host "[TEST] New-BuildStatus (with artifacts)..." -ForegroundColor Cyan
    $artifacts = @(
        [PSCustomObject]@{ FileName = "test.vdi"; SizeMB = 2048; SHA256 = "abc123" },
        [PSCustomObject]@{ FileName = "test.img.zst"; SizeMB = 600; SHA256 = "def456" }
    )
    $status2 = New-BuildStatus -Tag "build-002" -Success $true -DurationSeconds 360 -Artifacts $artifacts
    if ($status2.ArtifactSizes.'test.vdi' -ne 2048) { throw "artifact size mismatch" }
    if ($status2.Checksums.'test.img.zst' -ne "def456") { throw "checksum mismatch" }
    Write-Host "  PASS: artifacts and checksums OK" -ForegroundColor Green

    # Test 3: Add-SystemInfoToStatus
    Write-Host "[TEST] Add-SystemInfoToStatus..." -ForegroundColor Cyan
    $sysInfo = Get-SystemInformation
    $status3 = Add-SystemInfoToStatus -Status $status -SystemInfo $sysInfo
    if (-not $status3.MachineName) { throw "MachineName missing" }
    if (-not $status3.OS) { throw "OS missing" }
    Write-Host "  PASS: Machine=$($status3.MachineName) OS=$($status3.OS)" -ForegroundColor Green

    # Test 4: Save-BuildStatus
    Write-Host "[TEST] Save-BuildStatus..." -ForegroundColor Cyan
    $statusPath = Save-BuildStatus -Status $status3 -OutputDir $testDir
    if (-not (Test-Path $statusPath)) { throw "status.json not created" }
    $loaded = Get-Content $statusPath -Raw | ConvertFrom-Json
    if ($loaded.BuildId -ne "build-001") { throw "reloaded BuildId mismatch" }
    Write-Host "  PASS: status.json written and read back" -ForegroundColor Green

    # Test 5: Save-BuildSummary
    Write-Host "[TEST] Save-BuildSummary..." -ForegroundColor Cyan
    $summaryPath = Save-BuildSummary -Status $status3 -OutputDir $testDir
    if (-not (Test-Path $summaryPath)) { throw "summary.log not created" }
    $summaryRaw = Get-Content $summaryPath -Raw
    if ($summaryRaw -notmatch "build-001") { throw "summary missing BuildId" }
    if ($summaryRaw -notmatch "SUCCESS") { throw "summary missing success status" }
    Write-Host "  PASS: summary.log written" -ForegroundColor Green

    # Test 6: Update-BuildHistory
    Write-Host "[TEST] Update-BuildHistory..." -ForegroundColor Cyan
    $histPath = Update-BuildHistory -Status $status3 -OutputDir $testDir
    if (-not (Test-Path $histPath)) { throw "history.json not created" }
    $hist = Get-Content $histPath -Raw | ConvertFrom-Json
    if ($hist -is [array]) {
        if ($hist.Count -ne 1) { throw "expected 1 history entry" }
    } else {
        # Single entry isn't an array
        if ($hist.BuildId -ne "build-001") { throw "single history entry mismatch" }
    }
    Write-Host "  PASS: history.json written" -ForegroundColor Green

    # Test 7: Update-BuildHistory append
    Write-Host "[TEST] Update-BuildHistory (append)..." -ForegroundColor Cyan
    $status4 = New-BuildStatus -Tag "build-002" -Success $false -DurationSeconds 30 -ExitCode 1
    $null = Update-BuildHistory -Status $status4 -OutputDir $testDir
    $hist2 = Get-BuildHistoryFromFile -HistoryPath $histPath -Last 10
    if ($hist2.Count -ne 2) { throw "expected 2 history entries, got $($hist2.Count)" }
    Write-Host "  PASS: history has $($hist2.Count) entries" -ForegroundColor Green

    # Test 8: Get-BuildHistoryFromFile
    Write-Host "[TEST] Get-BuildHistoryFromFile..." -ForegroundColor Cyan
    $recent = Get-BuildHistoryFromFile -HistoryPath $histPath -Last 1
    Write-Host "  DEBUG: type=$($recent.GetType().FullName) Count=$($recent.Count)" -ForegroundColor DarkGray
    if ($recent.Count -ne 1) { throw "expected 1 recent entry, got $($recent.Count)" }
    if ($recent[0].BuildId -ne "build-002") { throw "expected most recent build" }
    Write-Host "  PASS: recent history correct" -ForegroundColor Green

    Write-Host "`n[SUCCESS] All status tests passed!" -ForegroundColor Green
} finally {
    Remove-Item $testDir -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item $testLogDir -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Module Status, Utils, Logger -ErrorAction SilentlyContinue
}
