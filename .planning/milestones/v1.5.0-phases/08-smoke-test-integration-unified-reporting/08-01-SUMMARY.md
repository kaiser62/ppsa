---
phase: 08-smoke-test-integration-unified-reporting
plan: 01
subsystem: testing
tags: [python, subprocess, e2e-testing, smoke-test, reporting]

# Dependency graph
requires:
  - phase: 07-02
    provides: "InstallerE2ETester.run() ordered results list (list[tuple[str, str]]), overall_pass = all(not status.startswith(\"FAIL\") for _, status in results), verify_boot_chain() as the pipeline's prior stage"
provides:
  - "InstallerE2ETester.run_smoke_test(ssh_target) -- subprocess invocation of scripts/ppsa-smoke-test.py, mapping its 0/1/2 exit codes to PASS/FAIL (TEST-01)"
  - "run() wiring: smoke_test stage appended to the results list after verify_boot_chain(), regardless of boot-chain PASS/WARN/SKIP status"
  - "[SUMMARY] one-line output naming the first failing stage on overall FAIL, or confirming full success (TEST-02)"
  - "--skip-smoke-test and --log-file CLI flags"
affects: []

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "Smoke-test integration is a pure subprocess call (never imports SmokeTestRunner), matching the existing run_vboxmanage()/CommandResult wrapper style already used for VBoxManage calls"
    - "Raw subprocess output (stdout+stderr) is written only to a log file, never printed to this script's own stdout/stderr -- console output stays limited to distilled per-step status lines"
    - "This is the final extension of Phase 6/7's flat list[tuple[str,str]] results contract -- no further extension points remain in this milestone"

key-files:
  created: []
  modified:
    - "scripts/ppsa-installer-e2e.py"

key-decisions:
  - "run_smoke_test() reuses this file's own DEFAULT_PASSWORD/SSH_USER constants for the smoke-test subprocess call, since both scripts document the identical ppsa/ppsa first-boot default (confirmed by reading ppsa-smoke-test.py's own DEFAULT_PASSWORD constant) -- no new credential source introduced"
  - "The smoke-test stage is NOT gated on verify_boot_chain()'s own PASS/WARN/SKIP status -- per Phase 7's precedent that WARN/SKIP boot-chain results are informational, not blocking, a box that booted via unsigned fallback may still be fully functional and deserves a smoke test"
  - "The [SUMMARY] one-liner strips the redundant \"FAIL: \" prefix from the per-step status string before printing, so the final line reads naturally (\"smoke_test failed: smoke test reported failures...\") instead of stuttering (\"FAIL: FAIL: ...\")"
  - "A defensive branch handles the theoretically-unreachable case of overall_pass=False with no FAIL-prefixed result present, printing a generic fallback line instead of crashing on a missing match"

patterns-established:
  - "This plan closes out the results-list extension pattern Phase 7 explicitly left open (\"Phase 8 can append (\\\"smoke_test\\\", ...) without a refactor\") -- no further work is anticipated against this exact extension point within the v1.5.0 milestone"

requirements-completed: [TEST-01, TEST-02]

coverage:
  - id: D1
    description: "run_smoke_test() invokes scripts/ppsa-smoke-test.py via subprocess.run() (never imports SmokeTestRunner), reads its exit code, and maps 0/1/2 to PASS/FAIL result tuples, writing raw subprocess output only to self.log_file"
    requirement: "TEST-01"
    verification:
      - kind: other
        ref: "python -c ast.parse syntax check passed; grep -c 'def run_smoke_test' == 1; grep -c 'SMOKE_TEST_SCRIPT' == 6 (constant def + docstring/comment refs + usage); inline Python harness exercising the summarize()-equivalent PASS/FAIL/SKIP mapping logic confirmed correct output for 4 scenarios (full success, smoke-test FAIL, early-stage FAIL, --skip-smoke-test)"
        status: pass
    human_judgment: true
    rationale: "The subprocess invocation itself (real SSH round-trip through ppsa-smoke-test.py against a live, completed-install guest) cannot be exercised without a CI-built installer ISO + VirtualBox + a completed first-boot -- consistent with Phase 6/7's precedent, this is verification item 8's manual follow-up, not a blocking gate for this plan."
  - id: D2
    description: "run() appends (\"smoke_test\", \"PASS: ...\"|\"FAIL: ...\"|\"SKIP: ...\") to the existing ordered results list after verify_boot_chain(), without gating on boot-chain's own status, and without modifying the existing overall_pass computation"
    requirement: "TEST-01, TEST-02"
    verification:
      - kind: other
        ref: "grep -c 'run_smoke_test(self.ssh_target)' == 1 (single call site in run()); overall_pass line byte-identical to Phase 7's version (diff confirms zero changes to that line); python scripts/ppsa-installer-e2e.py --help exits 0 with --skip-smoke-test and --log-file both listed"
        status: pass
    human_judgment: false
  - id: D3
    description: "A [SUMMARY] one-line output is appended after the existing per-step print loop: on overall_pass True, confirms full success; on False, names the first FAIL-prefixed stage by step name with its reason (stripped of the redundant FAIL: prefix), falling back to a generic line if no FAIL-prefixed result is found"
    requirement: "TEST-02"
    verification:
      - kind: other
        ref: "grep -c '\\[SUMMARY\\]' == 3 (confirmed via Grep tool after a Bash-grep quoting discrepancy, same environment quirk documented in 07-02-SUMMARY.md); inline harness exercised all 4 summarize() scenarios and produced correctly-worded one-liners in each case"
        status: pass
    human_judgment: false

