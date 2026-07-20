---
phase: 06-vm-orchestration-scripted-install
plan: 02
subsystem: testing
tags: [virtualbox, vboxmanage, python, ssh, plink, e2e-testing, scancode]

# Dependency graph
requires:
  - phase: 06-01
    provides: "InstallerE2ETester class skeleton, run_vboxmanage()/VBoxManageError/CommandResult, CLI surface, exit code contract (0/1/2)"
provides:
  - "INSTALLER_TUI_SEQUENCE constant + send_scancodes()/drive_installer_tui() -- blind scancode installer TUI automation (VM-02)"
  - "SshRunner class (ported plink/ssh auto-detecting transport) + wait_for_install_complete() -- bounded, distinguishable-timeout install completion polling (VM-03, NET-01)"
  - "InstallerE2ETester.run() -- full single-invocation pipeline (create -> attach -> boot -> TUI -> completion-poll -> summary)"
  - "--ssh-target / --ssh-password CLI flags"
affects: [07, 08]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "Blind scancode keystroke injection via VBoxManage keyboardputscancode, zero screenshot/OCR dependency"
    - "SshRunner ported (not imported) from ppsa-smoke-test.py's SshTransport, so this orchestrator script stays runnable standalone"
    - "Distinguishable timeout reasons (self.last_failure_reason) separating 'SSH never reachable' from 'reachable but marker absent', tracked via a 'last successful contact' timestamp independent of the overall elapsed-time budget"
    - "Pipeline-as-ordered-steps-list with first-failure-stops-remaining-skipped semantics in run(), mirroring STACK.md's InstallerE2ETester.run sketch"

key-files:
  created: []
  modified:
    - "scripts/ppsa-installer-e2e.py"

key-decisions:
  - "Split Task 1 (TUI driving) and Task 2 (completion polling + run()) into two separate atomic commits, since they are independently verifiable via distinct acceptance criteria and touch largely non-overlapping code regions (unlike Plan 01 where both tasks modified the same tightly-coupled main() flow)"
  - "wait_for_install_complete() treats SshRunner.exec()'s exit_code == -1 as the connection-level-failure sentinel (matches SshRunner's own convention: -1 is only ever returned for timeout/FileNotFoundError/OSError, never for a real remote command's own non-zero exit), keeping 'SSH itself failed' cleanly distinguishable from 'SSH succeeded, test -f returned false'"
  - "run() treats a missing --ssh-target as an immediate FAIL step (not a hang or a skip) -- since VM-03's scope is detecting completion via an already-reachable address, not discovering it, omitting the flag is a caller error worth surfacing distinctly rather than silently declaring PASS on lifecycle-only steps"
  - "Boot-chain verification (BOOT-01/BOOT-02) is represented only as a single NOTE print in run()'s output, per the plan's explicit instruction not to implement any signed/unsigned GRUB detection logic in this phase"

patterns-established:
  - "run()'s ordered (step_name, step_fn) tuple list + for/else pipeline construct: successful full iteration (no break) falls into the else clause to run the completion-poll phase; any exception appends a FAIL entry and breaks immediately, skipping remaining steps -- this is the pattern later phases (7, 8) extending run() should preserve"

requirements-completed: [VM-02, VM-03, NET-01]

coverage:
  - id: D1
    description: "drive_installer_tui() sends the exact proven blind-scancode sequence (GRUB Enter, disk-select, 3x uppercase YES+Enter) with the exact proven wallclock timings, zero screenshot/OCR dependency (VM-02)"
    requirement: "VM-02"
    verification:
      - kind: other
        ref: "grep -c on INSTALLER_TUI_SEQUENCE (1), the 3x-uppercase YES scancode string (3), def send_scancodes (1), def drive_installer_tui (1); python -c ast.parse syntax check passed"
        status: pass
    human_judgment: true
    rationale: "The scancode sequence and timings are copied verbatim from a manually-proven recipe (ppsa-installer-test skill) but cannot be exercised against a real VM/ISO in this execution session -- a human running this against a real CI-built installer ISO in VirtualBox is the actual proof, per the plan's own verification section item 5."
  - id: D2
    description: "wait_for_install_complete() polls /opt/ppsa/.installed over SSH, distinguishes 'still installing' from 'done', and never hangs past its bounded timeout, with distinguishable timeout reasons (VM-03, NET-01)"
    requirement: "VM-03"
    verification:
      - kind: unit
        ref: "Inline scenario harness (3 monkeypatched SshRunner stubs): never-reachable -> last_failure_reason contains 'never became reachable'; reachable-but-marker-absent -> last_failure_reason contains 'never appeared'; marker present -> returns (True, elapsed). All 3 scenarios passed in this session."
        status: pass
    human_judgment: false
  - id: D3
    description: "InstallerE2ETester.run() ties the full pipeline into one invocation producing exit code 0/1/2 and a one-line stdout summary; main() calls run() instead of the Task-1-era stub sequence"
    requirement: "NET-01"
    verification:
      - kind: other
        ref: "grep -c on def run(self) shows real orchestration (not NotImplementedError stub); TODO(Plan 06-02) marker count is 0; python scripts/ppsa-installer-e2e.py --help exits 0 with --ssh-target/--ssh-password present; python scripts/ppsa-installer-e2e.py /nonexistent.iso exits 2"
        status: pass
    human_judgment: false

