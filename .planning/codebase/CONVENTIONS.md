# Coding Conventions

**Analysis Date:** 2026-07-16

## Naming Patterns

**Files:**
- Bash scripts: lowercase with hyphens: `ppsa-firewall-apply.sh`, `ppsa-wifi-onboard.sh`
- PowerShell modules: PascalCase: `Logger.psm1`, `Builder.psm1`, `Configuration.psm1`
- PowerShell scripts: PascalCase with hyphen for main orchestrator: `Start-PpsaBuilder.ps1`
- Python: lowercase with underscores: `main.py`
- Test files: `test-<name>.ps1` pattern for PowerShell tests

**Functions:**
- **Python:** lowercase with underscores for private helpers (`_hash_pw`, `_verify_pw`, `_read_file`); lowercase for public routes (`health`, `dashboard`, `login`)
- **PowerShell:** Verb-Noun PascalCase following PowerShell standards: `Initialize-Logger`, `Write-LogInfo`, `Invoke-CommandCapture`, `Test-WslAvailable`, `Get-FileHashVerified`
- **Bash:** lowercase with underscores: `mark_step`, `ensure_loop_partition_node`; no verb-noun convention

**Variables:**
- **Python:** lowercase with underscores: `DATA_DIR`, `JWT_SECRET`, `PALWORLD_API_URL` (constants, uppercase)
- **PowerShell:** PascalCase for parameters and script-scoped vars: `$WslUser`, `$LogDirectory`, `$RepoRoot`; `$script:` prefix for module-scope globals
- **Bash:** UPPERCASE for constants and configuration: `PPSA_DIR`, `BUILD_DIR`, `CHAIN`, `WG_NET`

**Types:**
- **Python:** Pydantic `BaseModel` for request/response objects: `ConnectRequest`, `FirewallConfig`
- **PowerShell:** `[PSCustomObject]` for structured returns, explicit type hints on parameters: `[string]$LogDirectory`, `[hashtable]$ExtraEnv`

## Code Style

**Formatting:**
- **Python:** 
  - Lines follow natural Python convention (no explicit linter config found)
  - Import groups: standard library, third-party, local
  - Docstring style: triple-quoted with parameter descriptions inline in comments
  - Example: `docker/webui/app/main.py` uses consistent 4-space indentation, inline comments for complex logic
- **PowerShell:**
  - 4-space indentation (no explicit formatter config)
  - Param block at top of function with explicit `[CmdletBinding()]`
  - Comment style: `# Description` for single-line explanations
  - Example: `modules/Logger.psm1` uses consistent formatting with descriptive comment headers
- **Bash:**
  - 2-space indentation (implicit from script structure)
  - Quoted variables: `"$VAR"` throughout, not bare `$VAR`
  - `set -euo pipefail` (strict mode) is default; some scripts deliberately disable with `set +e` or `set +o pipefail` with explanatory comments
  - Example: `scripts/install.sh` includes "ponytail: " prefix comments explaining non-obvious choices

**Linting:**
- No `.eslintrc`, `.prettierrc`, or `biome.json` found
- No explicit Python linter config (no `pyproject.toml` or `.flake8`)
- PowerShell: no explicit linter config; style follows PowerShell best practices by convention

**Key style decisions documented in comments:**
- "ponytail: " prefix on comments indicates non-obvious design decisions or workarounds (seen in `docker/webui/app/main.py:30`, `scripts/install.sh:28`, `modules/Builder.psm1:35`)
- Explicit disable of `set -o pipefail` with justification in `scripts/install.sh:12-15`
- Comments explain **why**, not what (see `docker/webui/app/main.py:288-293` on Palworld empty-response handling)

## Import Organization

**Python:**
1. Standard library: `os`, `json`, `time`, `subprocess`, `asyncio`
2. Third-party: `httpx`, `docker`, `fastapi`, `pydantic`, `jose`, `bcrypt`
3. Local/internal: none (single-file app)

Example from `docker/webui/app/main.py`:
```python
import os
import json
import time
import shlex
import re
import asyncio
import subprocess
import zipfile
from pathlib import Path
from datetime import datetime, timedelta
from contextlib import asynccontextmanager

import httpx
import docker as _docker_sdk
from fastapi import FastAPI, HTTPException, Depends, status, UploadFile
```

**PowerShell:**
- Modules imported via `Import-Module` with path resolution
- Order: Utils → Logger → domain modules (Configuration, GitHub, Queue, Builder, Artifacts, VirtualBox, Status, SmokeTest)
- Example from `Start-PpsaBuilder.ps1:24`: "hardcoded module order matches build dependency chain"

**Bash:**
- Direct script sourcing (no import mechanism); helper functions defined inline
- Environment variables set at top of script

## Error Handling

**Patterns:**

**Python:**
- HTTPException for API errors: `raise HTTPException(status_code=401, detail="...")`
- Try/except for external calls (Palworld API, Docker exec, host exec)
- Graceful degradation in `palworld_get`: optional `default=` parameter returns default instead of raising on transient errors
- Example: `docker/webui/app/main.py:247-275` shows pattern for upstream failures

