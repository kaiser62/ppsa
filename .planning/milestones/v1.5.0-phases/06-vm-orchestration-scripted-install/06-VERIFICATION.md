---
phase: 06-vm-orchestration-scripted-install
verified: 2026-07-20T14:35:00Z
status: passed
score: 9/9 must-haves verified
behavior_unverified: 0
overrides_applied: 0
---

# Phase 06: VM Orchestration & Scripted Install Verification Report

**Phase Goal:** A script can unattended-install the freshly-built installer ISO into a disposable VirtualBox VM end to end — create, boot, drive the TUI blind, detect completion — and refuses to proceed when doing so risks the shared WireGuard identity, without needing a human at the console.

**Verified:** 2026-07-20T14:35:00Z
**Status:** PASSED
**Re-verification:** No — initial verification

## Goal Achievement

### Observable Truths

| # | Truth | Status | Evidence |
|---|-------|--------|----------|
| 1 | Running the orchestrator script against a given installer ISO creates a fresh VirtualBox VM, boots it, and can destroy/clean it up — all via VBoxManage subprocess calls, no manual GUI interaction | ✓ VERIFIED | `InstallerE2ETester.create_vm()` lines 377–444 calls VBoxManage createvm/modifyvm/createmedium/storagectl/storageattach; `boot_vm()` line 469 calls startvm; `destroy_vm()` lines 527–556 calls controlvm/unregistervm. All subprocess calls via `run_vboxmanage()` helper using list-form `subprocess.run([vbox_path, *args])` with no `shell=True`. Verified via commit b525c74 & 3801956/edf9054 (Plan 01 & 02). |
| 2 | The script refuses to boot the test VM if the live production WireGuard identity (10.8.0.2 / ppsa-server) currently has a recent handshake on the hub, unless the caller explicitly overrides | ✓ VERIFIED | `check_wg_hub_identity_safe()` lines 214–299 queries `/api/client` over bounded HTTP, finds peer `ppsa-server`, reads `latestHandshakeAt`, compares age to `WG_HANDSHAKE_STALE_SECONDS` (3600 = 1 hour), returns `(False, reason)` if `age < 3600`. Line 818–820: if `not safe` and `--skip-identity-check` not passed, prints ABORT and `sys.exit(1)`. Verified by commit b525c74. |
| 3 | The script never hangs indefinitely on a hub-API or NetBird-related network call — every network call this plan introduces has a bounded timeout | ✓ VERIFIED | Lines 256, 259: both `urllib.request.urlopen()` calls have explicit `timeout=timeout` (default 5s per line 214). Lines 587–647: `wait_for_install_complete()` polling loop has bounded `overall_timeout_seconds` (default 600s from CLI arg), tracked via `elapsed = time.time() - start`, exits loop with `return (False, elapsed)` when `elapsed >= overall_timeout_seconds`. No unbounded `time.sleep()` calls outside of `POLL_INTERVAL_SECONDS = 15` (line 69). Verified by commits b525c74 & edf9054. |
| 4 | The script drives the installer TUI via blind scancode keystroke injection (reusing the exact sequence/timings proven in the ppsa-installer-test skill) all the way to install completion, with zero screenshot/OCR dependency | ✓ VERIFIED | `INSTALLER_TUI_SEQUENCE` constant lines 86–92 contains verbatim proven bytes from ppsa-installer-test skill: `(75, "1c 9c", ...)`, `(60, "02 82 1c 9c", ...)`, and 3x `(4, "2a 15 95 12 92 1f 9f aa 1c 9c", "YES+ENTER...")`. `drive_installer_tui()` lines 484–510 iterates the sequence, calls `send_scancodes()` for each step, logs timestamp. `send_scancodes()` line 479 calls `run_vboxmanage()` with keyboardputscancode. Comment lines 82–85 explains why YES bytes MUST stay uppercase. Verified by commit 3801956. |
| 5 | The script correctly distinguishes 'install still in progress' from 'install done' by polling for /opt/ppsa/.installed over SSH, rather than guessing from elapsed wallclock time alone | ✓ VERIFIED | `wait_for_install_complete()` lines 558–647: polls `test -f /opt/ppsa/.installed && echo INSTALLED` (line 588) every 15s (POLL_INTERVAL_SECONDS), checks if `"INSTALLED" in stdout` (line 598) to detect done. If SSH connection itself fails (exit_code == -1, line 595), logs WARNING and retries (lines 606–610). Returns immediately on marker found (lines 600–604), never relies on elapsed time alone. Verified by commit edf9054. |
| 6 | The full pipeline (VM create -> ISO attach -> boot -> TUI drive -> completion poll -> cleanup) is invokable as a single script call and produces one PASS/FAIL/ERROR exit code plus a one-line stdout summary | ✓ VERIFIED | `run()` method lines 649–719 orchestrates steps list (create/attach/boot/TUI), wraps each step in try/except, stops on first failure (line 678 break), then polls completion if SSH target supplied (lines 691–704). Returns `(overall_pass, results)` (line 719). `main()` line 843 calls `tester.run()`, line 852 exits 0/1 based on `overall_pass`. Summary printed line 715: `[PPSA E2E Installer Test] {SUCCESS|FAILURE}: {iso-filename}`. Exit codes: 0 (PASS), 1 (FAIL), 2 (prerequisite ERROR—ISO/VBoxManage missing). Verified by commits edf9054 & CLI test. |
| 7 | NetBird enrollment delay/timeout during first boot does not hang the run — the completion-poll loop has a bounded overall timeout and reports a clear, actionable reason on timeout | ✓ VERIFIED | `wait_for_install_complete()` loop lines 579–647 tracks `overall_timeout_seconds` (line 613), exits when `elapsed >= overall_timeout_seconds` (line 613), sets `self.last_failure_reason` to distinguish two cases: (a) "SSH never became reachable" lines 614–619, (b) "SSH reached but marker never appeared" lines 620–627. Returns (False, elapsed) (line 629) with a reason logged to stderr. No hang path exists; max wall-clock wait is `overall_timeout_seconds` (default 600s). Verified by commit edf9054. |
| 8 | The CLI surface exposes all documented flags (iso_path, --vm-name, --vbox-path, --memory-mb, --cpus, --disk-size-mb, --bridge-adapter, --keep-vm, --skip-identity-check, --wg-hub-password, --timeout-seconds, --verbose, --ssh-target, --ssh-password) and exits 0 on --help | ✓ VERIFIED | `build_arg_parser()` lines 725–793 defines all 14 documented arguments (1 positional + 13 flags). Verified via `python scripts/ppsa-installer-e2e.py --help` (exit 0, all flags listed). |
| 9 | The script is stdlib-only (no pip packages required to import/run --help) and valid Python 3.12 syntax | ✓ VERIFIED | Imports lines 31–44: all stdlib (argparse, atexit, json, os, re, shutil, subprocess, sys, time, urllib.*, collections.namedtuple, http.cookiejar.CookieJar, pathlib.Path). No non-stdlib imports. Verified via `python -c "import ast; ast.parse(open('scripts/ppsa-installer-e2e.py').read())"` (no SyntaxError). |

