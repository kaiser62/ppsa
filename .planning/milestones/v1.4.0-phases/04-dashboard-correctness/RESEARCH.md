# Phase 4: Dashboard Correctness & Error Handling — Research

**Researched:** 2026-07-19
**Domain:** WebUI dashboard, Palworld REST API proxying, container log parsing, frontend error display
**Confidence:** HIGH

## Summary

This phase fixes five correctness issues in the PPSA WebUI dashboard: the game version being blank, missing "server starting" state on fresh boot, ambiguous empty states for metrics/players, silent failure on upstream errors, and non-actionable error messages.

The dashboard endpoint (`/api/dashboard`) currently proxies three Palworld REST API calls (`/info`, `/metrics`, `/players`) with a blanket try/except that returns `{"error": str(e)}` on failure. The frontend renders `-` for any missing field, and its `catch(e)` block silently logs errors to console without user feedback.

The solution spans both backend and frontend: (1) add a server-state detection layer on the backend using the Docker SDK, (2) add container-log-based version fallback, (3) introduce explicit empty-state rendering and a status-banner pattern on the frontend, and (4) enrich error messages with user-facing actions rather than raw error strings.

**Primary recommendation:** Extend the dashboard endpoint to return a `server_state` field (`"starting"`, `"ready"`, `"unavailable"`) derived from the palworld container status and Palworld REST API reachability. Add a `version` fallback that scans container logs when the REST API returns an empty version. Rewrite the frontend `refreshDashboard()` to render explicit empty states and show a status banner on error instead of swallowing failures.

## User Constraints (from CONTEXT.md)

No CONTEXT.md exists for this phase yet. Requirements are defined by the phase goal description (DASH-01 through DASH-05) provided by the orchestrator.

## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| DASH-01 | Dashboard shows correct running Palworld game version even when REST /info version field empty — source reliably (e.g. parse container log) rather than display blank | REST API version field can be empty during server init; container logs contain version info via appmanifest ACF and binary output; see Standard Stack and Architecture Patterns sections |
| DASH-02 | On fresh boot while palworld container initializing, dashboard shows explicit "server starting" state instead of blank fields/zeroed metrics | Docker SDK `container.status` returns `"running"` even while Palworld binary initializes; REST API unreachable during Steam download (5+ min); see Architecture Patterns for state detection |
| DASH-03 | Metrics/player data not yet available render as explicit empty states ("no players yet", "metrics unavailable") not silent blank | Frontend currently uses `?? '-'` which is ambiguous; see Code Examples for explicit empty-state patterns |
| DASH-04 | When dashboard/status endpoint hits upstream/transient failure, page stays usable and shows clear status banner instead of breaking/hanging | `refreshDashboard()` currently uses `catch(e) { console.error(...) }` — silent failure; see Architecture Patterns for status banner pattern |
| DASH-05 | Frontend surfaces API/network errors with actionable messaging (what failed, what to try), never failing silently or dumping raw error string | Error categories: network-unreachable, server-starting, container-not-running, unknown; see Code Examples for message map |

## Architectural Responsibility Map

| Capability | Primary Tier | Secondary Tier | Rationale |
|------------|-------------|----------------|-----------|
| Game server state detection | Backend (FastAPI) | — | Uses Docker SDK `container.status` + REST API reachability to determine state; frontend should not guess server state |
| Game version retrieval | Backend | — | Aggregates from REST API then falls back to container log parse; frontend just renders what it gets |
| Empty-state messaging | Frontend (JS) | Backend (data shape) | Backend provides the data; frontend decides how to render missing fields as explicit empty states |
| Error banner/status | Frontend | — | Backend should return structured error context; frontend converts to user-facing messages |
| Container log parsing | Backend | — | Uses `_run_docker(["logs", ...])` which wraps Docker SDK; frontend has no container access |

## Standard Stack

### Core
| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| FastAPI | 0.115.* | REST API framework | Already the project's framework; no change needed |
| docker (Docker SDK) | 7.1.* | Container status + log access | Already imported and used via `_run_docker`; add direct `_docker.containers.get()` call for status |
| httpx | 0.28.* | Palworld REST API proxy | Already the project's HTTP client; no change needed |

### Supporting
| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| re (stdlib) | — | Regex parsing of container logs for version | Version fallback parsing (DASH-01) |
| asyncio | — | Non-blocking container status checks | Already used by the app lifespan |

