# Testing Patterns

**Analysis Date:** 2026-07-16

## Test Framework

**Runner:**
- **PowerShell:** Custom test scripts (no framework; each file is self-contained)
- **Python:** No test suite found (WebUI tested manually via HTTP requests)
- **Bash:** No automated test suite (built image tested via VirtualBox smoke tests in PowerShell)

**Assertion Library:**
- **PowerShell:** Manual assertions via `if (...) { throw "message" }`
- **Python:** N/A
- **Bash:** N/A

**Run Commands:**
```bash
# PowerShell tests (each is independent)
pwsh tests/test-logger.ps1
pwsh tests/test-utils.ps1
pwsh tests/test-github.ps1
pwsh tests/test-configuration.ps1
pwsh tests/test-queue.ps1
pwsh tests/test-builder.ps1
pwsh tests/test-artifacts.ps1
pwsh tests/test-status.ps1
pwsh tests/test-virtualbox.ps1
pwsh tests/test-smoketest.ps1

# Python WebUI (no test runner; manual verification)
cd docker/webui/app
pip install -r requirements.txt
uvicorn main:app --reload --port 8080
# Test via HTTP: curl http://localhost:8080/health, http://localhost:8080/api/login, etc.

# Bash build (tested via CI GitHub Actions)
# Local: sudo bash scripts/build-live-usb.sh --output /tmp/ppsa.img --size 8192
```

## Test File Organization

**Location:**
- PowerShell tests: `tests/test-*.ps1` (separate from module files)
- Python: No test files (manual/integration testing only)
- Bash: No test files (build tested via smoke test in VirtualBox)

**Naming:**
- Pattern: `test-<module-name>.ps1`
- Example: `tests/test-logger.ps1`, `tests/test-builder.ps1`

**Structure:**
```
tests/
├── test-logger.ps1          # Tests Logger.psm1 functionality
├── test-utils.ps1           # Tests Utils.psm1 functionality
├── test-configuration.ps1   # Tests Configuration.psm1 functionality
├── test-github.ps1          # Tests GitHub.psm1 functionality
├── test-queue.ps1           # Tests Queue.psm1 functionality
├── test-builder.ps1         # Tests Builder.psm1 functionality
├── test-artifacts.ps1       # Tests Artifacts.psm1 functionality
├── test-status.ps1          # Tests Status.psm1 functionality
├── test-virtualbox.ps1      # Tests VirtualBox.psm1 functionality
└── test-smoketest.ps1       # Tests SmokeTest.psm1 functionality
```

## Test Structure

**PowerShell Test Suite Organization:**

Each test file follows this pattern:

```powershell
# 1. Set error handling
$ErrorActionPreference = "Stop"

# 2. Load module under test
$modulePath = Join-Path $PSScriptRoot "..\modules\<ModuleName>.psm1"
Remove-Module <ModuleName> -ErrorAction SilentlyContinue
Import-Module $modulePath -Force

# 3. Setup test environment
$testDir = Join-Path $env:TEMP "ppsa-test-<name>-$(Get-Random)"

try {
    # 4. Write-Host "[TEST] <description>..." -ForegroundColor Cyan
    # 5. Execute test logic
    # 6. Assert: if (...) { throw "failure message" }
    # 7. Write-Host "  PASS: <description>" -ForegroundColor Green
    
    Write-Host "`n[SUCCESS] All <ModuleName> tests passed!" -ForegroundColor Green
} finally {
    # Cleanup
    Remove-Item $testDir -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Module <ModuleName> -ErrorAction SilentlyContinue
}
```

**Live Example (tests/test-logger.ps1):**

```powershell
# Test 1: Initialize creates directory and cleans old logs
Write-Host "[TEST] Initialize-Logger..." -ForegroundColor Cyan
Initialize-Logger -LogDirectory $testLogDir -Levels @("TRACE","DEBUG","INFO","WARN","ERROR","SUCCESS")
if (-not (Test-Path $testLogDir)) { throw "Log directory not created" }
Write-Host "  PASS: Log directory created" -ForegroundColor Green

