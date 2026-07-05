# Local Builder (PowerShell)

A PowerShell system for fast local iteration without waiting on GitHub
Actions CI. It calls the exact same `scripts/build-live-usb.sh` inside WSL,
converts the result to VDI, and drives a VirtualBox smoke test — same core
build, different trigger and feedback loop. Not the sanctioned way to produce
release artifacts (see [docs/architecture.md#build-pipeline](architecture.md#build-pipeline));
this is a dev-inner-loop tool.

Entry point: `scripts/Start-PpsaBuilder.ps1`. Config: `builder.json` at the
repo root. Design doc: `MASTER_PLAN.md`.

## Configuration (`builder.json`)

| Section | Key | Default | Description |
|---------|-----|---------|-------------|
| output | directory | `H:\dev\palimage` | Output directory for artifacts |
| output | artifact_size_mb | `8192` | Raw image size in MB |
| output | compression_level | `10` | zstd compression level |
| wsl | user | `artho` | WSL user for build commands |
| wsl | project_path | `/mnt/d/Dev/palworld-self-containing-server` | Project path inside WSL |
| github | repository | `kaiser62/ppsa` | GitHub repository |
| github | issue_number | `1` | Issue to watch for test reports |
| github | poll_interval_seconds | `10` | Polling interval for new comments |
| virtualbox | vm_name | `ppsa-test` | VirtualBox VM name for testing |
| virtualbox | memory_mb | `8192` | VM memory (8GB+ recommended for the Palworld Steam download) |
| virtualbox | cpus | `8` | VM CPU count (2 CPUs is known to cause RCU stalls under load — see [docs/troubleshooting.md](troubleshooting.md)) |
| logging | retention_days | `30` | Days to keep logs |
| logging | directory | `H:\dev\palimage\logs` | Log output directory |
| logging | levels | `[TRACE..SUCCESS]` | Enabled log levels |
| build | retry_count | `3` | Build retry attempts |
| build | wsl_home_build_dir | `/home/artho/build` | WSL build directory |

```powershell
Import-Module modules\Configuration.psm1
$config = Get-Configuration
Write-Host $config.output.directory
```

## Module reference

### Logger.psm1 — structured logging

Format: `[yyyy-MM-dd HH:mm:ss.fff] [LEVEL] [Module] Message | cmd: ... | exit: N | at: ... | action: ...`

Levels route to files: `TRACE` → `trace.log`; `DEBUG`/`INFO`/`WARN`/`SUCCESS`
→ `build.log`; `ERROR` → both `build.log` and `error.log`.

```powershell
Import-Module modules\Logger.psm1
Initialize-Logger -LogDirectory "H:\dev\palimage\logs" -Levels @("INFO","WARN","ERROR")
Write-LogInfo -Module "Builder" -Message "Building image..."
Write-LogError -Module "Builder" -Message "Failed" -Command "build" -ExitCode 1 -Location "build.ps1:42" -RecommendedAction "Check disk space"

$sw = Start-Timer
Measure-Phase -Module "Builder" -Name "build" -ScriptBlock { ./build.sh }
```

### Utils.psm1 — shared helpers

| Function | Description |
|----------|-------------|
| `Invoke-CommandCapture` | Run a process, capture stdout/stderr/exit code/duration with timeout |
| `Get-FileHashVerified` | Compute SHA256, optionally verify against an expected hash |
| `Copy-Verified` | Copy a file and verify integrity by SHA256 after copy |
| `Get-SystemInformation` | Collect machine info: OS, CPU, memory, disk, PowerShell/WSL/kernel versions |
| `New-BuildTag` | Generate a unique build tag: `{prefix}-YYYYMMDD-HHmmss` |
| `Test-CommandAvailable` | Check if a command exists on PATH |

### GitHub.psm1 — issue polling

Requires `gh` CLI authenticated (`gh auth login`). Polls a GitHub issue for
tester comments and detects build-trigger keywords.

| Function | Description |
|----------|-------------|
| `Get-GitHubComments` | Fetch latest N comments from an issue |
| `Test-BuildTrigger` | Check if a comment contains trigger keywords ("test results"/"still broken"/"panics"/"error") |
| `Test-GitHubCommentIsOwn` | Check if a comment was made by the authenticated user |
| `Add-GitHubComment` | Post a comment to an issue |
| `Get-GitHubIssueLabels` | Fetch labels on an issue |

### Queue.psm1 — build job queue

Single-flight concurrency guard with dedup and history.

| Function | Description |
|----------|-------------|
| `Add-BuildJob` | Enqueue a job; rejects duplicates (pending + completed) |
| `Get-NextBuildJob` | Dequeue next job; returns null if busy or empty |
| `Complete-BuildJob` | Mark a job complete, record in history |
| `Get-QueueStatus` | Current state (`idle`/`building`), current job, pending count |
| `Clear-BuildQueue` / `Reset-BuildQueue` | Clear pending jobs, or full reset including history |

### Builder.psm1 — the actual WSL build

Runs the build phases: `prepare-dir` → `build-image`
(`build-live-usb.sh --output --size`) → `compress` (`zstd`) → `convert-vdi`
(VBoxManage/qemu-img) → `sha256` → `verify` → `copy-output`.

```powershell
Import-Module modules\Builder.psm1
$config = Get-Configuration
$result = Invoke-Build -Config $config -Tag "local-20260627-010000"
if ($result.Success) {
    Write-Host "Build OK in $($result.TotalDuration.TotalMinutes.ToString('F1')) min"
}
```

### Artifacts.psm1 — verification & manifests

| Function | Description |
|----------|-------------|
| `Test-Artifact` | Verify a file exists, meets a minimum size, and matches an expected SHA256 |
| `Test-VdiIntegrity` | Check VDI validity (`qemu-img check` or header magic) |
| `New-ArtifactManifest` | Generate `manifest.json` with all artifact hashes and sizes |
| `Update-LatestSymlink` | Copy a VDI as `latest.vdi` with verified copy |
| `Get-ArtifactInfo` | File info: exists, size, hash, modified time |

### Status.psm1 — build status & history

Writes `status.json` (build ID, git commit/branch, duration, success,
artifact sizes/checksums, machine/CPU/memory/disk info, PowerShell/WSL/kernel
versions), a human-readable `summary.log`, and appends to `history.json`.

```powershell
Import-Module modules\Status.psm1
$sysInfo = Get-SystemInformation
$status = New-BuildStatus -Tag "build-001" -Success $true -DurationSeconds 360 -ExitCode 0
$status = Add-SystemInfoToStatus -Status $status -SystemInfo $sysInfo
Save-BuildStatus -Status $status -OutputDir "H:\dev\palimage"
Save-BuildSummary -Status $status -OutputDir "H:\dev\palimage"
Update-BuildHistory -Status $status -OutputDir "H:\dev\palimage"
```

Build report files, all in the output directory: `build.log` / `trace.log` /
`error.log` (Logger), `summary.log` / `status.json` / `history.json`
(Status), `manifest.json` (Artifacts).

### SmokeTest.psm1 — automated VirtualBox smoke test

Boots a built VDI in VirtualBox, waits for it to come up, runs health checks
and an optional Web UI probe, shuts down, and persists a JSON report.

Configured via `builder.json`'s `smoke_test` block:
```json
"smoke_test": {
  "boot_timeout_seconds": 600,
  "webui_timeout_seconds": 300,
  "webui_url": "http://127.0.0.1:8080",
  "webui_probe_path": "/",
  "auto_shutdown": true
}
```
`webui_url` may be `null` to skip the probe. `auto_shutdown` issues
`acpipowerbutton` and waits for a clean poweroff, force-powering off on
failure.

| Function | Description |
|----------|-------------|
| `Test-VmBootHealthy` | Detect kernel panic, OOM kill, VFS/init failure, or a failed systemd unit in the console log |
| `Wait-VmBootReady` | Poll the console for a login prompt, Debian banner, or systemd marker, bounded by a timeout |
| `Test-VmWebUiReachable` | HTTP `GET` against the configured URL (requires a NAT port-forward to the guest) |
| `Invoke-SmokeTest` | Top-level: create/start VM → wait → health-check → optional Web UI probe → shutdown |

```powershell
Import-Module modules\SmokeTest.psm1 -Force
$config = Get-Configuration
$result = Invoke-SmokeTest -Config $config -VdiPath "H:\dev\palimage\ppsa-vbox-1.1.5.vdi"
Save-SmokeTestResult -Result $result -OutputDir $config.output.directory
if (-not $result.Success) { throw "Smoke test failed" }
```

Notes: Web UI probing needs a host→guest port forward (e.g.
`VBoxManage modifyvm ppsa-test --natpf1 "webui,tcp,,8080,,8080"`) — without it
the probe fails even if the service is healthy inside the VM. A failed boot
does not delete the VDI; the console excerpt is preserved in
`smoke-test.json` for triage.
