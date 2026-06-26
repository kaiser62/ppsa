# Test: Artifacts Module (M7)
$ErrorActionPreference = "Stop"

# Pre-load deps
$modules = @("Logger", "Utils")
foreach ($m in $modules) {
    Remove-Module $m -ErrorAction SilentlyContinue
    Import-Module (Join-Path $PSScriptRoot "..\modules\$m.psm1") -Force
}
$testLogDir = Join-Path $env:TEMP "ppsa-test-artifacts-$(Get-Random)"
Initialize-Logger -LogDirectory $testLogDir

$modulePath = Join-Path $PSScriptRoot "..\modules\Artifacts.psm1"
Remove-Module Artifacts -ErrorAction SilentlyContinue
Import-Module $modulePath -Force

$testDir = Join-Path $env:TEMP "ppsa-artifacts-test-$(Get-Random)"
New-Item -ItemType Directory -Path $testDir -Force | Out-Null

try {
    # Create test files
    $testFile1 = Join-Path $testDir "test.vdi"
    $testFile2 = Join-Path $testDir "test.img.zst"
    Set-Content -Path $testFile1 -Value "fake vdi content for testing" -Encoding ASCII
    Set-Content -Path $testFile2 -Value "fake zst content" -Encoding ASCII

    # Test 1: Test-Artifact existing file
    Write-Host "[TEST] Test-Artifact (exists)..." -ForegroundColor Cyan
    $r = Test-Artifact -Path $testFile1
    if (-not $r.Valid) { throw "expected valid: $($r.Issues -join '; ')" }
    if ($r.SizeMB -lt 0) { throw "expected non-negative size" }
    if (-not $r.Hash) { throw "expected hash" }
    Write-Host "  PASS: size=$($r.SizeMB)MB hash=$($r.Hash.Substring(0,16))..." -ForegroundColor Green

    # Test 2: Test-Artifact missing file
    Write-Host "[TEST] Test-Artifact (missing)..." -ForegroundColor Cyan
    $r2 = Test-Artifact -Path "C:\nonexistent_file_abc"
    if ($r2.Valid) { throw "missing should be invalid" }
    Write-Host "  PASS: missing file detected" -ForegroundColor Green

    # Test 3: Test-Artifact with size check
    Write-Host "[TEST] Test-Artifact (min size)..." -ForegroundColor Cyan
    $r3 = Test-Artifact -Path $testFile1 -MinSizeMB 1000
    if ($r3.Valid) { throw "small file should fail min size" }
    if ($r3.Issues -notmatch "minimum") { throw "expected size issue" }
    Write-Host "  PASS: min size check works" -ForegroundColor Green

    # Test 4: Test-Artifact hash verification
    Write-Host "[TEST] Test-Artifact (hash match)..." -ForegroundColor Cyan
    $goodHash = (Get-FileHash $testFile1 -Algorithm SHA256).Hash
    $r4 = Test-Artifact -Path $testFile1 -ExpectedHash $goodHash
    if (-not $r4.Valid) { throw "hash should match: $($r4.Issues -join '; ')" }
    Write-Host "  PASS: hash match OK" -ForegroundColor Green

    Write-Host "[TEST] Test-Artifact (hash mismatch)..." -ForegroundColor Cyan
    $r5 = Test-Artifact -Path $testFile1 -ExpectedHash "00000000000000000000000000000000000000000000000000"
    if ($r5.Valid) { throw "hash should not match" }
    Write-Host "  PASS: hash mismatch detected" -ForegroundColor Green

    # Test 5: Test-VdiIntegrity (minimal VDI header)
    Write-Host "[TEST] Test-VdiIntegrity (minimal VDI)..." -ForegroundColor Cyan
    $vdiTest = Join-Path $testDir "minimal.vdi"
    # VDI magic: "<<< Oracle VM VirtualBox Disk Image" starts with "<<< "
    $vdiHeader = [byte[]]@(0x3c, 0x3c, 0x3c, 0x20) + [System.Text.Encoding]::ASCII.GetBytes("Oracle VM VirtualBox Disk Image minimal header")
    [System.IO.File]::WriteAllBytes($vdiTest, $vdiHeader)
    $vdiResult = Test-VdiIntegrity -VdiPath $vdiTest
    if (-not $vdiResult.Valid) { throw "VDI header check failed: $($vdiResult.Error)" }
    Write-Host "  PASS: VDI header detected" -ForegroundColor Green

    Write-Host "[TEST] Test-VdiIntegrity (invalid)..." -ForegroundColor Cyan
    $badVdi = Join-Path $testDir "bad.vdi"
    [System.IO.File]::WriteAllText($badVdi, "not a vdi file at all", [System.Text.Encoding]::ASCII)
    $badResult = Test-VdiIntegrity -VdiPath $badVdi
    if ($badResult.Valid) { throw "bad VDI should be invalid" }
    Write-Host "  PASS: bad VDI rejected" -ForegroundColor Green

    # Test 6: New-ArtifactManifest
    Write-Host "[TEST] New-ArtifactManifest..." -ForegroundColor Cyan
    $manifestFile = Join-Path $testDir "manifest.json"
    $manifest = New-ArtifactManifest -Tag "test-build" -FilePaths @($testFile1, $testFile2) -OutputPath $manifestFile
    if ($manifest.TotalArtifacts -ne 2) { throw "expected 2 artifacts" }
    if ($manifest.ValidArtifacts -ne 2) { throw "expected 2 valid" }
    if ($manifest.Tag -ne "test-build") { throw "tag mismatch" }
    if (-not (Test-Path $manifestFile)) { throw "manifest file not written" }
    Write-Host "  PASS: manifest with $($manifest.TotalArtifacts) artifacts" -ForegroundColor Green

    # Test 7: Update-LatestSymlink
    Write-Host "[TEST] Update-LatestSymlink..." -ForegroundColor Cyan
    $latest = Update-LatestSymlink -SourceVdi $testFile1 -OutputDir $testDir
    if (-not (Test-Path $latest)) { throw "latest.vdi not created" }
    $srcHash = (Get-FileHash $testFile1).Hash
    $dstHash = (Get-FileHash $latest).Hash
    if ($srcHash -ne $dstHash) { throw "hash mismatch on latest.vdi" }
    Write-Host "  PASS: latest.vdi updated and verified" -ForegroundColor Green

    # Test 8: Get-ArtifactInfo
    Write-Host "[TEST] Get-ArtifactInfo..." -ForegroundColor Cyan
    $info = Get-ArtifactInfo -Path $testFile1
    if (-not $info.Exists) { throw "should exist" }
    if ($info.SizeMB -lt 0) { throw "expected non-negative size" }
    if (-not $info.Hash) { throw "expected hash" }
    Write-Host "  PASS: size=$($info.SizeMB)MB hash=$($info.Hash.Substring(0,16))..." -ForegroundColor Green

    Write-Host "[TEST] Get-ArtifactInfo (missing)..." -ForegroundColor Cyan
    $info2 = Get-ArtifactInfo -Path "C:\missing_file_xyz"
    if ($info2.Exists) { throw "should not exist" }
    Write-Host "  PASS: missing file handled" -ForegroundColor Green

    Write-Host "`n[SUCCESS] All artifact tests passed!" -ForegroundColor Green
} finally {
    Remove-Item $testDir -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item $testLogDir -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Module Artifacts, Utils, Logger -ErrorAction SilentlyContinue
}