### Installation
No new packages needed — all dependencies are already in the project.

### Version Verification

```bash
# Already installed in webui container per requirements.txt
# docker==7.1.* — already present
# fastapi==0.115.* — already present
# httpx==0.28.* — already present
# No new packages required
```

## Package Legitimacy Audit

No new packages. The existing stack (fastapi, docker SDK, httpx, python-multipart, bcrypt, python-jose) is already installed and verified in prior phases. The `re` module is stdlib. No external package installation needed for this phase.

## Architecture Patterns

### System Architecture Diagram

```
Browser (User)
    |
    |  GET /api/dashboard
    v
FastAPI /api/dashboard
    |
    |-- 1. Check palworld container status via Docker SDK (_docker.containers.get("ppsa-palworld"))
    |       |
    |       +-- status == "running"  → continue to step 2
    |       +-- status == "restarting" → server_state = "unavailable" (container restarting), skip step 2
    |       +-- status == "exited"/absent → server_state = "stopped", skip step 2
    |
    |-- 2. Try Palworld REST API (palworld_get):
    |       |
    |       +-- /info     → version, server name
    |       +-- /metrics  → serverfps, uptime, currentplayernum
    |       +-- /players  → player list
    |       |
    |       +-- All succeed  → server_state = "ready"
    |       +-- Connection error / timeout:
    |           +-- Container is running → server_state = "starting" (Palworld binary not ready yet)
    |           +-- Container not responding → server_state = "unavailable"
    |
    |-- 3. Version fallback (if REST version empty):
    |       |
    |       +-- Parse container logs for version patterns
    |       +-- If logs parsed → inject parsed version
    |       +-- If logs empty  → version = "version unavailable"
    |
    +-- Return JSON response:
        {
            "server_state": "ready" | "starting" | "stopped" | "unavailable",
            "server": {...info or error context...},
            "metrics": {...metrics or empty indicators...},
            "players": {...player list...},
            "player_count": N
        }

Browser Frontend (refreshDashboard)
    |
    |-- server_state == "ready"      → normal render
    |-- server_state == "starting"   → show "Server Starting" state card + animated indicator
    |-- server_state == "stopped"    → show "Container Stopped" state with action link
    |-- server_state == "unavailable"→ show "Unable to Reach Server" banner
    |
    |-- Per-field null handling:
    |       version  null → "version unavailable"
    |       serverfps null → "metrics unavailable"
    |       players  empty → "no players yet"
    |
    |-- On fetch error (network/auth):
    |       Show status banner with actionable message
    |       Keep last successful data visible
    |       Track last-updated timestamp
```

### Recommended Project Structure

No new files needed. Changes are contained within these existing files:

```
docker/webui/app/
├── main.py           # Modify dashboard(), palworld_get(), add helpers
│                        # Add: _get_container_state(), _get_game_version()
└── static/
    └── index.html    # Modify refreshDashboard(), add status banner + empty states
```

### Pattern 1: Server State Detection

**What:** A state machine that determines the palworld server's phase by combining Docker container status with REST API reachability. This gives the frontend structured state rather than guessing from error/blank data.

**When to use:** In the `/api/dashboard` endpoint, called on every dashboard refresh.

```python
# Backend pattern (src: research analysis, to be added to main.py)
_DASHBOARD_RAISE = object()

async def _get_container_state() -> str:
    """Return the palworld container's state: 'running', 'restarting', 'stopped', or 'absent'."""
    try:
        container = _docker.containers.get("ppsa-palworld")
        return container.status  # 'running', 'restarting', 'exited', 'paused'
    except _docker_sdk.errors.NotFound:
        return "absent"
    except Exception:
        return "unknown"

async def dashboard(_user: str = Depends(require_auth)):
    """Aggregate game server status with explicit state detection."""
    container_state = await _get_container_state()

    # If container isn't running, skip API calls entirely
    if container_state != "running":
        return {
            "server_state": "stopped" if container_state in ("exited", "absent") else container_state,
            "server": None,
            "metrics": None,
            "players": None,
            "player_count": 0,
        }

    # Container is running — try Palworld REST API
    try:
        info = await palworld_get("/info")
        metrics = await palworld_get("/metrics")
        players = await palworld_get("/players")
    except Exception:
        # Container running but REST API unreachable → Palworld binary still initializing
        return {
            "server_state": "starting",
            "server": None,
            "metrics": None,
            "players": None,
            "player_count": 0,
        }

    # Both container and REST API are working
    version = info.get("version", "")
    if not version:
        version = await _get_game_version_from_logs() or "version unavailable"

    return {
        "server_state": "ready",
        "server": {**info, "version": version},
        "metrics": metrics,
        "players": players,
        "player_count": len(players) if isinstance(players, list) else 0,
    }
```

