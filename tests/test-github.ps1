# Test: GitHub Module (M4)
$ErrorActionPreference = "Stop"
$repo = Split-Path $PSScriptRoot -Leaf

$modulePath = Join-Path $PSScriptRoot "..\modules\GitHub.psm1"
Remove-Module GitHub -ErrorAction SilentlyContinue
Import-Module $modulePath -Force

# --- Logic tests (no network needed) ---

Write-Host "[TEST] Test-BuildTrigger..." -ForegroundColor Cyan
$triggerCases = @(
    @{text = "test results are in";        expect = $true},
    @{text = "test result: all pass";      expect = $true},
    @{text = "Test Results attached";      expect = $true},
    @{text = "here is the test report";    expect = $true},
    @{text = "Test Report from CI";        expect = $true},
    @{text = "still broken in v0.3.3";     expect = $true},
    @{text = "still fails to boot";        expect = $true},
    @{text = "still panics on startup";    expect = $true},
    @{text = "Kernel panic detected";      expect = $true},
    @{text = "build error in step 2";      expect = $true},
    @{text = "looks good to me";           expect = $false},
    @{text = "LGTM";                       expect = $false},
    @{text = "test (not a trigger)";       expect = $false},
    @{text = "";                            expect = $false}
)
foreach ($tc in $triggerCases) {
    $got = Test-BuildTrigger -CommentBody $tc.text
    if ($got -ne $tc.expect) { throw "FAIL: '$($tc.text)' => $got, expected $($tc.expect)" }
}
Write-Host "  PASS: $($triggerCases.Count) trigger test cases" -ForegroundColor Green

Write-Host "[TEST] Test-GitHubCommentIsOwn (no auth = false)..." -ForegroundColor Cyan
$own = Test-GitHubCommentIsOwn -CommentUser "somebody-else"
if ($own) { throw "should not detect 'somebody-else' as self without auth" }
Write-Host "  PASS: other user returns false" -ForegroundColor Green

# --- Network-dependent tests (skip if gh not available) ---
$ghOk = $false
try {
    $null = Get-Command gh -ErrorAction Stop
    $null = & gh auth status 2>$null
    $ghOk = ($LASTEXITCODE -eq 0)
} catch { $ghOk = $false }

if (-not $ghOk) {
    Write-Host "  SKIP: gh CLI not authenticated, skipping network tests" -ForegroundColor Yellow
    Write-Host "`n[SUCCESS] All offline tests passed!" -ForegroundColor Green
    return
}

Write-Host "[TEST] Get-GitHubUser..." -ForegroundColor Cyan
$user = Get-GitHubUser
if (-not $user) { throw "no user returned" }
Write-Host "  PASS: authenticated as '$user'" -ForegroundColor Green

Write-Host "[TEST] Get-GitHubComments..." -ForegroundColor Cyan
$comments = Get-GitHubComments -Repository "kaiser62/ppsa" -IssueNumber 1 -Count 5
if ($comments.Count -gt 0) {
    Write-Host "  PASS: $($comments.Count) comments fetched" -ForegroundColor Green
} else {
    # Empty is OK — there may be no comments
    Write-Host "  PASS: 0 comments (empty issue)" -ForegroundColor Green
}

Write-Host "[TEST] Get-GitHubIssueLabels..." -ForegroundColor Cyan
$labels = Get-GitHubIssueLabels -Repository "kaiser62/ppsa" -IssueNumber 1
Write-Host "  PASS: $($labels.Count) labels found" -ForegroundColor Green

Write-Host "`n[SUCCESS] All GitHub tests passed!" -ForegroundColor Green
