---
phase: 04-dashboard-correctness-error-handling
plan: 01
subsystem: ui
tags: [fastapi, plain-js, palworld, dashboard, error-handling]

requires:
  - phase: 03-webui-backup-restore
    provides: WebUI FastAPI app + static frontend baseline
provides:
  - Durable game-server version (REST → container-log parse → last-known-good cache)
  - Honest fresh-boot dashboard states (server_state: running/starting/stopped)
  - players_known signal that fixes the {"players":[]} shape (no em-dash-forever / stuck 0)
  - Bounded concurrent upstream fetch (no ~15-21s dashboard hang on dead palworld)
  - Graceful /api/system degradation (200 + degraded flag, never bare 500)
  - Actionable frontend error banner (no raw errors, no silent failure)
affects: [05-professional-visual-redesign]

tech-stack:
  added: []
  patterns:
    - "Module-level last-known-good cache for values that appear only transiently upstream"
    - "asyncio.gather with per-call bounded timeout for independent upstream probes"
    - "Backend emits explicit state signals (server_state, players_known) so the frontend never guesses from empty payloads"

key-files:
  created:
    - .planning/phases/04-dashboard-correctness-error-handling/04-01-SUMMARY.md
  modified:
    - docker/webui/app/main.py
    - docker/webui/app/static/index.html

key-decisions:
  - "Source version defensively: REST server.version, else parse 'Game version is vX' from a widened (400-line) container-log tail, else serve the module-level last-known-good cache."
  - "Base players_known on rest_ok + expected payload shape (extract list from {\"players\":[...]}), NOT isinstance(raw, list) — the raw payload is an object, so the isinstance check was permanently false."
  - "Frontend changes limited to state/error rendering only; visual redesign deferred to Phase 5 (kept UI-SPEC clean)."

patterns-established:
  - "Honest empty states: distinguish real-zero (running + known) from unknown (starting/down) in the payload, render each differently."
  - "Never let one dead upstream stall the whole dashboard: bound + gather."

requirements-completed: [DASH-01, DASH-02, DASH-03, DASH-04, DASH-05]

coverage:
  - id: D1
    description: "Dashboard shows real Palworld version and it survives an outage (last-known-good cache)"
    requirement: DASH-01
    verification:
      - kind: e2e
        ref: "live nb14: /api/dashboard version=v1.0.1.100619 while running AND with palworld stopped; browser Version card renders it"
        status: pass
    human_judgment: false
  - id: D2
    description: "Fresh-boot / restart shows server_state starting-vs-running-vs-stopped instead of blanks"
    requirement: DASH-02
    verification:
      - kind: e2e
        ref: "live nb14: server_state transitions running→stopped→starting across docker stop/start"
        status: pass
    human_judgment: false
  - id: D3
    description: "players_known fixes the {players:[]} shape; explicit empty states, no stuck 0 / em-dash"
    requirement: DASH-03
    verification:
      - kind: e2e
        ref: "live nb14: players_known true on healthy server (object shape), false when down/starting; browser shows '0' + 'No players online'"
        status: pass
    human_judgment: false
  - id: D4
    description: "Graceful degradation, no hang: dashboard fast + /api/system 200 not 500 when palworld down"
    requirement: DASH-04
    verification:
      - kind: e2e
        ref: "live nb14: palworld stopped → /api/dashboard http=200 in 0.089s (baseline ~21s http=000); /api/system 200 degraded flag"
        status: pass
    human_judgment: false
  - id: D5
    description: "Actionable error messaging, never raw, never silent"
    requirement: DASH-05
    verification:
      - kind: e2e
        ref: "live nb14: errors are structured strings; backend never 500s; frontend error routing verified; only console noise is favicon 404"
        status: pass
    human_judgment: false
---

# Phase 04 / Plan 01 — Dashboard Correctness & Error Handling

## Context

Verify-and-harden plan over dashboard code a prior ad-hoc session had already
committed (`4a415dc`: `server_state`, a `--tail 50` version log-parse, a state
banner). This plan closed the remaining correctness gaps and hardened the
backend/frontend contract. No new dependencies; plain-JS/no-build architecture
and NetBird-only exposure preserved.

## Accomplishments

- **Backend (`main.py`, commit `efe6559`):** version last-known-good cache +
  widened log tail (50→400) so version survives after the one-shot startup line
  rotates out; single bounded `asyncio.gather` for the three upstream probes
  (kills the ~15-21s serial hang); `players_known` computed from the real
  `{"players":[...]}` shape (also fixes a pre-existing player_count-always-0
  bug); `/api/system` degrades to a partial `200 {degraded:true}` instead of a
  bare 500.
- **Frontend (`index.html`, commit `35d38cf`):** state-aware honest rendering —
  no misleading `0`/blanks, explicit starting/empty states, actionable error
  banner, guards on `players_known`, reads top-level `data.version`.

## Verification (Task 3 — live, blocking human-verify: APPROVED)

Deployed the two patched files to booted VM **nb14 (192.168.1.248)** via
`pscp` → `docker cp` into `ppsa-webui` → `docker restart` (healthy). Checks
driven over SSH against `localhost:8080` inside the VM (LAN `:8080` is
firewall-blocked by the `WG_FRIENDS` chain by design), plus a browser render
confirm through an SSH tunnel with Playwright.

| Check | Result |
|-------|--------|
| DASH-01 version durability | PASS — `version:"v1.0.1.100619"` while running AND with palworld stopped (cache holds); browser Version card renders it |
| DASH-02 fresh-boot state | PASS — `server_state` running→stopped→starting across stop/start |
| DASH-03 players shape + empty states | PASS — `players_known` true on healthy `{players:[]}` object, false when down/starting; browser "0" + "No players online" |
| DASH-04 graceful degrade / no hang | PASS — palworld down → `/api/dashboard` http=200 in **0.089s** (baseline ~21s http=000); `/api/system` 200 not 500 |
| DASH-05 actionable errors | PASS — structured error strings, backend never 500s, no silent fail (only cosmetic favicon 404) |

Not exercised: a real connected-player numeric count (no Palworld client
available) — the shape/known logic is proven structurally + via empty state.

## Artifacts this phase produces

- Backend: module-level version cache var, `players_known` response key,
  `server_state` response key, top-level `version` response key, bounded
  `asyncio.gather` in `dashboard()`, `degraded` key in `/api/system`.
- Frontend: `players_known`-guarded player rendering, `data.version` read,
  state-aware banner/empty-state rendering in `refreshDashboard()`.

## Follow-ups

- Phase 5 (visual redesign) will restyle these states; keep the state signals.
- Cosmetic: add a favicon to silence the 404 (Phase 5 polish).