```python
async def palworld_get(path: str, default=_RAISE):
    try:
        # ... call Palworld API
    except HTTPException:
        raise
    except Exception:
        if default is _RAISE:
            raise
        return default
```

**PowerShell:**
- `$ErrorActionPreference = "Stop"` at top of script (strict error handling)
- Try/catch blocks for external process calls
- Return structured objects with `Valid`, `Hash`, `Error` fields: `[PSCustomObject]@{ Valid = $false; Hash = $null; Error = "..." }`
- Example: `modules/Utils.psm1:48-68` (Get-FileHashVerified)

**Bash:**
- `set -euo pipefail` (or `set -eu` with explicit `set +o pipefail` comment)
- Exit codes checked explicitly: `if [ $RC -eq 0 ]`
- Subshells for scoped error disabling: `(set +e; command; RC=$?)`
- Example: `scripts/install.sh:74-99` subshell with bounded timeouts and explicit RC checks

## Logging

**Framework:**
- **Python:** No framework; uses direct `print()` and file writes for logs (simple approach for single-app container)
- **PowerShell:** Custom `Logger.psm1` module with structured output
- **Bash:** Direct `echo` to stdout/file (captured by systemd journal or explicit redirect)

**Patterns:**

**PowerShell (modules/Logger.psm1):**
```powershell
Write-Log -Level TRACE/DEBUG/INFO/WARN/ERROR/SUCCESS -Module "ModuleName" -Message "..." -Command "..." -ExitCode $rc -Location "..." -RecommendedAction "..."
```
- Convenience wrappers: `Write-LogInfo`, `Write-LogError`, `Write-LogSuccess`
- Output: console (colored) + file (`build.log`), plus level-specific logs (`trace.log`, `error.log`)
- Timestamps in `yyyy-MM-dd HH:mm:ss.fff` format

**Python (docker/webui/app/main.py):**
- No structured logging; comments document key decision points
- Exception messages included in HTTPException detail field
- Host-exec commands return tuples: `(exit_code, stdout, stderr)` for caller inspection

**Bash:**
- Direct echo to stdout; systemd captures as journal
- Progress file updates: `echo "$n" > "$PROGRESS_FILE"` for external progress tracking
- Log file redirect: `exec > "$LOG_FILE" 2>&1`

## Comments

**When to Comment:**
- **Design decisions:** "ponytail: " prefix for non-obvious choices (e.g., why `set +o pipefail` is used, why direct chroot is a fallback)
- **API quirks:** Documented where third-party APIs have surprising behavior (e.g., Palworld returns empty 200 on save success)
- **Bug workarounds:** Explicit call-outs for known issues (e.g., bcrypt ≥4.0 behavior change in `main.py:30`)
- **Timing/performance notes:** When operations are intentionally slow or have ordering constraints

**JSDoc/TSDoc:**
- Not used (this is not a TypeScript/JavaScript codebase)
- Python docstrings: inline one-liners for FastAPI routes and helper functions
- Example: `docker/webui/app/main.py:62` (lifespan context manager docstring)

## Function Design

**Size:**
- **Python:** Typically 10-50 lines for routes; complex logic (WG tunnel, firewall) spans 30-100 lines with clear subsections
- **PowerShell:** 15-40 lines per function; module-level scripts are longer (orchestrator `Start-PpsaBuilder.ps1` is ~300 lines but well-commented)
- **Bash:** 5-20 lines for helper functions; main script body is linear for clarity (e.g., `scripts/install.sh` is 200+ lines but marked with numbered steps)

**Parameters:**
- **Python:** Explicit Pydantic models for complex payloads; query/path parameters via FastAPI dependency injection
- **PowerShell:** `[CmdletBinding()]` with explicit parameter types and validation; hashtable for optional key-value sets
- **Bash:** Positional args and environment variables; no function parameters except helpers

**Return Values:**
- **Python:** JSON dict/list (via FastAPI automatic serialization) or HTTPException on error
- **PowerShell:** Explicit `return` statement with structured object (`[PSCustomObject]`) or error via `throw`
- **Bash:** Exit code (0 success, non-zero error); stdout for string output; files for structured output (e.g., JSON result files)

## Module Design

**Exports:**
- **PowerShell:** Explicit `Export-ModuleMember -Function ...` at end of `.psm1` file (e.g., `modules/Logger.psm1:155`)
- **Python:** No module exports; single `main.py` FastAPI app
- **Bash:** No module system; functions defined in script or sourced from other scripts

**Barrel Files:**
- Not used (no ES6-style re-exports)
- Python has no internal module structure
- PowerShell modules are atomic (one `.psm1` per module)

## Configuration Management

**Environment Variables:**
- Read from `.env` file via `_parse_env()` in `docker/webui/app/main.py:436-446`
- Passed to build scripts via `PPSA_*` prefixed vars
- PowerShell reads from `wireguard.local.json` and `builder.json` (JSON, not env vars)

**Pattern:**
- Environment variables control feature flags (e.g., `PPSA_WG_ENABLED=true/false`)
- JSON configs for complex nested settings (firewall rules, WireGuard credentials)
- Secrets in `.env` are never logged or quoted in comments

---

*Convention analysis: 2026-07-16*
