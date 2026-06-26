# Utilities (M3)

Common helper functions used by all modules.

## Functions

| Function | Description |
|----------|-------------|
| Invoke-CommandCapture | Run a process, capture stdout/stderr/exit code/duration with timeout |
| Get-FileHashVerified | Compute SHA256, optionally verify against expected hash |
| Copy-Verified | Copy a file and verify integrity by SHA256 after copy |
| Get-SystemInformation | Collect machine info: OS, CPU, memory, disk, PowerShell/WSL/kernel versions |
| New-BuildTag | Generate unique build tag: `{prefix}-YYYYMMDD-HHmmss` |
| Test-CommandAvailable | Check if a command exists on PATH |

## Usage

```powershell
Import-Module modules\Utils.psm1

$r = Invoke-CommandCapture -FileName "wsl" -Arguments @("--version") -TimeoutSeconds 10
if ($r.ExitCode -eq 0) { $r.Stdout }

Copy-Verified -Source "output.vdi" -Destination "H:\dev\palimage\latest.vdi"

$sys = Get-SystemInformation
$tag = New-BuildTag -Prefix "nightly"
```