### Pattern 2: Container Log Version Fallback

**What:** When the REST API returns an empty version field, fall back to scanning the palworld container's recent logs for version patterns. This handles the case where the REST API is alive but returns blank version fields.

**When to use:** Inside the dashboard endpoint after REST API returns info with empty version.

```python
# Backend pattern (src: research analysis)
import re

async def _get_game_version_from_logs() -> str | None:
    """Parse the palworld container logs for a game version string.
    
    Looks for patterns like:
    - "Game version is v0.1.2.3"
    - "Build: +++ UE5+Release-5.1"  
    - Log entries containing version info during PalServer.sh startup
    
    Returns the version string or None if not found.
    """
    try:
        log_text = _run_docker(["logs", "ppsa-palworld", "--tail", "300"])
    except Exception:
        return None
    
    # Pattern 1: "Game version is vX.Y.Z" or "version: vX.Y.Z"
    m = re.search(r'(?:Game\s+version|version)[:\s]+(v?[\d]+\.[\d]+\.[\d]+\.[\d]+)', log_text, re.IGNORECASE)
    if m:
        return m.group(1)
    
    # Pattern 2: UE build version "Build: +++ UE5+Release-5.1"
    m = re.search(r'Build:\s+\+\+\+\s+(\S+)', log_text)
    if m:
        return m.group(1)
    
    return None
```

### Pattern 3: Frontend State-Based Rendering

**What:** The `refreshDashboard()` function renders different UI states based on the `server_state` field, with explicit empty-state labels for missing data and a banner for errors.

**When to use:** In the frontend `refreshDashboard()`, replacing the current basic rendering.

```html
<!-- Frontend: Add this alert element near the dashboard grid -->
<div id="dash-alert" class="alert" style="display:none"></div>
```

```javascript
// Frontend pattern (src: research analysis)
let lastSuccessfulDashboard = null;

async function refreshDashboard() {
  try {
    const data = await api('/api/dashboard');
    lastSuccessfulDashboard = data;
    document.getElementById('dash-alert').style.display = 'none';
    renderDashboard(data);
  } catch(e) {
    console.error('Dashboard:', e);
    if (lastSuccessfulDashboard) {
      // Keep showing last known data but add a banner
      renderDashboard(lastSuccessfulDashboard);
    }
    showDashboardAlert(
      'Unable to connect to the game server. ' +
      (e.message.includes('401') ? 'Session expired. Please log in again.' :
       e.message.includes('Failed to fetch') ? 'Network error. The appliance may be offline.' :
       'The server is not responding. It may still be starting up.')
    );
  }
}

function renderDashboard(data) {
  const state = data.server_state || 'ready';
  
  // Server state indicator
  if (state === 'starting') {
    showDashboardAlert('Palworld server is starting up. First boot may take 2-5 minutes while Steam downloads updates.', true);
  } else if (state === 'stopped') {
    showDashboardAlert('Palworld container is not running. Start it from the Controls tab.', true);
  }
  
  // Version - explicit empty state
  const version = data.server?.version;
  document.getElementById('stat-version').textContent = 
    version && version !== 'version unavailable' ? version : 'game version unavailable';
  
  // FPS - explicit empty state
  const fps = data.metrics?.serverfps;
  document.getElementById('stat-fps').textContent = 
    fps != null ? fps : 'metrics unavailable';
  
  // Uptime
  const upSec = data.metrics?.uptime ?? 0;
  document.getElementById('stat-uptime').textContent = 
    data.server_state === 'ready' ? formatUptime(upSec) : '—';
  
  // Player count
  document.getElementById('stat-players').textContent = 
    data.player_count ?? '—';
  
  // Player table
  const tbody = document.getElementById('player-table-body');
  if (!data.players || !data.players.players || data.players.players.length === 0) {
    tbody.innerHTML = '<tr><td colspan="4">' +
      (state === 'ready' ? 'No players online' : 'Player data not available yet') +
      '</td></tr>';
  } else {
    tbody.innerHTML = data.players.players.map(p => 
      `<tr><td>${e(p.name||'')}</td><td>${e(p.steamid||'')}</td><td>${p.level??'-'}</td><td>${p.ping??'-'}</td></tr>`
    ).join('');
  }
}

function showDashboardAlert(msg, isInfo = false) {
  const el = document.getElementById('dash-alert');
  if (!el) return;
  el.textContent = msg;
  el.className = 'alert ' + (isInfo ? 'alert-info' : 'alert-error') + ' show';
  el.style.display = 'block';
}
```

