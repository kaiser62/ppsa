# Test: Configuration Module (M1)
$ErrorActionPreference = "Stop"

$modulePath = Join-Path $PSScriptRoot "..\modules\Configuration.psm1"
Remove-Module Configuration -ErrorAction SilentlyContinue
Import-Module $modulePath -Force

Write-Host "[TEST] Loading configuration..." -ForegroundColor Cyan
$config = Get-Configuration
Write-Host "  PASS: Config loaded" -ForegroundColor Green

$sections = @("output", "wsl", "github", "virtualbox", "logging", "build")
foreach ($s in $sections) {
    if (-not $config.$s) {
        Write-Host "  FAIL: Missing section '$s'" -ForegroundColor Red
        exit 1
    }
    Write-Host "  PASS: Section '$s' present" -ForegroundColor Green
}

$checks = @(
    @{path = "output.directory"; expect = "H:\dev\palimage"}
    @{path = "output.artifact_size_mb"; expect = 8192}
    @{path = "output.compression_level"; expect = 10}
    @{path = "wsl.user"; expect = "artho"}
    @{path = "github.repository"; expect = "kaiser62/ppsa"}
    @{path = "github.issue_number"; expect = 1}
    @{path = "virtualbox.vm_name"; expect = "ppsa-test"}
    @{path = "build.retry_count"; expect = 3}
)

foreach ($c in $checks) {
    $parts = $c.path -split "\."
    $val = $config
    foreach ($p in $parts) { $val = $val.$p }
    if ($val -ne $c.expect) {
        Write-Host "  FAIL: '$($c.path)' = '$val', expected '$($c.expect)'" -ForegroundColor Red
        exit 1
    }
    Write-Host "  PASS: '$($c.path)' = '$val'" -ForegroundColor Green
}

Write-Host "`n[SUCCESS] All configuration tests passed!" -ForegroundColor Green