duration: 4min
completed: 2026-07-20
status: complete
---

# Phase 06 Plan 02: Installer TUI Driving + Completion Polling Summary

**Completed `scripts/ppsa-installer-e2e.py` with blind scancode installer-TUI automation, SSH-polled `/opt/ppsa/.installed` completion detection with distinguishable timeout reasons, and a single-invocation `run()` pipeline producing one PASS/FAIL/ERROR exit code.**

## Performance

- **Duration:** 4 min
- **Started:** 2026-07-20T11:03:00Z
- **Completed:** 2026-07-20T11:07:00Z
- **Tasks:** 2
- **Files modified:** 1

## Accomplishments
- `INSTALLER_TUI_SEQUENCE` reproduces the exact proven GRUB-Enter -> disk-select -> 3x uppercase-YES-confirmation scancode bytes and wallclock waits from the `ppsa-installer-test` skill, with an explanatory comment on why the YES bytes must stay uppercase
- `send_scancodes()`/`drive_installer_tui()` drive the TUI blind (zero screenshot/OCR), logging a timestamped line per step for debuggability
- `SshRunner` ports the plink/ssh auto-detecting transport pattern from `ppsa-smoke-test.py`'s `SshTransport` into this file directly (no cross-script import, keeping the orchestrator standalone-runnable)
- `wait_for_install_complete()` polls `/opt/ppsa/.installed` every 15s under a bounded overall timeout, distinguishing "SSH never reachable" from "reachable but installer not done yet" via `self.last_failure_reason`, verified against three scripted scenarios (never-reachable, reachable-no-marker, installed)
- `InstallerE2ETester.run()` replaces Plan 01's `NotImplementedError` stub, orchestrating `create_vm -> attach_iso -> boot_vm -> drive_installer_tui -> wait_for_install_complete` as one ordered pipeline that stops on first failure and prints a one-line PASS/FAIL summary
- `main()` now calls `tester.run()` and exits 0/1 based on the overall result, with a `--ssh-target`/`--ssh-password` CLI surface added; boot-chain verification (BOOT-01/BOOT-02) is explicitly noted as Phase 7's responsibility, not implemented here

## Task Commits

Each task was committed atomically:

1. **Task 1: Blind scancode TUI driving (VM-02)** - `3801956` (feat)
2. **Task 2: SSH-polled install-completion detection + run() pipeline (VM-03, NET-01)** - `edf9054` (feat)

**Plan metadata:** (this commit, docs: complete plan)

## Files Created/Modified
- `scripts/ppsa-installer-e2e.py` - Extended in place: `INSTALLER_TUI_SEQUENCE`, `send_scancodes()`, `drive_installer_tui()` (Task 1); `SshRunner`, `wait_for_install_complete()`, `InstallerE2ETester.run()`, updated `main()`/CLI (Task 2)

## Decisions Made
- Task 1 and Task 2 were committed separately (unlike Plan 01's combined commit) since each task's acceptance criteria are independently checkable and the code regions they touch barely overlap
- `wait_for_install_complete()` uses `SshRunner.exec()`'s `exit_code == -1` as the sole connection-failure sentinel, matching `SshRunner`'s own internal convention, so "SSH itself failed" vs. "SSH succeeded, file absent" stays unambiguous
- A missing `--ssh-target` at `run()` time is surfaced as an explicit FAIL step rather than silently skipped, since VM-03's scope assumes an already-reachable address is supplied
- Boot-chain verification is represented as a single log line, per the plan's explicit instruction against scope creep into Phase 7

## Deviations from Plan

None - plan executed exactly as written. All acceptance criteria across both tasks verified directly (see Coverage above).

## Issues Encountered

During acceptance-criteria verification, a Bash/Git-Bash `grep` invocation for the literal string `/opt/ppsa/.installed` returned a false-negative (exit 1, count 0) due to a shell quoting/path-resolution artifact in that environment, even though the string is present 4 times in the file (confirmed via the Grep tool and via `grep -n "opt/ppsa"`). This was a test-harness quirk, not a defect in the script -- resolved by cross-checking with the Grep tool before proceeding.

## User Setup Required

None - no external service configuration required. Note for future manual verification: hand-running `python scripts/ppsa-installer-e2e.py <iso-path> --ssh-target <address>` against a real CI-built installer ISO + VirtualBox + an already-SSH-reachable test VM is the plan's ultimate proof (per the plan's `<verification>` item 5) and is expected as a follow-up pass, not blocked on this plan's automated gates.

## Next Phase Readiness

- `scripts/ppsa-installer-e2e.py` is now feature-complete per this phase's ROADMAP goal: a single invocation can unattended-install a CI-built PPSA installer ISO into a disposable VirtualBox VM end to end, producing one PASS/FAIL/ERROR exit code
- Boot-chain verification (BOOT-01/BOOT-02) is explicitly deferred to Phase 7 and can extend `run()`'s step list using the same ordered-tuple pattern established here
- Phase 8 (TEST-01/TEST-02) can chain `scripts/ppsa-smoke-test.py` after a successful `run()`, reusing the same `--ssh-target` address once install completion is confirmed
- No blockers identified

---
*Phase: 06-vm-orchestration-scripted-install*
*Completed: 2026-07-20*