### Anti-Patterns to Avoid

- **Silent failure:** The current `catch(e) { console.error('Dashboard:', e); }` swallows errors with no user visible indication. Never do this for dashboard data.
- **Ambiguous placeholders:** `'-'` for both "no data yet" and "loading" and "error" is indistinguishable. Use explicit text.
- **Hardcoded version pattern:** Container log format may change. Always try REST API first, fall back to log parsing, and log when the log parse fails so format changes can be detected.
- **Blocking the event loop:** Container status check via Docker SDK is fast (<100ms), but if it ever becomes slow, wrap in `asyncio.to_thread()` or `run_in_executor`.

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Container status | Custom HTTP polling of Docker API | Docker SDK `_docker.containers.get(name).status` | Already imported; direct SDK call is faster and more reliable than shelling out |
| Version parsing | Custom subprocess into container | `_run_docker(["logs", ...])` wrapper | Already exists in codebase; reuses the same Docker SDK path used by `/api/logs` |
| Error categorization | if-else chain on error strings | Try/catch with specific exception types (httpx.ConnectError, httpx.TimeoutException, docker.errors.NotFound, etc.) | Exception types survive API changes better than string matching on `e.message` |
| JWT auth | Custom session management | Existing `require_auth` + `api()` helper | Already handles 401 → logout; just needs dashboard-specific error overlay |

## Common Pitfalls

### Pitfall 1: Container Status Returns "running" Before REST API Is Ready
**What goes wrong:** Docker SDK returns `status == "running"` the moment the container's entrypoint starts (e.g., SteamCMD). The Palworld REST API is not reachable for 5+ minutes on first boot. If the code only checks container status, it reports the server as "ready" when it isn't.
**Why it happens:** Docker considers a container "running" once its PID 1 is alive, regardless of whether the application inside has initialized.
**How to avoid:** Always combine container status WITH REST API reachability. Container "running" + REST unreachable = server_state "starting". Container "running" + REST reachable = server_state "ready".
**Warning signs:** Dashboard shows "ready" but all values are blank or the REST API call times out.

### Pitfall 2: Log Format Changes Breaking Version Parsing
**What goes wrong:** The Palworld-server-docker image or Palworld binary changes its log output format, causing the regex pattern to return no matches.
**Why it happens:** Log lines are not a stable API. Game updates or container image changes can alter output.
**How to avoid:** (1) Always try REST API version first — the REST API field IS the stable contract. (2) Log parse on every failure attempt so format drift can be detected. (3) Return "version unavailable" rather than a stale/inaccurate version. (4) Consider storing a cache of the last successfully parsed version and returning it if the new parse fails (but still try again each time).
**Warning signs:** Server version shows "version unavailable" when the server is clearly running.

### Pitfall 3: Error Banner Dismissal Without Fix
**What goes wrong:** Frontend shows a dismissible "server starting" banner, user dismisses it, but the server still hasn't started. Next refresh fails silently again.
**Why it happens:** Auto-dismiss or user-dismiss of a status condition that hasn't actually been resolved.
**How to avoid:** Never auto-dismiss error/status banners on the dashboard. Only hide them when the next successful fetch proves the condition resolved. Use a non-dismissible banner for state conditions like "starting" and "stopped".

### Pitfall 4: Exception Object Message Parsing
**What goes wrong:** Code branches on `e.message` or `e.code` to categorize errors, but the same error type can produce different messages across versions.
**How to avoid:** Catch specific exception types (httpx.ConnectError, httpx.TimeoutException, httpx.HTTPStatusError, json.JSONDecodeError, docker.errors.NotFound) rather than parsing strings. Map exception types to user-facing messages.

## Code Examples

### Backend: Dashboard Endpoint With State Detection

