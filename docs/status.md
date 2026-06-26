# Status Engine (M8)

Build status, summary reports, and persistent build history management.

## Functions

| Function | Description |
|----------|-------------|
| New-BuildStatus | Create status object with BuildId, Git info, duration, artifacts, checksums |
| Add-SystemInfoToStatus | Enrich status with machine/CPU/memory/disk/WSL info |
| Save-BuildStatus | Write `status.json` to output directory |
| Save-BuildSummary | Write human-readable `summary.log` |
| Update-BuildHistory | Append to `history.json`, trim to max entries |
| Get-BuildHistoryFromFile | Read last N entries from `history.json` |

## status.json Fields

- BuildId, GitCommit, GitBranch
- Duration (seconds + human-readable)
- Success, ExitCode
- ArtifactSizes, Checksums
- BuildTimestamp, TriggerId, TriggerUser, LogPath
- MachineName, OS, CPU, MemoryGB, DiskFreeGB
- PowerShellVer, WslVersion, KernelVersion

## Build Report Files

| File | Source Module | Content |
|------|--------------|---------|
| `build.log` | Logger | INFO+ log entries |
| `trace.log` | Logger | TRACE level entries |
| `error.log` | Logger | ERROR level entries |
| `summary.log` | Status | Human-readable build summary |
| `status.json` | Status | Structured build status |
| `history.json` | Status | Build history across sessions |
| `manifest.json` | Artifacts | Artifact checksums and sizes |

## Usage

```powershell
Import-Module modules\Status.psm1

$sysInfo = Get-SystemInformation
$status = New-BuildStatus -Tag "build-001" -Success $true -DurationSeconds 360 -ExitCode 0
$status = Add-SystemInfoToStatus -Status $status -SystemInfo $sysInfo
Save-BuildStatus -Status $status -OutputDir "H:\dev\palimage"
Save-BuildSummary -Status $status -OutputDir "H:\dev\palimage"
Update-BuildHistory -Status $status -OutputDir "H:\dev\palimage"
```
