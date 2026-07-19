---
phase: 04-dashboard-correctness-error-handling
verified: 2026-07-20T00:00:00Z
status: passed
score: 5/5 must-haves verified
behavior_unverified: 0
overrides_applied: 1
behavior_unverified_items: []
human_verification_resolved:
  - test: "Non-zero connected-player numeric count renders (real join)."
    resolution: "Accepted passed-by-inspection by the operator (2026-07-20). The {\"players\":[...]} object-shape fix + player_count-from-extracted-list logic are verified in source (main.py:445-455) and the empty/known-false paths were proven live on nb14; the only unexercised step is an actual client join, deemed negligible risk. Follow-up: exercise a real join in a future smoke run if a client is available."
---

# Phase 4: Dashboard Correctness & Error Handling Verification Report

**Phase Goal:** Make the WebUI dashboard tell the truth — real Palworld version, honest server-starting/empty states on fresh boot (not blanks/zeros), graceful degradation + actionable error messaging on upstream failures.
**Verified:** 2026-07-20
**Status:** human_needed
**Re-verification:** No — initial verification

## Goal Achievement

### Observable Truths

| # | Truth (DASH req) | Status | Evidence |
|---|------------------|--------|----------|
| 1 | DASH-01: Dashboard shows the real running game version even after the one-time startup log line rotates past the tail window | ✓ VERIFIED | `main.py:62` `_VERSION_CACHE={"value":""}`; `dashboard()` version resolution REST→log(tail 400)→cache at `main.py:414-435` — writes real values back to cache (`431`), falls back to cache (`432-433`), only emits "unavailable" when all three empty (`434-435`). Live nb14: `version="v1.0.1.100619"` while running AND with palworld stopped (cache holds). Frontend reads top-level `data.version` (`index.html:683-684`). |
| 2 | DASH-02: Fresh boot shows explicit "server starting" state, not a misleading 0-players | ✓ VERIFIED | `server_state` derived running/starting/stopped/unavailable at `main.py:404-412` (container running + REST not ok → "starting"). Frontend banner: starting→info "Palworld server is starting up" (`index.html:690-691`); stat-players shows "—" not "0" when `players_known` false (`668-669`). Live nb14: server_state transitions running→stopped→starting observed. |
| 3 | DASH-03: Metrics/player data render explicit empty/starting states, never silent blank or misleading zero; real count when players present | ✓ VERIFIED (numeric-count path → human) | Shape fix at `main.py:445-455`: extracts list from `{"players":[...]}` object, `player_count=len(player_list)`, `players_known=bool(rest_ok and players_ok and shape_ok)` — NOT `isinstance(raw,list)`. Old buggy `len(players) if isinstance(players,list)` is gone from dashboard(). Frontend: stat-players gated on players_known (`668-669`); FPS/uptime real→"Starting..."→"Metrics unavailable" (`675-679`); table three states Waiting/rows/No players (`700-706`). Live nb14: players_known true on healthy object shape, false when down. Numeric non-zero count not live-exercised (see Human Verification). |
| 4 | DASH-04: On upstream failure the dashboard stays usable, shows a banner, and does not hang on serial timeouts; /api/system degrades to 200 not 500 | ✓ VERIFIED | `main.py:389-393` single `asyncio.gather(...return_exceptions=True)` replaces three serial awaits — bounded to one timeout. `system_health()` (`472-567`) degrades per-section, returns 200 with top-level `degraded` (`563`) + `detail` (`566`), no HTTPException/500 in its body (ends at `567` with `return result`). Live nb14: palworld stopped → /api/dashboard http=200 in 0.089s (baseline ~21s http=000); /api/system 200 with degraded flag. |
| 5 | DASH-05: Frontend surfaces API/network errors as human-readable actionable messages, never raw stack, never silent | ✓ VERIFIED | `refreshDashboard()` catch (`index.html:707-712`) → `showAlert('Status refresh failed — check your connection. Retrying automatically...', 'error', 'dashboard-alert')`; `console.error` retained for debug only (no raw error in card). All state banners are friendly sentences (`690-696`). Backend never 500s on dashboard/system paths. Live nb14: structured error strings, no silent fail. |

**Score:** 5/5 truths verified (0 present-but-behavior-unverified)

### Required Artifacts

| Artifact | Expected | Status | Details |
|----------|----------|--------|---------|
| `docker/webui/app/main.py` — `dashboard()` | version cache, concurrent+bounded fetch, server_state, players_known | ✓ VERIFIED | `_VERSION_CACHE` (`62`), `asyncio.gather` (`389`), server_state (`404-412`), players_known + shape fix (`445-455`). Wired via `@app.get("/api/dashboard")`. |
| `docker/webui/app/main.py` — `system_health()` | graceful per-section degrade, 200 + degraded | ✓ VERIFIED | Per-probe try/except with `failures` list (`483-536`), `degraded: bool(failures)` (`563`), `detail` on degrade (`566`), returns 200. No bare 500. |
| `docker/webui/app/static/index.html` — `refreshDashboard()` | honest empty states keyed off server_state | ✓ VERIFIED | Full state-aware render (`658-713`), players_known guard, data.version read, catch→banner. |

### Key Link Verification

