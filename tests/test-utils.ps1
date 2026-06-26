# Test: Utils Module (M3)
$ErrorActionPreference = "Stop"

$modulePath = Join-Path $PSScriptRoot "..\modules\Utils.psm1"
Remove-Module Utils -ErrorAction SilentlyContinue
Import-Module $modulePath -Force

# Test 1: Invoke-CommandCapture with a simple command
Write-Host "[TEST] Invoke-CommandCapture (echo)..." -ForegroundColor Cyan
$result = Invoke-CommandCapture -FileName "cmd.exe" -Arguments @("/c", "echo hello world")
if ($result.ExitCode -ne 0) { throw "exit code $($result.ExitCode)" }
if ($result.Stdout -notmatch "hello world") { throw "stdout mismatch: $($result.Stdout)" }
if ($result.Duration.TotalMilliseconds -le 0) { throw "duration not set" }
Write-Host "  PASS: echo (exit=$($result.ExitCode), duration=$($result.Duration.TotalMilliseconds.ToString('F0'))ms)" -ForegroundColor Green

# Test 2: Invoke-CommandCapture with failure
Write-Host "[TEST] Invoke-CommandCapture (failure)..." -ForegroundColor Cyan
$result = Invoke-CommandCapture -FileName "cmd.exe" -Arguments @("/c", "exit 42")
if ($result.ExitCode -ne 42) { throw "expected exit 42, got $($result.ExitCode)" }
Write-Host "  PASS: exit 42" -ForegroundColor Green

# Test 3: Get-FileHashVerified
Write-Host "[TEST] Get-FileHashVerified..." -ForegroundColor Cyan
$selfPath = Join-Path $PSScriptRoot "test-utils.ps1"
$hashResult = Get-FileHashVerified -Path $selfPath
if (-not $hashResult.Valid) { throw "hash verification failed: $($hashResult.Error)" }
if (-not $hashResult.Hash) { throw "hash not returned" }
Write-Host "  PASS: hash=$($hashResult.Hash.Substring(0,16))..." -ForegroundColor Green

# Test 4: Get-FileHashVerified with expected hash
Write-Host "[TEST] Get-FileHashVerified (expected)..." -ForegroundColor Cyan
$hashResult2 = Get-FileHashVerified -Path $selfPath -ExpectedHash $hashResult.Hash
if (-not $hashResult2.Valid) { throw "expected hash should match" }
$hashResult3 = Get-FileHashVerified -Path $selfPath -ExpectedHash "0000000000000000000000000000000000000000000000000000"
if ($hashResult3.Valid) { throw "bad hash should not match" }
Write-Host "  PASS: expected hash match=$($hashResult2.Valid), mismatch=$(-not $hashResult3.Valid)" -ForegroundColor Green

# Test 5: Get-FileHashVerified missing file
Write-Host "[TEST] Get-FileHashVerified (missing)..." -ForegroundColor Cyan
$hashResult4 = Get-FileHashVerified -Path "C:\nonexistent_file_xyz123"
if ($hashResult4.Valid) { throw "missing file should not be valid" }
Write-Host "  PASS: missing file handled" -ForegroundColor Green

# Test 6: Copy-Verified
Write-Host "[TEST] Copy-Verified..." -ForegroundColor Cyan
$tmpSrc = Join-Path $env:TEMP "ppsa-utils-src-$(Get-Random).tmp"
$tmpDst = Join-Path $env:TEMP "ppsa-utils-dst-$(Get-Random).tmp"
try {
    Set-Content -Path $tmpSrc -Value "test data for copy verification"
    Copy-Verified -Source $tmpSrc -Destination $tmpDst
    if (-not (Test-Path $tmpDst)) { throw "destination not created" }
    $srcHash = (Get-FileHash $tmpSrc).Hash
    $dstHash = (Get-FileHash $tmpDst).Hash
    if ($srcHash -ne $dstHash) { throw "hash mismatch after copy" }
    Write-Host "  PASS: copy and verify OK" -ForegroundColor Green
} finally {
    Remove-Item $tmpSrc -Force -ErrorAction SilentlyContinue
    Remove-Item $tmpDst -Force -ErrorAction SilentlyContinue
}

# Test 7: Get-SystemInformation
Write-Host "[TEST] Get-SystemInformation..." -ForegroundColor Cyan
$sysInfo = Get-SystemInformation
if (-not $sysInfo.MachineName) { throw "MachineName missing" }
if (-not $sysInfo.OS) { throw "OS missing" }
if (-not $sysInfo.CPU) { throw "CPU missing" }
if (-not $sysInfo.PowerShellVer) { throw "PowerShellVer missing" }
Write-Host "  PASS: Machine=$($sysInfo.MachineName), OS=$($sysInfo.OS), CPU=$($sysInfo.CPU)" -ForegroundColor Green

# Test 8: New-BuildTag
Write-Host "[TEST] New-BuildTag..." -ForegroundColor Cyan
$tag = New-BuildTag
if ($tag -notmatch '^local-\d{8}-\d{6}$') { throw "unexpected tag format: $tag" }
$tag2 = New-BuildTag -Prefix "nightly"
if ($tag2 -notmatch '^nightly-') { throw "prefix not applied: $tag2" }
Write-Host "  PASS: tag='$tag', tag2='$tag2'" -ForegroundColor Green

# Test 9: Test-CommandAvailable
Write-Host "[TEST] Test-CommandAvailable..." -ForegroundColor Cyan
if (-not (Test-CommandAvailable -Command "cmd.exe")) { throw "cmd.exe should be available" }
if (Test-CommandAvailable -Command "nonexistent_command_xyz") { throw "nonexistent should not be available" }
Write-Host "  PASS: cmd.exe available, nonexistent not" -ForegroundColor Green

Write-Host "`n[SUCCESS] All utils tests passed!" -ForegroundColor Green