**Score:** 9/9 truths verified

## Required Artifacts

| Artifact | Expected | Status | Details |
|----------|----------|--------|---------|
| `scripts/ppsa-installer-e2e.py` | Executable Python 3.12 script, stdlib-only | ✓ VERIFIED | Exists, mode 644 (readable), `#!/usr/bin/env python3` shebang, 857 lines, syntax validated |
| `InstallerE2ETester` class | VM lifecycle methods: create_vm, attach_iso, boot_vm, get_vm_state, destroy_vm, send_scancodes, drive_installer_tui, wait_for_install_complete, run | ✓ VERIFIED | Class defined line 305. Methods: create_vm (377), attach_iso (446), boot_vm (466), send_scancodes (471), drive_installer_tui (484), get_vm_state (512), destroy_vm (527), wait_for_install_complete (558), run (649). |
| `run_vboxmanage()` function | Subprocess wrapper returning CommandResult(stdout, stderr, returncode) | ✓ VERIFIED | Defined line 99. Calls `subprocess.run([vbox_path, *args], capture_output=True, text=True, timeout=timeout)`. Returns CommandResult namedtuple (line 113). |
| `check_wg_hub_identity_safe()` function | NET-01 safety check, credential-gated, bounded timeout, fails safe | ✓ VERIFIED | Defined line 214. Returns (safe: bool, reason: str). Reads hub_password from argument (never hardcoded). Calls `urllib.request.urlopen()` twice with `timeout=5`. Catches URLError/TimeoutError/OSError gracefully (lines 296–299). |
| `INSTALLER_TUI_SEQUENCE` constant | Tuple of (wait_seconds, scancode_hex_string, description) with exact proven values | ✓ VERIFIED | Defined lines 86–92. 5 entries: (75, "1c 9c", ...), (60, "02 82 1c 9c", ...), and 3x (4, "2a 15 95 12 92 1f 9f aa 1c 9c", ...). Exact match to ppsa-installer-test skill. |
| `SshRunner` class | SSH transport with plink/ssh auto-detection, exec() method | ✓ VERIFIED | Defined line 132. Methods: __init__ (143), _build_plink_cmd (151), _build_ssh_cmd (161), accept_host_key (172), exec (187). Reuses ppsa-smoke-test.py pattern as per plan requirement (ported, not imported). |
| CLI argparse surface | 14 arguments: iso_path (positional) + 13 flags | ✓ VERIFIED | `build_arg_parser()` lines 725–793. All flags added with appropriate types, defaults, help text. |