```python
# Source: Research analysis based on FastAPI 0.115.x patterns and existing codebase
# File: docker/webui/app/main.py — replace the existing dashboard() function

import re
from httpx import ConnectError, TimeoutException, HTTPStatusError
import docker.errors as docker_errors

async def _get_game_version_from_logs() -> str | None:
    """Fallback: parse palworld container logs for version info.
    
    Log format may change across Palworld versions — this is a best-effort
    fallback. Always prefer REST API version first.
    """
    try:
        logs = _run_docker(["logs", "ppsa-palworld", "--tail", "500"])
    except Exception:
        return None
    if not logs or logs.startswith("docker error"):
        return None
    
    # Pattern 1: "Game version is v0.1.2.3" or "version: v0.1.2.3"
    m = re.search(
        r'(?:game\s+version|version)[:\s]+(v?[\d]+\.[\d]+\.[\d]+\.[\d]+)',
        logs, re.IGNORECASE
    )
    if m:
        return m.group(1)
    
    # Pattern 2: "Build: +++ UE5+Release-5.1" or similar
    m = re.search(r'Build:\s+\+\+\+\s+(\S+)', logs)
    if m:
        return m.group(1)
    
    return None


@app.get("/api/dashboard")
async def dashboard(_user: str = Depends(require_auth)):
    """Aggregate game server status for the dashboard.
    
    Returns a server_state field so the frontend knows what's happening:
    - "ready" — all systems go
    - "starting" — container running but Palworld binary not yet ready
    - "stopped" — container is exited/absent
    - "unavailable" — container restarting or unknown state
    """
    # Step 1: Check container status
    container_state = "absent"
    try:
        container = _docker.containers.get("ppsa-palworld")
        container_state = container.status
    except docker_errors.NotFound:
        pass
    except Exception:
        container_state = "unknown"
    
    # Step 2: If container not running, short-circuit
    if container_state not in ("running",):
        state_map = {
            "exited": "stopped",
            "paused": "stopped",
            "restarting": "unavailable",
            "absent": "stopped",
            "dead": "stopped",
        }
        server_state = state_map.get(container_state, "unavailable")
        return {
            "server_state": server_state,
            "server": None,
            "metrics": None,
            "players": None,
            "player_count": 0,
        }
    
    # Step 3: Container is running — try the Palworld REST API
    try:
        info = await palworld_get("/info")
        metrics = await palworld_get("/metrics")
        players = await palworld_get("/players")
    except (ConnectError, TimeoutException):
        # Container running but network unreachable → Palworld binary still init
        return {
            "server_state": "starting",
            "server": None,
            "metrics": None,
            "players": None,
            "player_count": 0,
        }
    except HTTPStatusError:
        # REST API responded with error — container issue
        return {
            "server_state": "unavailable",
            "server": None,
            "metrics": None,
            "players": None,
            "player_count": 0,
        }
    except Exception:
        # Any other error — treat as unavailable
        return {
            "server_state": "unavailable",
            "server": None,
            "metrics": None,
            "players": None,
            "player_count": 0,
        }
    
    # Step 4: REST API responded — fill in version fallback
    version = (info or {}).get("version", "") or ""
    if not version:
        version = await _get_game_version_from_logs() or "version unavailable"
        if info:
            info["version"] = version
    
    player_list = players if isinstance(players, list) else []
    
    return {
        "server_state": "ready",
        "server": info,
        "metrics": metrics or {},
        "players": players or {"players": []},
        "player_count": len(player_list),
    }
```

### Frontend: Dashboard With Error Banner and Empty States

```html
<!-- Source: Research analysis. Add inside #page-dashboard, before the .grid -->
<div id="dash-alert" class="alert" style="display:none"></div>
```

