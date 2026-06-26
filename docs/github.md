# GitHub Watcher (M4)

GitHub API layer for fetching issue comments, posting build status, and detecting build triggers.

## Requirements

- `gh` CLI installed and authenticated (`gh auth login`)

## Functions

| Function | Description |
|----------|-------------|
| Get-GitHubUser | Returns authenticated GitHub username |
| Get-GitHubComments | Fetch latest N comments from an issue |
| Test-BuildTrigger | Check if comment contains trigger keywords (test results/report, still broken/panics/error) |
| Test-GitHubCommentIsOwn | Check if a comment was made by the authenticated user |
| Add-GitHubComment | Post a comment to an issue |
| Get-GitHubIssueLabels | Fetch labels on an issue |

## Usage

```powershell
Import-Module modules\GitHub.psm1

$comments = Get-GitHubComments -Repository "kaiser62/ppsa" -IssueNumber 1 -Count 5
foreach ($c in $comments) {
    if (-not (Test-GitHubCommentIsOwn -CommentUser $c.user) -and (Test-BuildTrigger -CommentBody $c.body)) {
        Add-GitHubComment -Repository "kaiser62/ppsa" -IssueNumber 1 -Body "Build started..."
    }
}
```
