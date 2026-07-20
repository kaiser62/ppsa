---
task_id: 260721-54i
type: quick
status: complete
files_modified: [scripts/ppsa-installer-e2e.py]
---

# 260721-54i: E2E Tester VirtualBox Bugs - Summary

Fixed two confirmed bugs in `scripts/ppsa-installer-e2e.py`, both reproduced live during a real installer-ISO end-to-end run in VirtualBox: a missing `--basefolder` flag that let VM/disk creation silently fall through to the host C: drive (violating repo disk policy and once filling C: to 100%, triggering `VERR_DISK_FULL`), and a hard failure on missing `--ssh-target` that made the script incapable of running truly unattended against a fresh VM whose LAN IP can't be known in advance.

## Accomplishments

**Task 1 - `--basefolder` CLI flag (commit `1a93d24`)**
- Added `DEFAULT_VM_BASEFOLDER = r"H:\dev\palimage\vms"` constant, matching the proven manual recipe in `.claude/skills/ppsa-installer-test/SKILL.md`.
- Added `--basefolder` CLI argument (default `DEFAULT_VM_BASEFOLDER`), documented as controlling where VirtualBox registers the VM and stores its disk.
- Added `basefolder` parameter to `InstallerE2ETester.__init__()`, stored as `self.basefolder`.
- Replaced hardcoded `self.vm_dir = Path.home() / "VirtualBox VMs" / self.vm_name` with `self.vm_dir = Path(self.basefolder) / self.vm_name`.
- Added `"--basefolder", str(self.basefolder)` to the `createvm` VBoxManage args list in `create_vm()`.
- Wired `basefolder=args.basefolder` into the `InstallerE2ETester(...)` constructor call in `main()`.

**Task 2 - `discover_guest_ip()` fallback for `ssh_target` (commit `c93d2e4`)**
- Added `GUEST_IP_PROPERTY = "/VirtualBox/GuestInfo/Net/0/V4/IP"` and `GUEST_IP_DISCOVERY_TIMEOUT_SECONDS = 300` constants.
- Added `discover_guest_ip(self, poll_interval_seconds=15)` method to `InstallerE2ETester`, placed between `drive_installer_tui()` and `get_vm_state()`. Polls `VBoxManage guestproperty get <vm> /VirtualBox/GuestInfo/Net/0/V4/IP` on a bounded overall timeout, parses `Value: <ip>` output with a regex, validates the result looks like an IPv4 address before accepting it, and never raises (transient `VBoxManage` failures are caught and treated as "keep polling").
- Rewired `run()`'s no-`--ssh-target` branch: instead of immediately appending a `FAIL:` result, it now calls `discover_guest_ip()` first. On success, `effective_ssh_target` is set to the discovered IP and a `discover_guest_ip: PASS (<ip>)` result is recorded; on failure, a `discover_guest_ip: FAIL: <reason>` result is recorded and the pipeline skips `wait_for_install_complete()` entirely (no attempt with a `None` target).
- When `--ssh-target` is explicitly passed, discovery is skipped entirely and `effective_ssh_target = self.ssh_target` - explicit CLI value always takes priority (it may be a NetBird overlay address unreachable via the bridged LAN NIC).
- Updated the two downstream call sites (`verify_boot_chain()`, `run_smoke_test()`) to use `effective_ssh_target` instead of `self.ssh_target`, so boot-chain verification and the smoke test run against whichever address actually detected install completion.

## Deviations from Plan

None - plan executed exactly as written. Both tasks matched the plan's specified line ranges, method placement, and behavior contracts.

## Files Touched

- `scripts/ppsa-installer-e2e.py` - both fixes applied in the same file, across two atomic commits.

## Commits

- `1a93d24` - `fix(installer-e2e): add --basefolder flag to keep VM/disk off C:`
- `c93d2e4` - `fix(installer-e2e): discover guest IP instead of hard-failing on no --ssh-target`

## Verification

Both fixes are verified via static/structural checks only (syntax parse + argparse/AST inspection), per the plan's `<verification>` section - no live VirtualBox run was performed as part of this quick task:

```bash
python -c "import ast; ast.parse(open('scripts/ppsa-installer-e2e.py').read())"   # PARSE_OK
python scripts/ppsa-installer-e2e.py --help | grep -qi basefolder                 # BASEFOLDER_OK
python -c "import ast; t=ast.parse(open('scripts/ppsa-installer-e2e.py').read()); n={f.name for f in ast.walk(t) if isinstance(f, ast.FunctionDef)}; assert 'discover_guest_ip' in n"  # DISCOVER_OK
```

All three checks passed after each task and again after both were combined.

**Deferred to next live installer-ISO test pass** (per plan's verification section, using the `ppsa-installer-test` skill):
1. Confirm `.vbox`/`.vdi` files actually land under `H:\dev\palimage\vms\ppsa-e2e-test\` after a real `create_vm()` run.
2. Confirm `discover_guest_ip()` successfully resolves a real DHCP-leased IP against a booting installer VM, and that `wait_for_install_complete()` / `verify_boot_chain()` / `run_smoke_test()` proceed correctly against the discovered address.
3. Confirm an explicit `--ssh-target` still bypasses discovery (i.e. `discover_guest_ip` does not appear in the results table when `--ssh-target` is passed).

## Self-Check

- `scripts/ppsa-installer-e2e.py` exists and contains both fixes: FOUND
- Commit `1a93d24` exists in git log: FOUND
- Commit `c93d2e4` exists in git log: FOUND
- `--basefolder` present in `--help` output: FOUND
- `discover_guest_ip` present as a function/method in the AST: FOUND

## Self-Check: PASSED
