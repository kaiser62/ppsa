# Phase 8: Smoke-Test Integration & Unified Reporting - Context

**Gathered:** 2026-07-20
**Status:** Ready for planning

<domain>
## Phase Boundary

This phase chains the existing `scripts/ppsa-smoke-test.py` onto the end of
`scripts/ppsa-installer-e2e.py`'s pipeline (install → boot-verify → smoke-test),
folds its pass/fail into one overall verdict, and produces a single one-line
human-readable summary — while routing all raw noise (VM console, SSH output,
smoke-test details) to a log file instead of the main context. It does not
reimplement any smoke-test check, and does not touch `scripts/ppsa-smoke-test.py`
itself.

</domain>

<decisions>
## Implementation Decisions

### Invocation mechanism
- **D-01:** Invoke `scripts/ppsa-smoke-test.py` via `subprocess.run()` (e.g.
  `[sys.executable, "scripts/ppsa-smoke-test.py", "--target", ip, ...]`),
  capturing stdout/stderr and reading its exit code. Do NOT import
  `SmokeTestRunner` directly — subprocess isolation avoids coupling
  `ppsa-installer-e2e.py` to the smoke test's internal class API, matches
  the existing subprocess-wrapper pattern already used for VBoxManage
  (`run_vboxmanage()`), and keeps the smoke test independently runnable/testable
  without the e2e script's presence.

### Raw-output log location
- **D-02:** Write all raw install/boot/smoke-test output to a **fixed path,
  overwritten each run** (not timestamped-per-run). Exact path is
  implementer's choice within existing project conventions (e.g. alongside
  other transient script output) — no retention/rotation policy needed since
  each invocation is a fresh, disposable manual test run, not a monitored
  history.

### CLI surface changes
- **D-03:** Add exactly two new flags to `ppsa-installer-e2e.py`:
  - `--skip-smoke-test` — escape hatch to stop after boot-verify, for
    debugging install/boot without waiting on the smoke test.
  - `--log-file <path>` — override the default fixed log path from D-02.
  Do NOT add a flag for the smoke-test script's own path — it's a sibling
  script in this same repo at a fixed location (`scripts/ppsa-smoke-test.py`),
  not a variable/configurable location.

### One-line summary format
- **Claude's discretion.** Not discussed — user deferred this to
  implementation. Constraints from ROADMAP.md success criteria still apply:
  exit 0 on full success / 1 on any failure, and the summary must make clear
  which stage failed (install, boot-verify, or smoke-test) on a FAIL verdict
  without needing a re-run to diagnose. Follow the existing pattern already
  established in Phase 7's `run()` results list (`list[tuple[str, str]]`,
  `overall_pass = all(not status.startswith("FAIL") ...)`) — append a
  `("smoke_test", "PASS"|"FAIL: ...")` tuple to that same list rather than
  introducing a new result shape.

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### This phase's target files
- `scripts/ppsa-installer-e2e.py` — the file this phase extends (Phase 6/7
  deliverable; `run()` already orchestrates install → boot-verify and ends
  with a flat results list + `overall_pass`; this phase appends a third stage)
- `scripts/ppsa-smoke-test.py` — the existing, already-proven smoke test this
  phase invokes as a subprocess; read its `parse_args()`/`main()` (lines
  1061-1131) for its CLI contract (flags, exit codes 0/1/2) before writing
  the subprocess invocation

### Prior phase artifacts (for continuity)
- `.planning/phases/07-boot-chain-verification-hang-detection/07-02-SUMMARY.md`
  — documents the exact results-list/overall_pass shape this phase must extend
- `.planning/phases/07-boot-chain-verification-hang-detection/07-VERIFICATION.md`
  — confirms Phase 7 left the pipeline explicitly extensible for this phase
- `.planning/REQUIREMENTS.md` — TEST-01, TEST-02 definitions

No external specs/ADRs — requirements fully captured in decisions above.

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- `run_vboxmanage()` in `ppsa-installer-e2e.py` — existing subprocess-wrapper
  pattern (`CommandResult`, error handling) to mirror for the smoke-test
  subprocess call, rather than inventing a new wrapper style.
- `SshRunner` class in `ppsa-installer-e2e.py` — not needed for this phase's
  own logic (smoke-test manages its own SSH transport), but confirms the
  project's existing convention of not re-deriving transport code.

### Established Patterns
- Exit-code contract: 0=PASS, 1=FAIL, 2=prerequisite ERROR — already
  established in `ppsa-installer-e2e.py`; `ppsa-smoke-test.py` uses the same
  0/1/2 contract (confirmed at lines 87/90/177/667/670/1131) — codes map
  directly, no translation needed.
- Results-list shape: `list[tuple[str, str]]` with `overall_pass = all(not
  status.startswith("FAIL") ...)` — established in Phase 7, this phase's
  smoke-test result must fit the same shape.

### Integration Points
- `run()` method's tail end (after `verify_boot_chain()` call) is where the
  smoke-test subprocess call and result-tuple append belong.
- `main()`/`parse_args()` CLI section is where `--skip-smoke-test` and
  `--log-file` get added, following the existing 14-argument argparse style.

</code_context>

<specifics>
## Specific Ideas

No particular UI/UX references — this is a CLI/orchestration phase. The
one-line summary should read naturally as a status line (not JSON), consistent
with the terse style of the rest of the script's existing print output.

</specifics>

<deferred>
## Deferred Ideas

None — discussion stayed within phase scope.

</deferred>

---

*Phase: 8-Smoke-Test Integration & Unified Reporting*
*Context gathered: 2026-07-20*
