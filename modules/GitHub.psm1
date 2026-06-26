# GitHub.psm1 - PPSA GitHub API Interaction Layer
# Milestone 4: Fetch comments, post status, check triggers.
# Requires `gh` CLI to be installed and authenticated.

$script:GithubUser = $null

function Get-GitHubUser {
    if (-not $script:GithubUser) {
        $r = & gh api user --jq '.login' 2>$null
        if ($LASTEXITCODE -ne 0 -or -not $r) { throw "gh CLI not authenticated. Run 'gh auth login' first." }
        $script:GithubUser = $r.Trim()
    }
    return $script:GithubUser
}

function Get-GitHubComments {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string]$Repository,
        [Parameter(Mandatory=$true)]
        [int]$IssueNumber,
        [int]$Count = 10
    )
    $url = "repos/$Repository/issues/$IssueNumber/comments"
    $raw = & gh api $url --jq '.[] | {id: .id, user: .user.login, body: .body, createdAt: .createdAt}' 2>$null
    if ($LASTEXITCODE -ne 0) { return @() }

    $result = @()
    $raw -split "`n" | ForEach-Object {
        if ($_ -match '^\{') {
            try { $obj = $_ | ConvertFrom-Json -ErrorAction Stop; $result += $obj } catch {}
        }
    }
    return $result | Select-Object -Last $Count
}

function Test-BuildTrigger {
    [CmdletBinding()]
    param([string]$CommentBody)

    if (-not $CommentBody) { return $false }
    $keywords = @(
        "test results", "test result", "Test Results",
        "test report", "Test Report",
        "still broken", "still fails", "still panics",
        "panic", "error"
    )
    foreach ($k in $keywords) {
        if ($CommentBody -match [regex]::Escape($k)) { return $true }
    }
    return $false
}

function Test-GitHubCommentIsOwn {
    [CmdletBinding()]
    param([string]$CommentUser)
    try {
        $me = Get-GitHubUser
        return ($CommentUser -eq $me)
    } catch { return $false }
}

function Add-GitHubComment {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string]$Repository,
        [Parameter(Mandatory=$true)]
        [int]$IssueNumber,
        [Parameter(Mandatory=$true)]
        [string]$Body
    )
    $url = "repos/$Repository/issues/$IssueNumber/comments"
    $tmpFile = Join-Path $env:TEMP "ppsa-gh-comment-$(Get-Random).json"
    try {
        $bodyEscaped = $Body -replace '"', '\"'
        $json = "{`"body`": `"$bodyEscaped`"}"
        Set-Content -Path $tmpFile -Value $json -Encoding UTF8
        $result = & gh api $url --input $tmpFile --jq '.id' 2>&1
        if ($LASTEXITCODE -ne 0) { throw "Failed to post comment: $result" }
        return $result
    } finally {
        Remove-Item $tmpFile -Force -ErrorAction SilentlyContinue
    }
}

function Get-GitHubIssueLabels {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string]$Repository,
        [Parameter(Mandatory=$true)]
        [int]$IssueNumber
    )
    $url = "repos/$Repository/issues/$IssueNumber/labels"
    $raw = & gh api $url --jq '.[].name' 2>$null
    if ($LASTEXITCODE -ne 0) { return @() }
    return @($raw -split "`n" | Where-Object { $_ })
}

Export-ModuleMember -Function Get-GitHubUser, Get-GitHubComments, Test-BuildTrigger, Test-GitHubCommentIsOwn, Add-GitHubComment, Get-GitHubIssueLabels
