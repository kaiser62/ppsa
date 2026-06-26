# Build Queue (M5)

Manages build job queue with dedup, concurrency guard, and build history.

## Functions

| Function | Description |
|----------|-------------|
| New-BuildJob | Create a job object (internal) |
| Add-BuildJob | Enqueue a job; rejects duplicates (pending + completed) |
| Get-NextBuildJob | Dequeue next job; returns null if busy or empty |
| Complete-BuildJob | Mark job complete, record in history |
| Get-QueueStatus | Current state, current job, pending count, last build |
| Get-BuildHistory | Return last N completed jobs |
| Clear-BuildQueue | Clear pending queue and dedup cache (fails if building) |
| Reset-BuildQueue | Full reset: clear queue, history, and dedup cache |

## States

- `idle` — ready for next job
- `building` — a build is in progress; Get-NextBuildJob returns null

## Usage

```powershell
Import-Module modules\Queue.psm1

$job = Add-BuildJob -TriggerId "comment-456" -TriggerUser "tester" -Repository "kaiser62/ppsa" -IssueNumber 1
$next = Get-NextBuildJob
# ... run build ...
Complete-BuildJob -Job $next -Success $true -LogPath "build.log"

Get-QueueStatus  # { State, CurrentJob, PendingCount, LastBuild }
```
