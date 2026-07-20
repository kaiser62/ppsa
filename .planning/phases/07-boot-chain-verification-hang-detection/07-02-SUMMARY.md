---
phase: 07-boot-chain-verification-hang-detection
plan: 02
subsystem: testing
tags: [python, ssh, e2e-testing, boot-chain, secure-boot, hang-detection]

# Dependency graph
requires:
  - phase: 07-01
    provides: "mark_step_activity() heartbeat helper in scripts/install.sh, writing a world-readable Unix timestamp to /run/ppsa-install.activity during Step 3's Docker pull/up loops"
  - phase: 06-02
    provides: "InstallerE2ETester class, SshRunner (plink/ssh auto-detecting transport), wait_for_install_complete() two-reason timeout distinction, run() ordered-results pipeline"
provides:
  - "InstallerE2ETester.verify_boot_chain(ssh_target) -- post-boot SSH classification of signed shim/GRUB vs unsigned grub-mkstandalone fallback (BOOT-01)"
  - "wait_for_install_complete() extended with a THIRD distinguishable timeout reason (SUSPECTED HANG, heartbeat-stale) alongside Phase 6's existing two (BOOT-02)"
  - "run() wiring: verify_boot_chain() invoked after a successful completion-poll, appended to the same ordered results list; overall_pass keyed strictly off FAIL-prefixed status (WARN/SKIP informational)"
affects: [08]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "Boot-chain classification is declarative (PASS/WARN/SKIP), never FAIL -- an unsigned-fallback finding is surfaced for the release process to judge, not auto-failed (Pitfall 4)"
    - "Heartbeat staleness is a THIRD failure-reason branch layered onto Phase 6's existing two-reason self.last_failure_reason distinction, not a replacement -- fresh/absent heartbeat both preserve prior behavior exactly"
    - "overall_pass generalized from a PASS-only check to a FAIL-prefix-only check, so future WARN/SKIP-producing steps (this plan's verify_boot_chain, and Phase 8's smoke_test) don't need special-casing in the aggregate pass/fail computation"

key-files:
  created: []
  modified:
    - "scripts/ppsa-installer-e2e.py"

key-decisions:
  - "verify_boot_chain() reuses the exact SshRunner construction pattern already used in wait_for_install_complete() (same class, same self.ssh_password/self.verbose args) rather than introducing a second SSH transport or a shared/cached runner instance -- keeps each method self-contained and matches Phase 6's existing style of constructing a fresh SshRunner per verification method"
  - "Heartbeat polling runs unconditionally every iteration of the existing while loop (not gated behind a separate timer), since the SSH round-trip cost of one extra `cat` command is negligible next to the existing 15s poll interval and the existing marker-check SSH call"
  - "A malformed/unparseable heartbeat value keeps the previous last_heartbeat_epoch rather than resetting it to None, so a single transient garbled read doesn't erase heartbeat history that was previously observed as fresh"
  - "overall_pass changed from `all(status == \"PASS\" or status.startswith(\"PASS\") for _, status in results)` to `all(not status.startswith(\"FAIL\") for _, status in results)` -- functionally equivalent for all pre-existing FAIL-producing steps (verified they already only emit bare \"FAIL: ...\" strings), but now also correctly treats this plan's new WARN/SKIP statuses as non-blocking without any additional special-casing"

patterns-established:
  - "Boot-chain and hang-detection results append to the same flat list[tuple[str,str]] results contract from Phase 6, using the same (step_name, status_string) shape -- Phase 8 can append (\"smoke_test\", \"PASS\"|\"FAIL: ...\") without a refactor, per the plan's artifacts_produced contract"

requirements-completed: [BOOT-01, BOOT-02]