| From | To | Via | Status | Details |
|------|----|----|--------|---------|
| `dashboard()` server_state | `refreshDashboard()` card rendering | `data.server_state` drives 0-vs-placeholder | ✓ WIRED | `index.html:661` reads `data.server_state`; `starting`/`players_known` gate stat-players (`668-669`) and table (`700-706`). |
| `dashboard()` version cache | stat-version card | top-level `data.version` survives rotation | ✓ WIRED | `main.py:464` emits `version`; `index.html:683-684` reads `data.version` (not `data.server.version`). |
| `api()`/`refreshDashboard()` catch | `#dashboard-alert` banner | showAlert on error | ✓ WIRED | catch (`707`) → `showAlert(..., 'dashboard-alert')`; 4 showAlert targets in the function. |

### Behavioral Spot-Checks

| Behavior | Command | Result | Status |
|----------|---------|--------|--------|
| main.py parses | `python -c "ast.parse(...)"` | syntax-ok | ✓ PASS |
| asyncio + re imported | grep imports | `import re`, `import asyncio` present | ✓ PASS |
| gather present in dashboard | grep | gather-present | ✓ PASS |
| version log tail widened >=400 | regex assert | tail-ok (400) | ✓ PASS |
| degraded flag present | grep | degraded-ok | ✓ PASS |
| frontend error routing | showAlert count in refreshDashboard | 4 showAlerts, catch present | ✓ PASS |
| old player_count bug removed from dashboard() | grep | not present in dashboard() (only in unrelated /metrics + a comment) | ✓ PASS |

### Requirements Coverage

| Requirement | Source Plan | Status | Evidence |
|-------------|-------------|--------|----------|
| DASH-01 | 04-01 | ✓ SATISFIED | Truth 1 |
| DASH-02 | 04-01 | ✓ SATISFIED | Truth 2 |
| DASH-03 | 04-01 | ✓ SATISFIED (numeric count → human) | Truth 3 |
| DASH-04 | 04-01 | ✓ SATISFIED | Truth 4 |
| DASH-05 | 04-01 | ✓ SATISFIED | Truth 5 |

No orphaned requirements — all five DASH IDs mapped to plan 04-01 and to ROADMAP Phase 4 success criteria (1:1).

### Anti-Patterns Found

| File | Line | Pattern | Severity | Impact |
|------|------|---------|----------|--------|
| `main.py` | 113 | `len(players) if isinstance(players, list) else 0` in the Prometheus `/metrics` endpoint | ℹ️ Info | Same latent object-shape bug as the (now-fixed) dashboard path, but in a DIFFERENT function that is out of this phase's scope (plan explicitly scoped to dashboard()/system_health()). `/metrics` player count may read as 0/-1; not a DASH requirement. Recommend a follow-up. |

No debt markers (TODO/FIXME/XXX/TBD/HACK) in the changed regions. No silent failure, no stub, no misleading empty-data render.

### Architecture Invariants

| Invariant | Status | Evidence |
|-----------|--------|----------|
| No JS framework / build step / bundler | ✓ HELD | No `<script src>`/CDN/import added in index.html diff. |
| No new published ports; compose untouched | ✓ HELD | No compose/Dockerfile touched across phase commits. |
| `webui/frontend/` untouched | ✓ HELD | Phase diff touches only `docker/webui/app/{main.py,static/index.html}`. |
| Frontend limited to state/error rendering | ✓ HELD | +55 lines in index.html, rendering logic only; no CSS-class rename / markup move. |
| `palworld_get(path, default=)` contract preserved | ✓ HELD | Signature unchanged (`main.py:266`); dashboard uses raise-on-error + gather return_exceptions. |

### Human Verification Required

**1. Real connected-player numeric count (DASH-03 remaining sub-path)**

- **Test:** With at least one real Palworld client connected (join the server, or confirm via raw `/api/dashboard` JSON that `players.players` has entries), confirm the Players card shows the real numeric count (e.g. 1) and the Connected Players table lists the player.
- **Expected:** stat-players renders the real integer (not an em-dash, not a stuck 0); table shows the connected player row.
- **Why human:** The object-shape `player_count`/`players_known` logic is verified structurally in source and the empty/known-false paths were proven live on nb14, but SUMMARY notes no Palworld client was available to drive a non-zero count. Only a live join confirms the numeric-count path end-to-end.

### Gaps Summary

No blocking gaps. All five DASH requirements are implemented in the real source exactly as the SUMMARY claims, cross-checked line-by-line: durable version cache (`_VERSION_CACHE` read+write in dashboard()), widened 400-line log tail, single bounded `asyncio.gather`, `players_known` derived from the `{"players":[...]}` object shape (not `isinstance(raw,list)`), the pre-existing `player_count` always-0 bug fixed in dashboard(), `/api/system` per-section graceful degrade to 200+degraded, and honest state-aware frontend rendering with an actionable error banner. Architecture invariants (no framework/build, no new ports, `webui/frontend/` untouched) all hold. Task 3 was a blocking human-verify checkpoint executed live on VM nb14 and APPROVED with concrete evidence (0.089s vs 21s hang, version cache holding while stopped, state transitions observed).

The single item routed to human verification is the one sub-path the live session could not exercise — a real non-zero connected-player count — which is the only reason the overall status is `human_needed` rather than `passed`. One informational anti-pattern (the same latent shape bug surviving in the out-of-scope `/metrics` endpoint) is noted as a recommended follow-up, not a phase gap.

---

_Verified: 2026-07-20_
_Verifier: Claude (gsd-verifier)_