# Test 2: Write-LogInfo writes to console and file
Write-Host "[TEST] Write-LogInfo..." -ForegroundColor Cyan
Write-LogInfo -Module "Test" -Message "hello info"
$logFile = Join-Path $testLogDir "build.log"
if (-not (Test-Path $logFile)) { throw "build.log not created" }
$content = Get-Content $logFile
if ($content -notmatch "INFO.*Test.*hello info") { throw "build.log missing expected content" }
Write-Host "  PASS: build.log contains INFO message" -ForegroundColor Green
```

**Patterns:**
- **Setup:** Create isolated temp directory, import module fresh (remove any cached version first)
- **Teardown:** Always run in `finally` block; clean up temp dirs and unload modules
- **Assertions:** Throw on failure with descriptive message
- **Output:** Color-coded console messages (Cyan for test name, Green for PASS, Red for errors)
- **No fixtures/factories:** Tests create minimal inline test data

## Mocking

**Framework:**
- No mocking framework used
- Manual mocking via function overrides (not seen in existing tests)
- Docker/host operations tested via real processes (e.g., `Invoke-CommandCapture` runs actual commands)

**Patterns:**
- Docker SDK (`_docker`) in `docker/webui/app/main.py` is imported directly; no mocking of Docker API calls
- Host exec (`_host_exec`) returns real subprocess output; cannot be mocked in container context
- PowerShell tests create real temp directories and real files (no file I/O mocking)

**What to Mock:**
- External APIs: Palworld API calls could be mocked via `httpx` fixture, but not currently done
- Host operations: Cannot mock in WebUI container (missing namespace/permissions)
- Subprocess calls: Generally not mocked; tests use real processes for fidelity

**What NOT to Mock:**
- File I/O: Tests use real temp directories to ensure write permissions work
- Process execution: Real `Invoke-CommandCapture` calls for accurate exit code/output behavior
- Module loading: Tests reload modules to test initialization

## Fixtures and Factories

**Test Data:**
- **PowerShell:** No factory pattern; tests create minimal test data inline
  - Example: `tests/test-logger.ps1` creates a temp directory with `Join-Path $env:TEMP "ppsa-test-logger-$(Get-Random)"`
  - Example: `tests/test-logger.ps1:26-34` manually constructs error log entry with explicit fields

- **Python:** No fixture files; test data would be hardcoded in route test calls (not currently tested)

**Location:**
- Tests are self-contained in `tests/test-*.ps1` files
- No separate fixtures directory
- No shared test utilities (each test imports its module independently)

## Coverage

**Requirements:**
- No explicit coverage target
- No coverage tool configured (no `.coveragerc`, `coverage.xml`, or `pytest.ini`)

**View Coverage:**
- Not applicable (no automated test runner)
- Manual testing via running test scripts individually

## Test Types

**Unit Tests:**
- **PowerShell (tests/test-logger.ps1, tests/test-utils.ps1, etc.):**
  - Scope: Individual PowerShell module functions
  - Approach: Create temp directories, call functions, verify output files and return values
  - Example: `tests/test-logger.ps1` tests all Logger.psm1 functions in isolation
  - Independent: Each `test-*.ps1` can run standalone (imports its module fresh)

**Integration Tests:**
- **PowerShell (tests/test-builder.ps1, tests/test-smoketest.ps1):**
  - Scope: Multi-module workflows (Builder calls Utils, Artifacts, VirtualBox; SmokeTest boots real VirtualBox VM)
  - Approach: Create realistic build/test scenarios (e.g., SmokeTest runs actual appliance in VirtualBox)
  - Coverage: Build end-to-end from source to artifact; verify image boots and services are up

**E2E Tests:**
- **VirtualBox Smoke Test (modules/SmokeTest.psm1 → tests/test-smoketest.ps1):**
  - Framework: VirtualBox MCP tool (not a traditional framework)
  - Approach: Boot the built `.vdi` in VirtualBox, verify SSH access, check systemd services
  - Trigger: Called from PowerShell orchestrator after Artifacts.psm1 converts `.img` to `.vdi`
  - Gate: Build succeeds only if smoke test passes (or `--SkipSmokeTest` flag is set)

- **CI Testing (GitHub Actions):**
  - Trigger: `push` to `netbird` branch or manual `gh workflow run`
  - Approach: Build image in Ubuntu runner, convert to VDI, boot in VirtualBox
  - Verification: Same smoke test as local builder (systemd units up, SSH reachable)

- **WebUI Manual Testing:**
  - No E2E framework; tested via HTTP requests to running container
  - Procedure: Start WebUI container, call `/health`, `/api/login`, other routes manually
  - Coverage: Happy-path flows (login → get dashboard → restart server) verified in browser/curl

## Common Patterns

**Async Testing:**

**Python (docker/webui/app/main.py):**
```python
# All FastAPI routes are async
@app.get("/api/dashboard")
async def dashboard(_user: str = Depends(require_auth)):
    try:
        info = await palworld_get("/info")
        metrics = await palworld_get("/metrics")
        players = await palworld_get("/players")
    except Exception as e:
        info = {"error": str(e)}
        metrics = {}
        players = []
    return {...}
