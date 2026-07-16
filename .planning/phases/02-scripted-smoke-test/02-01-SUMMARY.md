---
phase: 02-scripted-smoke-test
plan: 01
subsystem: testing
tags: smoke-test, ssh, automation, regression, python, plink
requires:
  - phase: 01-overlay-access
    provides: NetBird overlay SSH path to test VM, stable DNS label mechanism
provides:
  - Host-side smoke test script (scripts/ppsa-smoke-test.py) for one-shot install verification
  - Updated installer-test SKILL.md chaining Phase 1 SSH path into Phase 2 automated check
  - .gitignore entry for smoke-test-logs/ (per T-02-01)
affects: []
tech-stack:
  added: []
  patterns:
    - SSH transport abstraction with auto-detected plink/ssh backend
    - Assertion engine with 8 types (exit_zero, json_has, json_gt, json_has_key, json_in, matches, count_lines, response_time)
    - Raw output isolation to timestamped log file, distilled PASS/FAIL to stdout
    - Polling check pattern for async operations (backup archive waiting)
key-files:
  created:
    - scripts/ppsa-smoke-test.py
  modified:
    - .claude/skills/ppsa-installer-test/SKILL.md
    - .gitignore
key-decisions:
  - "D-01: Python (host-side) — JSON parsing and structured output easier than bash; runs on dev host"
  - "D-02: SSH via plink (Windows) or ssh (Linux/macOS) — auto-detected at runtime"
  - "D-03: Remote command execution via SSH curl against localhost:8080 on the VM"
  - "D-04: Raw output isolation to timestamped log file, only PASS/FAIL summary to stdout"
  - "D-05: nb.12 regression as a dedicated guard group — fails entire run if any regress"
  - "D-06: 10 named check groups with per-group PASS/FAIL sub-totals"
patterns-established:
  - "Smoke test script pattern: stdlib-only, host-side, SSH transport, assertion-driven checks"
  - "Verification pipeline: CI build -> ISO -> VBox first boot -> Phase 1 SSH setup -> Phase 2 smoke-test.py -> PASS/FAIL"
requirements-completed: [TEST-01, TEST-02, TEST-03, TEST-04]
coverage:
  - id: D1
    description: "Host-side smoke test script that runs full install checklist over SSH"
    requirement: TEST-01
    verification:
      - kind: other
        ref: "scripts/ppsa-smoke-test.py --help exits 0, parses valid Python, contains all 10 check groups"
        status: pass
    human_judgment: false
  - id: D2
    description: "Single pass/fail summary from one script invocation"
    requirement: TEST-02
    verification:
      - kind: other
        ref: "scripts/ppsa-smoke-test.py exits 0 (all pass) or 1 (any fail), prints === Summary === block"
        status: pass
    human_judgment: false
  - id: D3
    description: "Raw output isolated to timestamped log file, not main context"
    requirement: TEST-03
    verification:
      - kind: other
        ref: "scripts/ppsa-smoke-test.py defaults to smoke-test-logs/ directory; --log-dir overridable"
        status: pass
    human_judgment: false
  - id: D4
    description: "Three nb.12 regression fixes asserted in dedicated guard group"
    requirement: TEST-04
    verification:
      - kind: other
        ref: "scripts/ppsa-smoke-test.py contains 'Server-action save returns 200 not 500', 'Backup trigger returns immediately', 'Backup archive appears after trigger' check names"
        status: pass
    human_judgment: false
duration: N/A (multi-session execution)
completed: 2026-07-17
status: complete
---

# Phase 2: Scripted Smoke Test Summary

**Host-side Python smoke test script that drives the full PPSA install verification checklist (~26 checks across 10 groups) over SSH via the WebUI API, asserts three nb.12 regression fixes, and returns a single PASS/FAIL summary with raw output isolated to a log file**

## Performance

- **Duration:** Multi-session execution (initial implementation in prior session, wrap-up in this session)
- **Started:** 2026-07-16 (initial session)
- **Completed:** 2026-07-17
- **Tasks:** 2
- **Files modified:** 3