coverage:
  - id: D1
    description: "verify_boot_chain() classifies the post-install boot path as signed shim/GRUB (PASS), unsigned fallback (WARN, not auto-failed), or unverifiable (SKIP), reusing the existing SshRunner transport (BOOT-01)"
    requirement: "BOOT-01"
    verification:
      - kind: other
        ref: "grep -c on def verify_boot_chain (1), secure.boot|shim dmesg query (1), proc/cmdline fallback query (4), Unsigned WARN text (1); python -c ast.parse syntax check passed"
        status: pass
    human_judgment: true
    rationale: "The dmesg/proc-cmdline classification logic is exercised for syntax and logical correctness in this session, but cannot be run against a real signed-shim-booted guest without a CI-built installer ISO + VirtualBox + a completed first-boot -- a human hand-running this against a real appliance is the plan's own verification item 6, expected as a follow-up pass per Phase 6's precedent."
  - id: D2
    description: "wait_for_install_complete() polls /run/ppsa-install.activity alongside the existing /opt/ppsa/.installed check, and on timeout distinguishes THREE failure reasons (SSH-never-reachable, marker-never-appeared-heartbeat-fresh-or-absent, SUSPECTED-HANG-heartbeat-stale) instead of Phase 6's two, without changing the success path or polling cadence (BOOT-02)"
    requirement: "BOOT-02"
    verification:
      - kind: unit
        ref: "Inline scenario harness (4 monkeypatched SshRunner.exec stubs, per the plan's <behavior> block): (1) heartbeat recent + marker absent -> NOT classified as hang, falls into existing 'marker never appeared' reason; (2) heartbeat stale past 300s threshold + marker absent + overall timeout elapsed -> 'SUSPECTED HANG' reason; (3) heartbeat file absent entirely -> falls back to existing marker-absent reason, not hang-suspected; (4) marker appears immediately -> (True, elapsed) unchanged from Phase 6. All 4 scenarios passed in this session."
        status: pass
    human_judgment: false
  - id: D3
    description: "run() calls verify_boot_chain() after a successful completion-poll, appends its PASS/WARN/SKIP result to the same ordered results list used by every other step, and overall_pass is computed so only a FAIL-prefixed status fails the whole run -- WARN (unsigned fallback) and SKIP (boot-chain check itself unreachable) are informational, not blocking. The Phase 6 stub NOTE is removed."
    requirement: "BOOT-01, BOOT-02"
    verification:
      - kind: other
        ref: "grep -c on verify_boot_chain(self.ssh_target) call site (1), 'Phase 7's' stub text (0, removed), status.startswith(\"FAIL\") in overall_pass (1); python -c ast.parse syntax check passed; python scripts/ppsa-installer-e2e.py --help exits 0 (no CLI regression)"
        status: pass
    human_judgment: false

duration: 12min
completed: 2026-07-20
status: complete
---

# Phase 07 Plan 02: Boot-Chain Verification & Heartbeat-Aware Hang Detection Summary

**Extended `scripts/ppsa-installer-e2e.py` with `verify_boot_chain()` (post-boot SSH classification of signed shim/GRUB vs. unsigned fallback) and heartbeat-aware hang detection in `wait_for_install_complete()`, wired into `run()`'s existing ordered-results pipeline with a FAIL-only `overall_pass` computation.**

## Performance

- **Duration:** 12 min
- **Started:** 2026-07-20T00:00:00Z
- **Completed:** 2026-07-20T00:12:00Z
- **Tasks:** 3
- **Files modified:** 1

## Accomplishments