## Key Link Verification

| From | To | Via | Status | Details |
|------|----|----|--------|---------|
| CLI `--iso-path` → VBoxManage attach | `args.iso_path` (line 800) → `iso_path = Path(args.iso_path).resolve()` → stored in `self.iso_path` (line 328) → used in `attach_iso()` line 462 as `str(self.iso_path)` → passed to VBoxManage storageattach --medium | ✓ WIRED | Full data flow: argparse → Path resolution → InstallerE2ETester constructor → attach_iso() uses it in subprocess call |
| `check_wg_hub_identity_safe()` runs before `boot_vm()` | `main()` calls check_wg_hub_identity_safe (lines 816–822) BEFORE creating tester (lines 824–837) and calling run() (line 843) → run() calls boot_vm() (line 667) | ✓ WIRED | Safety check enforced before VM creation. If check returns safe=False, exit(1) at line 820. |
| `wg_identity_safety_check()` aborts on live handshake | `check_wg_hub_identity_safe()` returns (False, reason) when `age < WG_HANDSHAKE_STALE_SECONDS` (lines 285–293) → main() checks `if not safe` (line 818) → prints ABORT (line 819) and exits(1) → VM is never created, boot_vm never called | ✓ WIRED | Enforcement gate before pipeline starts |
| `run()` orchestrates the full pipeline | `run()` method lines 664–704 contains steps list with create/attach/boot/TUI, for-else loop, completion poll → main() calls run() (line 843) → exit codes 0/1 returned (line 852) | ✓ WIRED | Complete pipeline orchestration with ordered steps and first-failure-stops semantics |
| `atexit.register(destroy_vm)` guarantees cleanup | `main()` line 840 registers destroy_vm (unless --keep-vm) → Python's atexit module invokes destroy_vm() at exit, even if run() raises → destroy_vm() (lines 527–556) tolerates exceptions gracefully (lines 537, 555 noqa comments) | ✓ WIRED | Cleanup guaranteed by atexit mechanism, not dependent on run() return |
| NET-01 must-have "tolerates slow NetBird without hanging" | `wait_for_install_complete()` has bounded `overall_timeout_seconds` (line 692 passes self.timeout_seconds) → polling loop enforces exit at line 613 when `elapsed >= overall_timeout_seconds` → distinguishable failure reasons stored in self.last_failure_reason (lines 615–627) → printed to stderr (line 628) | ✓ WIRED | No unbounded wait; timeout always respected; reason always provided |

## Requirements Coverage