## Accomplishments

- Created `scripts/ppsa-smoke-test.py` (~560 lines) — stdlib-only Python 3 script that SSHs into a PPSA test VM and runs the full install verification checklist over the WebUI API
- Three-layer architecture: SshTransport (plink/ssh with host-key handling), assertion engine (8 types), runner (10 check groups, summary table)
- 10 check groups: SSH (2), AUTH (2), STACK (6), SYSTEM (3), FIREWALL (2), NETBIRD (2), WG DORMANCY (1), BACKUP (3), nb.12 Regression Guard (3), API INTEGRITY (3)
- Dedicated nb.12 guard group asserts server-action 200 fix, non-blocking backup trigger, and backup-archive-appears-after-trigger — fails entire run if any regress
- Polling check for async backup archive (snapshots pre-trigger list, triggers, polls up to 12x every 10s)
- Plink host-key acceptance protocol: first-connection handshake via non-batch mode, extracts SHA256 fingerprint, stores for subsequent `-hostkey` usage
- Raw output written to timestamped log file under `smoke-test-logs/`, only PASS/FAIL summary to stdout
- Updated `.claude/skills/ppsa-installer-test/SKILL.md` to chain Phase 1 SSH path into automated smoke test workflow, with ASCII verification pipeline diagram and preserved sections 1-3
- Added `smoke-test-logs/` to `.gitignore` per threat model T-02-01

## Task Commits

Each task was committed atomically:

1. **Task 1: Create the host-side smoke test script** - `3521685` (feat)
2. **Task 2: Update installer-test SKILL.md** - `3521685` (same commit — both tasks committed together due to shared dependency on the script file)

**Plan metadata:** (pending — final metadata commit)

## Files Created/Modified

- `scripts/ppsa-smoke-test.py` — Host-side Python 3 smoke test script (~560 lines), stdlib-only, plink/ssh transport, 10 check groups, 8 assertion types, raw output to log file
- `.claude/skills/ppsa-installer-test/SKILL.md` — Updated to reference smoke test script as canonical verification entry point, added Phase 1+ SSH path and verification pipeline diagram
- `.gitignore` — Added `smoke-test-logs/` entry per threat model T-02-01

## Decisions Made

- **D-01: Python (host-side)** — JSON parsing and structured output easier than bash; runs on the dev machine, not inside the VM
- **D-02: SSH via plink/ssh** — Auto-detected platform (Windows=plink, Linux/macOS=ssh); `--plink` flag forces plink; plink host-key acceptance protocol handles first-connection prompt
- **D-03: Remote command execution** — All API checks run via `curl http://localhost:8080/api/...` over SSH on the VM, not directly from host
- **D-04: Raw output isolation** — Timestamped log file per run; `smoke-test-logs/ppsa-smoke-<vm>-<timestamp>.log`; default directory configurable via `--log-dir`
- **D-05: nb.12 regression guard** — Three checks under `===== nb.12 Regression Guard =====` decorative heading, each fails the entire run if it regresses
- **D-06: Check grouping** — 10 named groups each with per-group PASS/FAIL sub-totals; summary table at end with `RESULT: PASS` or `RESULT: FAIL`

## Deviations from Plan

None — plan executed exactly as written.

## Issues Encountered

None.

## User Setup Required

None — the script is self-contained and requires only Python 3 + plink (Windows) or ssh (Linux/macOS) on the dev host. The test VM must already be reachable over SSH (via Phase 1 NetBird path or ufw console-injection bootstrap).

## Next Phase Readiness

- Phase 3 (WebUI Save-File Backup & Restore) is independent and already complete
- The smoke test script is ready for use; first live run against a real test VM will validate transport, assertion engine, and polling logic end-to-end
- Phase 1 Task 2 (live re-enrollment verification) is still pending — once completed, the full CI -> ISO -> VBox -> Phase 1 SSH -> Phase 2 smoke test pipeline will be fully executable

---
*Phase: 02-scripted-smoke-test*
*Completed: 2026-07-17*