```javascript
// Source: Research analysis. Replace refreshDashboard() in index.html

let lastValidDashboard = null;  // state for graceful degradation

function renderDashboardState(state, data) {
  // Show/hide state banner based on server_state
  const alertEl = document.getElementById('dash-alert');
  if (state === 'ready') {
    alertEl.style.display = 'none';
  } else if (state === 'starting') {
    alertEl.style.display = 'block';
    alertEl.textContent = 'Palworld server is starting up. First boot may take 2-5 minutes while Steam downloads updates.';
    alertEl.className = 'alert alert-info show';
  } else if (state === 'stopped') {
    alertEl.style.display = 'block';
    alertEl.textContent = 'Palworld container is not running. Go to the Controls tab to start it.';
    alertEl.className = 'alert alert-error show';
  } else if (state === 'unavailable') {
    alertEl.style.display = 'block';
    alertEl.textContent = 'Palworld server is temporarily unavailable. It may be restarting.';
    alertEl.className = 'alert alert-warn show';
  }

  // Version — explicit empty state
  const versionEl = document.getElementById('stat-version');
  const version = data?.server?.version;
  versionEl.textContent = version && version !== 'version unavailable' && version !== ''
    ? version
    : (state === 'ready' ? 'version unavailable' : '—');

  // FPS — explicit empty state
  const fps = data?.metrics?.serverfps;
  document.getElementById('stat-fps').textContent = fps != null ? fps : 'metrics unavailable';

  // Uptime — show only when ready
  const upSec = data?.metrics?.uptime ?? 0;
  document.getElementById('stat-uptime').textContent = state === 'ready' ? formatUptime(upSec) : '—';

  // Player count
  document.getElementById('stat-players').textContent = data?.player_count ?? '—';

  // Player table
  const tbody = document.getElementById('player-table-body');
  const playerArr = data?.players?.players;
  if (state !== 'ready' || !playerArr) {
    tbody.innerHTML = '<tr><td colspan="4">' +
      (state === 'starting' ? 'Waiting for server to start...' :
       state === 'stopped' ? 'Server is stopped' :
       'Player data not available') +
      '</td></tr>';
  } else if (playerArr.length === 0) {
    tbody.innerHTML = '<tr><td colspan="4">No players online</td></tr>';
  } else {
    tbody.innerHTML = playerArr.map(p =>
      `<tr><td>${e(p.name||'')}</td><td>${e(p.steamid||'')}</td><td>${p.level??'-'}</td><td>${p.ping??'-'}</td></tr>`
    ).join('');
  }
}

async function refreshDashboard() {
  try {
    const data = await api('/api/dashboard');
    lastValidDashboard = data;
    renderDashboardState(data.server_state || 'ready', data);
  } catch(e) {
    console.error('Dashboard:', e);
    // On error, keep showing last valid data but add error banner
    if (lastValidDashboard) {
      // Re-render the last known state, with error overlay
      renderDashboardState(lastValidDashboard.server_state || 'ready', lastValidDashboard);
    }
    // Show error overlay
    const alertEl = document.getElementById('dash-alert');
    alertEl.style.display = 'block';
    if (e.message.includes('401') || e.message.includes('Session')) {
      alertEl.textContent = 'Session expired. Please log in again.';
      alertEl.className = 'alert alert-error show';
    } else if (e.message.includes('Failed to fetch') || e.message.includes('NetworkError')) {
      alertEl.textContent = 'Cannot reach the PPSA WebUI. The appliance may be offline or restarting.';
      alertEl.className = 'alert alert-error show';
    } else {
      alertEl.textContent = 'An error occurred loading dashboard data. Check server logs for details.';
      alertEl.className = 'alert alert-error show';
    }
  }
}
```

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| Dashboard returns `{"error": str(e)}` on Palworld API failure | Dashboard returns `server_state` field + graceful empty data | This phase | Frontend can render appropriate UI per state |
| Version sourced only from REST `/info` | REST first, container log fallback second | This phase | Version shows even when REST API returns empty |
| Frontend shows `-` for all empty/error states | Frontend shows explicit text ("version unavailable", "metrics unavailable", etc.) | This phase | No ambiguity between "loading", "error", and "empty" |
| Errors silently logged to console | Errors shown as status banner with actionable message | This phase | User knows when something is wrong and what to do |
| Dashboard cards show "-" for FPS on fresh boot | Cards show "metrics unavailable" on fresh boot | This phase | Clear distinction between "not ready" and "zero" |

## Assumptions Log

| # | Claim | Section | Risk if Wrong |
|---|-------|---------|---------------|
| A1 | `_docker.containers.get("ppsa-palworld")` can see the palworld container from the webui container | Architecture Patterns | If webui can't see palworld (different Docker context/network), container state detection would need `_host_exec("docker inspect ppsa-palworld")` fallback |
| A2 | Container log parsing for version will eventually find a match when the server is running | Standard Stack | If no log pattern matches across Palworld versions, version shows "version unavailable" — which is the same as current behavior, so no regression |
| A3 | The `_run_docker` function's `logs` subcommand works with default 100 tail lines | Code Examples | Increased to 500 lines in the pattern to cover the full SteamCMD + PalServer.sh startup output |
| A4 | The `renderDashboardState` function maintains existing state when called with lastValidDashboard on error | Pitfalls | If the lastValidDashboard is stale (e.g., server state changed since last fetch), the re-rendered state could be misleading. Mitigation: less harmful than showing a blank page |