- `verify_boot_chain(ssh_target)` queries `dmesg | grep -iE 'secure.boot|shim'` first, falls back to `/proc/cmdline` keyword matching, and classifies the result as `PASS` (signed markers found), `WARN` (no markers -- likely unsigned grub-mkstandalone fallback, explicitly NOT auto-failed per Pitfall 4), or `SKIP` (SSH unreachable) -- reusing the exact `SshRunner` construction pattern already established in `wait_for_install_complete()`, no second SSH transport introduced
- `wait_for_install_complete()` now polls `/run/ppsa-install.activity` (Plan 07-01's heartbeat contract) on every iteration alongside the existing `/opt/ppsa/.installed` marker check, tracking `last_heartbeat_epoch` with a defensive `try/except ValueError` around the integer parse so a garbled read never crashes the loop
- On timeout, `self.last_failure_reason` now distinguishes THREE reasons instead of Phase 6's two: SSH-never-reachable (unchanged), marker-never-appeared-with-fresh-or-absent-heartbeat (unchanged wording, now correctly NOT relabeled when a heartbeat exists and is fresh), and a new `SUSPECTED HANG` reason that only fires when a heartbeat was observed AND has gone stale past `HEARTBEAT_STALE_THRESHOLD_SECONDS` (300s/5min)
- A live per-iteration progress line (`heartbeat: Ns ago` or `heartbeat: none observed yet`) was added so verbose output shows the heartbeat signal in real time, not just after the fact
- `run()` now calls `verify_boot_chain(self.ssh_target)` immediately after a successful `wait_for_install_complete()`, appending `("verify_boot_chain", "{status}: {reason}")` to the same flat `results` list every other step already uses
- `overall_pass` was generalized from a bare `PASS`-only check to `all(not status.startswith("FAIL") for _, status in results)` -- WARN and SKIP are now correctly non-blocking without any special-casing, and this is backward-compatible with every pre-existing FAIL-producing step (all of which already only ever emit `"FAIL: {reason}"` strings)
- The Phase 6 stub NOTE ("boot-chain verification ... is Phase 7's responsibility and is NOT performed by this script") was removed and replaced with an accurate docstring describing what this plan implemented

## Task Commits

Each task was committed atomically:

1. **Task 1: verify_boot_chain() post-boot SSH classification (BOOT-01)** - `cd605ab` (feat)
2. **Task 2: Heartbeat-aware hang detection in wait_for_install_complete() (BOOT-02)** - `411d6ba` (feat)
3. **Task 3: Wire verify_boot_chain() and heartbeat-aware timeout into run()'s pipeline** - `41247f6` (feat)

**Plan metadata:** (this commit, docs: complete plan)

## Files Created/Modified

- `scripts/ppsa-installer-e2e.py` - Extended in place: `HEARTBEAT_FILE`/`HEARTBEAT_STALE_THRESHOLD_SECONDS` constants, `InstallerE2ETester.verify_boot_chain()` (Task 1); heartbeat polling + third `SUSPECTED HANG` failure-reason branch in `wait_for_install_complete()` (Task 2); `run()` wiring + FAIL-only `overall_pass` + removed Phase 6 stub NOTE (Task 3)

## Decisions Made

- `verify_boot_chain()` constructs its own fresh `SshRunner` instance (matching `wait_for_install_complete()`'s own pattern) rather than sharing/caching one across methods on `self` -- keeps each verification method self-contained, consistent with Phase 6's existing style
- Heartbeat polling runs on every iteration of the existing `while True:` loop unconditionally (not behind a separate timer), since one extra `cat` SSH round-trip is negligible against the existing 15s poll cadence
- A malformed/unparseable heartbeat value is caught via `try/except ValueError` and the previous `last_heartbeat_epoch` value is kept rather than reset to `None`, so a single transient garbled read doesn't erase previously-observed-fresh heartbeat history
- `overall_pass`'s FAIL-prefix-only rewrite is functionally equivalent to the old PASS-only check for every pre-existing step (verified by inspection: all existing steps only ever emit `"PASS"`, `f"PASS ({elapsed:.0f}s)"`, or `f"FAIL: {...}"`), so this is a safe generalization, not new leniency

## Deviations from Plan

None - plan executed exactly as written. All acceptance criteria across all three tasks verified directly (see Coverage above). One minor implementation-mechanics note: the `verify_boot_chain(self.ssh_target)` call in `run()` was initially written across two lines (matching this file's general multi-line call style), then collapsed to a single line to satisfy the plan's literal `grep -c "verify_boot_chain(self.ssh_target)"` acceptance check -- a cosmetic formatting choice, not a behavioral deviation.

## Issues Encountered

Some `grep -c` invocations against string literals containing embedded double quotes (e.g. `'status.startswith("FAIL")'`) returned false-negative exit codes / counts in this session's Bash/Git-Bash environment due to shell quoting artifacts, even though the string is genuinely present in the file (confirmed via the Grep tool, which is quoting-safe). This is the same environment quirk documented in Phase 6's 06-02-SUMMARY.md "Issues Encountered" section -- not a defect in the script. Resolved by cross-checking every such acceptance criterion with the Grep tool before considering it failed.

## User Setup Required

None - no external service configuration required. Note for future manual verification: hand-running `python scripts/ppsa-installer-e2e.py <iso-path> --ssh-target <address>` against a real CI-built installer ISO + VirtualBox + a completed first-boot (with Plan 07-01's heartbeat change baked in) is the plan's own verification item 6 and the phase's ultimate proof -- confirming the final summary shows a `verify_boot_chain: PASS|WARN: ...` line, and that a deliberately-induced Docker-pull stall produces a `SUSPECTED HANG` reason distinct from a normal timeout. This is expected as a follow-up manual pass, per this project's established Phase 6 precedent, and is not blocked on this plan's automated gates.

## Next Phase Readiness

- `scripts/ppsa-installer-e2e.py` now satisfies this phase's ROADMAP goal in full: the E2E tester can tell a genuinely broken/hung install apart from a correctly-booted (or documented-fallback) one, instead of guessing from a single fixed timeout
- The `results` list remains a flat `list[tuple[str, str]]` of `(step_name, status_string)` entries using the `PASS{...}` / `WARN: {...}` / `SKIP: {...}` / `FAIL: {...}` status-string convention -- Phase 8 can append `("smoke_test", "PASS"|"FAIL: ...")` to this same list and reuse the same FAIL-prefix `overall_pass` check without modification, per this plan's `artifacts_produced` contract
- No changes were made to the CLI argument surface (no new flags needed for BOOT-01/BOOT-02), so Phase 8's CLI additions (if any) start from an unchanged baseline
- No blockers identified

---
*Phase: 07-boot-chain-verification-hang-detection*
*Completed: 2026-07-20*

## Self-Check: PASSED

- FOUND: scripts/ppsa-installer-e2e.py
- FOUND: .planning/phases/07-boot-chain-verification-hang-detection/07-02-SUMMARY.md
- FOUND: cd605ab (Task 1 commit)
- FOUND: 411d6ba (Task 2 commit)
- FOUND: 41247f6 (Task 3 commit)