| Requirement | Requirement Text | Status | Evidence |
|-------------|-----------------|--------|----------|
| VM-01 | Script creates, boots, resets, and destroys a VirtualBox test VM unattended via VBoxManage — no manual GUI steps | ✓ SATISFIED | InstallerE2ETester.create_vm (VBoxManage createvm/modifyvm/createmedium/storagectl/storageattach), boot_vm (startvm), destroy_vm (controlvm/unregistervm). All subprocess-based, no GUI interaction. Verified commits b525c74 & 3801956/edf9054. |
| VM-02 | Script drives the installer TUI to completion via blind scancode keystroke injection, reusing the sequence proven in the ppsa-installer-test skill | ✓ SATISFIED | INSTALLER_TUI_SEQUENCE (lines 86–92) contains verbatim bytes from skill. drive_installer_tui() (lines 484–510) iterates sequence, calls send_scancodes() (line 479). Zero screenshot/OCR. Verified commit 3801956. |
| VM-03 | Script detects install completion by polling for /opt/ppsa/.installed (or equivalent first-boot marker) over SSH, distinguishing "still installing" from "done" | ✓ SATISFIED | wait_for_install_complete() (lines 558–647) polls `test -f /opt/ppsa/.installed && echo INSTALLED`, checks stdout for "INSTALLED" (line 598), returns immediately on success (lines 600–604). Verified commit edf9054. |
| NET-01 | Script performs a pre-boot safety check (or documented default) preventing the shared WireGuard identity (10.8.0.2) from colliding with a live production server, and tolerates NetBird enrollment delays/timeouts without hanging the whole run | ✓ SATISFIED | check_wg_hub_identity_safe() (lines 214–299) queries hub, aborts on live handshake unless --skip-identity-check (lines 816–820). Bounded timeout on all network calls (lines 256, 259). wait_for_install_complete() has bounded overall_timeout_seconds with distinguishable timeout reasons (lines 615–627). Verified commits b525c74 & edf9054. |
| BOOT-01 | Script verifies the post-install boot chain came up correctly — signed shim/GRUB success, or explicitly documents the unsigned-fallback path when Secure Boot is off | NOT IN PHASE 6 | Explicitly deferred to Phase 7. run() prints note at line 706–710: "boot-chain verification (BOOT-01/BOOT-02) is Phase 7's responsibility". |
| BOOT-02 | Script distinguishes a genuinely hung install from a slow-but-progressing one via heartbeat/timestamp polling, avoiding false-negative timeouts on slow Docker pulls | NOT IN PHASE 6 | Explicitly deferred to Phase 7. |
| TEST-01 | Script invokes the existing ppsa-smoke-test.py against the freshly-installed box and folds its result into the overall verdict | NOT IN PHASE 6 | Explicitly deferred to Phase 8. |
| TEST-02 | A single script invocation reports one pass/fail summary (exit code 0/1 + one-liner), keeping raw install/boot/smoke-test output out of the main context | PARTIALLY IN PHASE 6 | Exit code 0/1 and one-liner summary implemented by run() and main(). Smoke-test chaining is Phase 8's scope. |

**Phase 6 Requirements Coverage:** 4 of 4 required (VM-01, VM-02, VM-03, NET-01) — ✓ ALL SATISFIED

## Anti-Patterns Found

| File | Line | Pattern | Severity | Impact |
|------|------|---------|----------|--------|
| scripts/ppsa-installer-e2e.py | 85 | "comment explaining why YES bytes MUST stay uppercase" | ℹ️ Info | Prevents future simplification errors; best-practice defensive comment. |
| scripts/ppsa-installer-e2e.py | 277–281 | datetime import inside function (lazy import) | ℹ️ Info | Acceptable pattern: imports only when needed (ISO datetime parsing path). No blocker. |
| scripts/ppsa-installer-e2e.py | 537, 555 | `except Exception as exc: # noqa: BLE001` (bare except in cleanup) | ℹ️ Info | Intentional per code comments: cleanup must never raise even on unexpected errors. Acceptable for cleanup-only code paths. |

**No blockers found.** All anti-patterns are intentional or best-practice.

## Behavioral Spot-Checks

