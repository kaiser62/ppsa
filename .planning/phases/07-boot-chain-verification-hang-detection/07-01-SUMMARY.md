---
phase: 07-boot-chain-verification-hang-detection
plan: 01
subsystem: first-boot-orchestration
tags: [bash, install.sh, heartbeat, hang-detection, first-boot, e2e-testing]

# Dependency graph
requires: []
provides:
  - "mark_step_activity() helper in scripts/install.sh — writes a world-readable Unix-timestamp heartbeat to /run/ppsa-install.activity"
  - "Heartbeat call sites wired into Step 3 (Deploying Docker stack): pre-pull, pull-retry-loop success/failure branches, stack-up-loop success/failure branches"
  - "Contract for Plan 07-02: /run/ppsa-install.activity — single Unix epoch integer, chmod 644, absent-until-Step-3, no-more-updates-after-Step-3-completes"
affects: ["07-02"]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "Additive heartbeat sits alongside the existing mark_step() step-counter helper, same best-effort (2>/dev/null || true) error style so a /run write failure under set -eu can never abort first-boot"
    - "Heartbeat calls scoped strictly to Step 3 (the only documented 10-20+ minute operation) — not scattered across all 9 steps"

key-files:
  created: []
  modified:
    - "scripts/install.sh"

key-decisions:
  - "Followed the plan's exact call-site list (5 sites: 1 pre-pull + 2 pull-retry-loop branches + 2 stack-up-loop branches) rather than the research doc's line-by-line 'after every docker compose pull output line' variant — the plan's version is coarser-grained but matches the acceptance criteria (grep -c >= 5) and avoids piping docker compose output through a while-read loop that would change existing control flow/output buffering"
  - "mark_step_activity() defined directly beneath mark_step(), before TOTAL_STEPS=9, preserving the existing helper's position and comment style"

requirements-completed: [BOOT-02]

coverage:
  - id: D1
    description: "mark_step_activity() helper exists, writes a world-readable heartbeat timestamp to /run/ppsa-install.activity with best-effort (non-fatal) error handling"
    requirement: "BOOT-02"
    verification:
      - kind: automated
        ref: "grep -c mark_step_activity scripts/install.sh -> 6 (>= 5 required); grep -c 'chmod 644' scripts/install.sh -> 2; bash -n scripts/install.sh -> exit 0"
        status: pass
    human_judgment: false
  - id: D2
    description: "Heartbeat is called repeatedly during Step 3's Docker pull/up operations without altering existing control flow, retry counts, or error-handling semantics"
    requirement: "BOOT-02"
    verification:
      - kind: automated
        ref: "git diff shows 5 new call sites purely additive (no existing lines removed/reordered) inside pull_with_retry(), the pre-pull call, and both branches of the stack-up for-loop"
        status: pass
    human_judgment: false
  - id: D3
    description: "Existing mark_step()/TOTAL_STEPS/STEP_NAMES/PROGRESS_FILE step-counter contract (used by ppsa-firstboot.sh's tty1 display) is completely unmodified"
    requirement: "BOOT-02"
    verification:
      - kind: automated
        ref: "grep -c '^mark_step()' scripts/install.sh -> 1 (unchanged); grep -c 'TOTAL_STEPS=9' scripts/install.sh -> 1 (unchanged); no diff hunks touch mark_step(), STEP_NAMES, or PROGRESS_FILE"
        status: pass
    human_judgment: false
  - id: D4
    description: "Manual verification of the heartbeat actually updating during a real first-boot run in VirtualBox, readable by the unprivileged ppsa SSH user without sudo"
    requirement: "BOOT-02"
    verification:
      - kind: manual_procedural
        ref: "Deferred to Plan 07-02 per the plan's own verification section: 'Manual (requires a real first-boot run in VirtualBox): SSH in during Step 3 and confirm cat /run/ppsa-install.activity returns a recent Unix timestamp as the unprivileged ppsa user' — this plan only adds the guest-side code, the E2E harness that will exercise it end-to-end lands in 07-02"
        status: deferred
    human_judgment: true

duration: 8min
completed: 2026-07-20
status: complete
---

# Phase 07 Plan 01: Boot-Chain Heartbeat (Guest-Side BOOT-02) Summary

**Additive `mark_step_activity()` heartbeat helper in `scripts/install.sh`, writing a world-readable Unix-timestamp to `/run/ppsa-install.activity` at 5 call sites inside Step 3's Docker pull/up loops, giving Plan 07-02's SSH poller a real signal to distinguish a slow install from a genuine hang.**

## Performance