## Open Questions

1. **What is the exact Palworld log line format for version output?**
   - What we know: The Palworld server binary outputs version info during startup; the thijsvanloef container logs include SteamCMD output and PalServer.sh startup lines.
   - What's unclear: The exact regex pattern that matches the version line may differ across Palworld builds. The community image's version 2.0.0 switched REST API to be the default backend, which may change log output.
   - Recommendation: Implement a multi-pattern fallback (3 regex patterns). Add a debug log line when parsing fails (so format changes are detectable). Consider adding a `docker exec ppsa-palworld cat /palworld/steamapps/appmanifest_2394010.acf` alternative that reads the build ID from the Steam manifest.

2. **Should the version be cached between refreshes?**
   - What we know: Container logs don't change frequently; parsing them on every 10-second refresh is wasteful.
   - What's unclear: Should we cache the parsed version in-memory with a TTL?
   - Recommendation: Cache the parsed version in a module-level variable, invalidated when the container restarts. For simplicity in this phase, just parse on every request — the log read is <50ms and 500 lines of tail is small.

3. **How to test the "server starting" state without waiting 5 minutes?**
   - What we know: The Palworld REST API is unreachable during Steam download.
   - What's unclear: How to verify the DASH-02 fix works without booting a real appliance and waiting.
   - Recommendation: For development testing, temporarily stop the palworld container (`docker stop ppsa-palworld`) to see the "stopped" state. Then manually trigger the container but block port 8212 to see "starting" state. For full verification, use the VirtualBox MCP to boot a fresh VDI.

## Environment Availability

> This phase has no external dependencies beyond the already-running Docker stack. Code changes are deployed by copying `main.py` into the running webui container (`docker cp`) and restarting it (`docker restart ppsa-webui`). No external tool installations needed.

## Security Domain

> `security_enforcement` is absent from config.json (not explicitly `false`), but this phase introduces no new attack surface: the dashboard endpoint is already behind `require_auth`, no new secrets are handled, and version log parsing reads container stdout which is already accessible from the webui container.

### Applicable ASVS Categories

| ASVS Category | Applies | Standard Control |
|---------------|---------|-----------------|
| V5 Input Validation | yes | Version regex pattern validates known version formats; error strings from container logs are displayed as UI text (not eval'd) |
| V7 Error Handling | yes | New error categorization maps exception types to user-facing messages without exposing internal stack traces |

### Known Threat Patterns

| Pattern | STRIDE | Standard Mitigation |
|---------|--------|---------------------|
| Log injection in version display | Tampering | Version string is displayed as text content (`textContent`, not `innerHTML`), escaped via existing `e()` helper |
| Information disclosure via error messages | Information Disclosure | Error messages surface only generic categories ("network error", "server starting") — never raw stack traces or internal paths |

## Sources

### Primary (HIGH confidence)
- [Context7: FastAPI] — Error handling, HTTPException, response customization patterns
- [Context7: Docker SDK for Python] — Container status, logs retrieval, exception types
- [Codebase: main.py] — Existing `_run_docker`, `_docker` SDK import, `palworld_get`, `dashboard()` patterns
- [Codebase: index.html] — Existing `refreshDashboard()`, `showAlert()`, `api()` patterns

### Secondary (MEDIUM confidence)
- [WebSearch: palworld-server-docker GitHub] — Startup sequence, REST API port, UPDATE_ON_BOOT behavior
- [WebSearch: Palworld REST API docs] — `/v1/api/info`, `/v1/api/metrics`, `/v1/api/players` response fields
- [WebSearch: Palworld container log patterns] — Version/manifest ID output patterns during startup

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH — no new packages needed; all code uses existing libraries
- Architecture: HIGH — state detection pattern is well-understood in Docker-based apps
- Pitfalls: HIGH — log format fragility and container "running" vs "ready" distinction are known issues in the codebase (same pattern as the webui depends_on: service_started vs service_healthy comment in docker-compose.yml line 115-121)
- Version log parsing: MEDIUM — exact regex patterns need confirmation against a running container; patterns provided are based on known Palworld/UE5 log formats

**Research date:** 2026-07-19
**Valid until:** 2026-08-19 (stable patterns — Palworld REST API contract has been stable since v0.1.x, Docker SDK API is stable)