duration: 3min
completed: 2026-07-20
status: complete
---

# Phase 08 Plan 01: Smoke-Test Integration & Unified Reporting Summary

**Extended `scripts/ppsa-installer-e2e.py` with a `run_smoke_test()` subprocess wrapper around `scripts/ppsa-smoke-test.py`, wired as a final pipeline stage into `run()`'s existing ordered-results list, plus a `[SUMMARY]` one-line verdict that names the first failing stage without requiring a re-run.**

## Performance

- **Duration:** 3 min
- **Started:** 2026-07-20T16:18:54Z
- **Completed:** 2026-07-20T16:21:14Z
- **Tasks:** 2
- **Files modified:** 1

## Accomplishments

- `SMOKE_TEST_SCRIPT` (fixed sibling path, `Path(__file__).parent / "ppsa-smoke-test.py"`) and `DEFAULT_SMOKE_TEST_LOG_FILE` (`"ppsa-installer-e2e-smoke.log"`, fixed relative path, overwritten each run) constants added alongside the existing HEARTBEAT_* constants
- `InstallerE2ETester.run_smoke_test(ssh_target)` invokes `scripts/ppsa-smoke-test.py` via `subprocess.run([sys.executable, str(SMOKE_TEST_SCRIPT), ssh_target, "--ssh-password", ...], capture_output=True, text=True, timeout=600)` -- mirrors the existing `run_vboxmanage()`/`CommandResult` wrapper style, never imports `SmokeTestRunner`
- `subprocess.TimeoutExpired` and `OSError` (including `FileNotFoundError`) are both caught inside `run_smoke_test()`, mapped to a `FAIL` result tuple, so a broken/hung smoke-test invocation never crashes the whole e2e run
- Raw captured stdout+stderr is written to `self.log_file`, opened in `"w"` mode (overwritten every call, per D-02) with a labeled header -- this method never prints that raw text to the main script's own stdout/stderr
- The smoke test's own documented exit-code contract (0=PASS, 1=FAIL, 2=setup/prerequisite ERROR) is mapped to `("PASS", ...)` / `("FAIL", ...)` / `("FAIL", ...)` result tuples, with a defensive catch-all for any unexpected returncode
- `InstallerE2ETester.__init__()` gained `skip_smoke_test=False` and `log_file=DEFAULT_SMOKE_TEST_LOG_FILE` parameters, stored as `self.skip_smoke_test`/`self.log_file`
- `--skip-smoke-test` (`action="store_true"`) and `--log-file` (`default=DEFAULT_SMOKE_TEST_LOG_FILE`) CLI flags added immediately after `--ssh-password`, both wired into the `InstallerE2ETester(...)` construction call in `main()`
- `run()`'s pipeline now appends a `("smoke_test", "PASS: ..."|"FAIL: ..."|"SKIP: --skip-smoke-test set")` tuple to the existing `results` list immediately after `verify_boot_chain()`, regardless of the boot-chain stage's own PASS/WARN/SKIP status (WARN/SKIP are informational per Phase 7's precedent, not blocking)
- `overall_pass = all(not status.startswith("FAIL") for _, status in results)` was left completely unmodified -- the new smoke-test statuses already fit the existing FAIL-prefix-only contract
- A new `[SUMMARY]` one-line output was added after the existing per-step print loop: on full success, prints `"[SUMMARY] PASS -- install, boot-verify, and smoke-test all succeeded"`; on any FAIL, finds the first FAIL-prefixed result in pipeline order and prints `f"[SUMMARY] FAIL -- {step_name} failed: {reason}"` (with the redundant `"FAIL: "` prefix stripped so the line reads naturally), with a defensive fallback line if no FAIL-prefixed result is somehow found

## Task Commits

Each task was committed atomically:

1. **Task 1: run_smoke_test() subprocess invocation + log-file plumbing + CLI flags** - `a54741a` (feat)
2. **Task 2: Wire run_smoke_test() into run()'s pipeline + one-line summary** - `3b844ed` (feat)

**Plan metadata:** (this commit, docs: complete plan)

## Files Created/Modified

- `scripts/ppsa-installer-e2e.py` - Extended in place: `SMOKE_TEST_SCRIPT`/`DEFAULT_SMOKE_TEST_LOG_FILE` constants, `InstallerE2ETester.run_smoke_test()`, `skip_smoke_test`/`log_file` constructor params, `--skip-smoke-test`/`--log-file` CLI flags (Task 1); `run()` wiring of the smoke-test stage into the results list + `[SUMMARY]` one-liner builder (Task 2)

## Decisions Made

- `run_smoke_test()` reuses this file's own `DEFAULT_PASSWORD`/`SSH_USER` constants for the smoke-test subprocess call rather than introducing a new credential path -- confirmed both scripts document the identical `ppsa`/`ppsa` first-boot default via `ppsa-smoke-test.py`'s own `DEFAULT_PASSWORD` constant
- The smoke-test stage is unconditionally invoked after a successful `wait_for_install_complete()`, independent of `verify_boot_chain()`'s own PASS/WARN/SKIP result -- an unsigned-fallback boot (WARN) does not block the smoke test from running, matching Phase 7's "informational, not blocking" precedent for non-FAIL statuses
- The `[SUMMARY]` line strips the leading `"FAIL: "` substring from the matched status string before interpolating it, avoiding a `"FAIL: FAIL: ..."` stutter in the final human-readable line
- A defensive `else` branch handles the case where `overall_pass` is `False` but no result actually starts with `"FAIL"` (should not happen given the FAIL-prefix contract, but avoided a possible `None`-unpacking crash by checking explicitly rather than assuming a match always exists)

## Deviations from Plan

None - plan executed exactly as written. All acceptance criteria across both tasks verified directly (see Coverage above).

## Issues Encountered

The same Bash/Git-Bash grep-quoting artifact documented in `07-02-SUMMARY.md`'s "Issues Encountered" section recurred here: `grep -c "\[SUMMARY\]" scripts/ppsa-installer-e2e.py` from the Bash tool returned an inflated/incorrect count (298, then 959 via `grep -o | wc -l`) despite the string genuinely appearing exactly 3 times in the file. Cross-checked with the Grep tool (which is quoting-safe), confirming 3 occurrences -- matching the plan's own `>= 1` acceptance threshold. Not a defect in the script; an environment quirk in how this session's Bash invokes `grep` with bracket-escaped patterns.

## User Setup Required

None - no external service configuration required. Note for future manual verification: the plan's own verification item 8 (hand-running `python scripts/ppsa-installer-e2e.py <iso-path> --ssh-target <address>` against a real completed install, deliberately inducing a smoke-test failure by stopping the palworld container before the smoke-test stage runs, and confirming the `[SUMMARY]` line names `smoke_test` as the failing stage) requires a CI-built installer ISO + VirtualBox + a completed first-boot, consistent with Phase 6/7/8's established precedent of deferring live-guest verification to a follow-up manual pass. Not blocked on this plan's automated gates.

## Next Phase Readiness

- `scripts/ppsa-installer-e2e.py` now satisfies the v1.5.0 milestone's final ROADMAP goal in full: a single invocation covers install -> boot-verify -> smoke-test, exits 0 only on full success and 1 on any failure, routes all raw subprocess noise (VM console, SSH output, smoke-test details) to a log file instead of the main console, and produces a `[SUMMARY]` one-liner that names the failing stage without requiring a re-run
- `--skip-smoke-test` provides a clean escape hatch for debugging install/boot in isolation, still producing a valid `overall_pass` verdict and one-line summary
- This is the final phase of the v1.5.0 Installer-ISO E2E Tester milestone -- no further extension points are anticipated against this results-list/overall_pass contract within this milestone
- No blockers identified

---
*Phase: 08-smoke-test-integration-unified-reporting*
*Completed: 2026-07-20*

## Self-Check: PASSED

- FOUND: scripts/ppsa-installer-e2e.py
- FOUND: .planning/phases/08-smoke-test-integration-unified-reporting/08-01-SUMMARY.md
- FOUND: a54741a (Task 1 commit)
- FOUND: 3b844ed (Task 2 commit)