```
- Pattern: `try/except` wrapping async calls; return empty/default on failure
- Testing: Manual HTTP requests to running uvicorn instance; no pytest fixtures

**PowerShell:**
```powershell
# No async pattern (PowerShell 5.1 has limited async support)
# Uses synchronous process execution with timeouts instead
$result = Invoke-CommandCapture -FileName "wsl" -Arguments @(...) -TimeoutSeconds 7200
if ($result.ExitCode -ne 0) { throw "build failed: $($result.Stderr)" }
```

**Error Testing:**

**PowerShell:**
```powershell
# Test error handling with explicit try/catch
Write-Host "[TEST] Measure-Phase (error)..." -ForegroundColor Cyan
$caught = $false
try {
    Measure-Phase -Module "Test" -Name "fail-phase" -ScriptBlock { throw "intentional failure" }
} catch {
    $caught = $true
    if ($_ -notmatch "intentional failure") { throw "unexpected error message" }
}
if (-not $caught) { throw "Measure-Phase did not propagate error" }
Write-Host "  PASS: Measure-Phase propagated error" -ForegroundColor Green
```
- Pattern: Wrap function call in try/catch; verify error is propagated
- Assert: Use `if (-not $caught)` to confirm error was not silently swallowed

**Python:**
```python
# Test error responses via explicit exception raising
try:
    detail = await _wg_apply("up")
except HTTPException as e:
    return {
        "status": "config_written",
        "detail": f"Config written but tunnel start failed: {e.detail}",
        "ppsa_public_key": pub_key,
    }
```
- Pattern: Catch HTTPException and return graceful fallback response
- Testing: Manual HTTP request verifies 200 with degraded status (not 500)

## Test Execution

**Local PowerShell Tests:**
```bash
# Run all tests
for test in tests/test-*.ps1; do
    pwsh "$test" || exit 1
done

# Run single test
pwsh tests/test-logger.ps1
```

**WebUI Manual Verification:**
```bash
cd docker/webui/app
pip install -r requirements.txt
uvicorn main:app --reload --port 8080

# In another terminal:
curl -X POST http://localhost:8080/api/login \
  -H "Authorization: Basic YWRtaW46YWRtaW4=" \
  -H "Content-Type: application/json"

curl -H "Authorization: Bearer <token>" http://localhost:8080/api/dashboard
```

**Build Smoke Test (CI and Local):**
```bash
# Via GitHub Actions
gh workflow run build-release.yml

# Via local WSL builder (PowerShell)
pwsh scripts/Start-PpsaBuilder.ps1 -Watch

# Smoke test logs in VirtualBox
# - Boot: ~2 minutes
# - Services check: ~30 seconds
# - SSH verify: ~10 seconds
```

---

*Testing analysis: 2026-07-16*