- **Duration:** 8 min
- **Started:** 2026-07-20T00:00:00Z (approx, single-task plan)
- **Completed:** 2026-07-20
- **Tasks:** 1
- **Files modified:** 1

## Accomplishments
- Added `mark_step_activity()` immediately beneath the existing `mark_step()` helper, matching its comment style and best-effort (`2>/dev/null || true`) error handling on both the timestamp write and the `chmod 644`, so a `/run` write failure can never abort first-boot under `set -eu`
- Wired the heartbeat into exactly 5 call sites inside Step 3 ("Deploying Docker stack"), the only step documented as taking 10-20+ minutes:
  1. Immediately before `pull_with_retry` is invoked
  2. Inside `pull_with_retry()`'s retry loop, on the success path (`return 0`)
  3. Inside `pull_with_retry()`'s retry loop, on the failure/retry path (after the "Pull attempt failed" log line)
  4. Inside the two-attempt stack-up loop, on the `up -d --build` success branch
  5. Inside the two-attempt stack-up loop, on the `up -d --build` failure (`else`) branch
- Left every other step (1, 2, 5-9) untouched — no heartbeat noise added to fast steps
- Verified zero impact on the existing `mark_step()`/`TOTAL_STEPS`/`STEP_NAMES`/`PROGRESS_FILE` step-counter contract that `ppsa-firstboot.sh`'s tty1 progress display depends on

## Task Commits

1. **Task 1: Add mark_step_activity() heartbeat helper and wire it into Step 3's Docker pull/up loops** - `e4a736c` (feat)

**Plan metadata:** (this commit, docs: complete plan)

## Files Created/Modified
- `scripts/install.sh` - Added `mark_step_activity()` helper (6 lines) + 5 call sites (5 lines) inside Step 3; 14 lines added, 0 removed, 0 changed

## Decisions Made
- Chose the plan's exact 5-call-site wiring over the research doc's alternative "pipe docker compose output through `while read line; do ... mark_step_activity; done`" pattern — the plan's version satisfies the acceptance criteria (`grep -c mark_step_activity >= 5`) without introducing a subshell/pipe that would change how `docker compose pull`/`up -d` output is captured by the existing `exec > "$LOG_FILE" 2>&1` redirection, keeping this task strictly additive
- Placed `mark_step_activity()` directly after `mark_step()`'s closing brace, before `TOTAL_STEPS=9`, exactly as the plan specified, so the two helpers read as a matched pair in the script

## Deviations from Plan

None - plan executed exactly as written. All acceptance criteria verified directly (see Coverage above).

## Issues Encountered

During acceptance-criteria verification, the Bash tool's `grep -c "/run/ppsa-install.activity"` invocation returned 0 despite the literal string being present in the file (confirmed via `grep -c "ppsa-install.activity"` returning 4, and a Node.js regex scan confirming 3 occurrences of the exact `/run/ppsa-install.activity` substring). This was a shell-quoting/escaping quirk in the tool invocation, not a real file defect — `bash -n scripts/install.sh` passed cleanly and the file's raw bytes (checked via `cat -A`) show no hidden characters or line-ending issues. Verified via an alternate method (Node.js string match) to confirm the acceptance criterion is genuinely satisfied.

## User Setup Required

None - this is a guest-side code change only, baked into the next image build. No external service configuration required. The heartbeat file will not appear on any already-built/already-booted appliance until a new image is built from this commit and a first boot (or `install.sh --force` re-run) occurs.

## Next Phase Readiness

- `scripts/install.sh` now exposes `/run/ppsa-install.activity` per the documented contract (single Unix epoch integer, world-readable, present only from Step 3 onward, stops updating but remains present once Step 3 completes).
- Plan 07-02 can now extend `scripts/ppsa-installer-e2e.py`'s `wait_for_install_complete()` (or equivalent) to poll this file over SSH alongside the existing `/opt/ppsa/.installed` marker check, implementing the heartbeat-timeout hang-detection logic sketched in `07-RESEARCH.md` Pattern 3.
- The manual end-to-end verification (SSH into a real first-boot VM during Step 3, confirm `cat /run/ppsa-install.activity` as the unprivileged `ppsa` user) is deferred to Plan 07-02's execution, per this plan's own verification section — no blocker, this is the expected sequencing (guest-side code first, then the harness that exercises it).
- No blockers identified for Plan 07-02.

---
*Phase: 07-boot-chain-verification-hang-detection*
*Completed: 2026-07-20*

## Self-Check: PASSED

- FOUND: scripts/install.sh (modified, verified via git diff)
- FOUND: e4a736c (Task 1 commit, verified via git log)
- FOUND: .planning/phases/07-boot-chain-verification-hang-detection/07-01-SUMMARY.md (this file)