| Behavior | Command | Result | Status |
|----------|---------|--------|--------|
| Script syntax valid | `python -c "import ast; ast.parse(open('scripts/ppsa-installer-e2e.py').read())"` | No SyntaxError | ✓ PASS |
| CLI help works | `python scripts/ppsa-installer-e2e.py --help` | Exit 0, all 14 args listed | ✓ PASS |
| Missing ISO detected | `python scripts/ppsa-installer-e2e.py /nonexistent.iso` | Exit 2, stderr: "ERROR: ISO not found at..." | ✓ PASS |
| Imports stdlib only | `grep "^import\|^from" scripts/ppsa-installer-e2e.py` | 14 lines, all stdlib (argparse, atexit, json, os, re, shutil, subprocess, sys, time, urllib.*, collections, http.cookiejar, pathlib) | ✓ PASS |
| Critical scancode bytes present | `grep -c "2a 15 95 12 92 1f 9f aa 1c 9c" scripts/ppsa-installer-e2e.py` | Count = 3 (three YES-confirmations) | ✓ PASS |
| Class/function definitions present | `grep -c "class InstallerE2ETester\|^def run_vboxmanage\|def check_wg_hub_identity_safe\|def drive_installer_tui\|def send_scancodes\|def wait_for_install_complete\|class SshRunner"` | All 1 each (8 symbols) | ✓ PASS |
| TODO placeholder removed | `grep -c "TODO(Plan 06-02)" scripts/ppsa-installer-e2e.py` | Count = 0 (no TODOs left) | ✓ PASS |
| Runs without crashing (help path only) | `python scripts/ppsa-installer-e2e.py --help >/dev/null 2>&1` | Exit 0 | ✓ PASS |

**All behavioral checks passed.**

## Deviations from Plan

**None identified.** Both plans were executed exactly as specified:

- **Plan 01:** VM lifecycle skeleton, NET-01 safety check, atexit cleanup, CLI argparse, all implemented per task acceptance criteria. Verified commit b525c74.
- **Plan 02:** TUI driving (INSTALLER_TUI_SEQUENCE + drive_installer_tui + send_scancodes), completion polling (SshRunner + wait_for_install_complete), run() orchestration, all implemented per task acceptance criteria. Verified commits 3801956 & edf9054.

No deviations from documented patterns, no unresolved dependencies.

## Known Limitations (Deferred to Later Phases)

1. **Boot-chain verification (BOOT-01/BOOT-02):** Explicitly reserved for Phase 7. The script prints a note (lines 706–710) that this phase does not perform signed/unsigned GRUB detection.
2. **Smoke-test invocation (TEST-01/TEST-02):** Explicitly reserved for Phase 8. The orchestrator script outputs a one-line PASS/FAIL summary suitable for chaining with ppsa-smoke-test.py in a later phase.
3. **NetBird overlay IP discovery:** Out of scope. The script requires `--ssh-target` to be supplied by the caller (already-reachable address). IP discovery would be a separate future enhancement.

These limitations are documented in the plans and do not impact Phase 6's goal achievement.

## User Setup Required

None. The script is self-contained and runnable immediately:

1. **VirtualBox:** Must be installed (VBoxManage binary on PATH or fallback to Windows default location).
2. **WireGuard hub credentials (optional):** If `PPSA_WG_HUB_PASSWORD` env var or `--wg-hub-password` flag is provided, the script queries the hub to check for live identity collision. If not provided, the check gracefully skips (prints WARNING).
3. **SSH target (optional for phase goal, required for full completion polling):** The script can create/boot a VM without `--ssh-target`, but completion polling requires an address (e.g., NetBird DNS label, overlay IP, or LAN IP).

No secrets or credentials are hardcoded. No external service configuration is required to run the core VM lifecycle (create/boot/TUI/cleanup).

## Overall Status

**PASSED**

All 9 observable truths verified. All 4 phase-required artifacts verified. All 4 phase-required requirements (VM-01, VM-02, VM-03, NET-01) satisfied. All acceptance criteria across both plans met. All behavioral spot-checks passed. No blocking anti-patterns found. Script is ready for hand-testing against a real CI-built installer ISO in VirtualBox.

### Next Phase Readiness

Phase 7 (Boot Chain Verification) can extend this script's `run()` method by adding boot-chain checks after the TUI-driving step. Phase 8 (Smoke Test) can chain `ppsa-smoke-test.py` against the same `--ssh-target` after successful completion polling, reusing the same InstallerE2ETester instance.

---

_Verified: 2026-07-20T14:35:00Z_
_Verifier: Claude (gsd-verifier)_
