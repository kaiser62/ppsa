# Architecture: Automated Installer-ISO E2E Tester

**Project:** PPSA v1.5.0 — Portable Palworld Server Appliance  
**Research Date:** 2026-07-20  
**Domain:** Automated end-to-end testing of installer ISO boot, install, and smoke-test  
**Confidence:** HIGH

## Executive Summary

The automated E2E tester integrates into the existing PPSA architecture as a new orchestration layer—a single Python script (`scripts/ppsa-installer-e2e.py`) that drives the current manual testing flow end-to-end. It:

1. **Acquires the installer ISO** from a local path or GitHub Actions artifact download
2. **Creates a temporary VirtualBox VM** from the ISO using the VirtualBox MCP tool
3. **Drives the installer TUI** with timed keystroke sequences (current blind-keystroke approach from `ppsa-installer-test` skill, but deterministic rather than screenshot-polling)
4. **Monitors first-boot progress** via tty1 log capture and completion markers (`/opt/ppsa/.installed`)
5. **Verifies the boot chain** (signed shim/GRUB success marker or documented unsigned fallback)
6. **Hands off to the existing smoke test** (`scripts/ppsa-smoke-test.py`) via SSH over NetBird overlay
7. **Reports a single PASS/FAIL** summary to stdout

**Key design choice:** Rather than replacing the manual skill-based flow, this new script **automates the steps** that the skill documents, reusing the proven VirtualBox MCP calls, TUI keystroke sequences, and SSH-over-NetBird pattern from v1.3.0 Phase 1.

---

## Component Boundaries

### New Component: Installer E2E Tester

**Location:** `scripts/ppsa-installer-e2e.py`  
**Responsibility:** Orchestrate the full ISO-to-verified-install path  
**Language:** Python 3.12  
**Invocation:** `python scripts/ppsa-installer-e2e.py <iso_path> [--vm-name <name>] [--vbox-path <path>] [--timeout-seconds 600] [--keep-vm]`

**Interfaces:**
- **Input:** ISO file path (`.iso` not `.iso.zst`; decompression is caller's responsibility)
- **Output:** Exit code (0 = PASS, 1 = FAIL), summary message to stdout
- **Artifacts:** Raw logs in `smoke-test-logs/` (from the chained smoke-test script)
- **Dependencies:** VirtualBox MCP tool, Python subprocess (plink for SSH), existing `ppsa-smoke-test.py`

**Phases:**
1. **Setup:** Resolve ISO path, validate file exists, prepare tempdir, register VBox path
2. **VM Lifecycle:** Create VM (via VBox MCP), attach ISO, start headless
3. **Install Phase:** Send blind TUI keystrokes (GRUB menu, disk select, confirmations)
4. **First-Boot Monitoring:** Poll tty1 log or completion marker for "PPSA First Boot Setup" → completion
5. **NetBird Enrollment Wait:** Give the boot-up process time to pull images and reach stable state (most failure risk is here; timeout is configurable, default 10 min)
6. **Smoke-Test Handoff:** Locate the test VM's NetBird overlay IP (if available) or fall back to UfW LAN exception for SSH
7. **Result Aggregation:** Capture smoke-test exit code, clean up VM, return PASS/FAIL

### Modified/Reused Components

| Component | Change | Rationale |
|-----------|--------|-----------|
| `ppsa-installer-test` skill | **No change.** Remains the manual recipe. | New script automates *exactly* what this skill documents; coexistence allows manual verification when needed. |
| `ppsa-smoke-test.py` | **No change.** Reuse as subprocess. | New E2E tester is just a wrapper; smoke test is the canonical verification. |
| `.github/workflows/build-installer.yml` | **No change** (stretch goal: wrap with E2E call on artifact ready). | CI wiring is deferred; E2E script is standalone. |
| VirtualBox MCP | **No change.** Use existing calls. | VBox MCP already handles VM creation, keyboard injection, screenshots. E2E script is a high-level orchestrator over it. |

---

## Data Flow

### Installer ISO → VM Boot → Install → SSH → Smoke Test → Summary

```
┌─────────────────────────────────────────────────────────────────────────┐
│                         ppsa-installer-e2e.py                           │
├──────────────────────────────────────────────────────────────────────────┤
│                                                                          │
│  [1] ISO Acquisition (validate/acquire from local or CI)                │
│       │                                                                  │
│       ├─ Check file exists, readable                                    │
│       └─ Resolve ISO path to absolute (H:\dev\palimage\<ver>\)         │
│                                                                          │
│  [2] VM Lifecycle (VBox MCP)                                            │
│       │                                                                  │
│       ├─ VBoxManage createvm --name ppsa-test-<timestamp>               │
│       ├─ VBoxManage modifyvm (memory 10240, cpus 4, EFI, bridged)       │
│       ├─ VBoxManage createmedium (40GB VDI)                             │
│       ├─ VBoxManage storagectl + storageattach (SATA, ISO on port 1)    │
│       ├─ VBoxManage startvm --type headless                             │
│       └─ Trap EXIT/INT to clean up VM                                   │
│                                                                          │
│  [3] TUI Keystroke Sequence (blind, ~8-10 min)                         │
│       │                                                                  │
│       ├─ Wait ~75s (GRUB loads), send ENTER (1c 9c)                    │
│       ├─ Wait ~60s (TUI menu), select disk 1 (02 82 1c 9c)             │
│       ├─ Send uppercase YES + ENTER 3× with ~4s pauses                │
│       │   (2a 15 95 12 92 1f 9f aa 1c 9c)                              │
│       └─ Installer wipes, decompresses, writes, grows partition         │
│                                                                          │
│  [4] First-Boot Monitoring (via tty1 or system state markers)          │
│       │                                                                  │
│       ├─ Poll /var/log/ppsa-install.log or VBox serial output          │
│       ├─ Expect: "PPSA First Boot Setup" → 9 steps → completion banner │
│       ├─ Timeout: configurable (default 10 min per CLAUDE.md note)     │
│       └─ If stalled >5 min on same line: FAIL (soft-lockup or OOM)    │
│                                                                          │
│  [5] SSH Readiness (NetBird overlay or LAN fallback)                   │
│       │                                                                  │
│       ├─ Test VM auto-enrolled in NetBird during first-boot            │
│       │  (ppsa-netbird-up.service runs with PPSA_NB_SETUP_KEY)         │
│       ├─ Derive overlay IP from NetBird dashboard or wait for stable   │
│       │  DNS label (ppsa-ppsa-test-<timestamp>.nb.pleaseee.eu.org)    │
│       └─ Fallback: ufw LAN exception for IP reachability (one-time)     │
│                                                                          │
│  [6] Smoke Test Invocation (subprocess call)                           │
│       │                                                                  │
│       ├─ python ppsa-smoke-test.py <vm-address>                        │
│       │   [--ssh-password ppsa --timeout 300 --verbose]                │
│       ├─ Capture exit code (0 = all checks pass, 1 = ≥1 check fail)   │
│       └─ Aggregates ~26 checks across 10 groups (SSH, Auth, Stack,     │
│          System, Firewall, NetBird, WG Dormancy, Backup, Regression, API)
│                                                                          │
│  [7] Result Summary & Cleanup                                           │
│       │                                                                  │
│       ├─ Exit code 0 if install + smoke-test both passed              │
│       ├─ Output: one-line PASS/FAIL + summary reason                  │
│       ├─ Optional: keep VM for inspection (--keep-vm flag)             │
│       └─ VBoxManage unregistervm --delete on exit (normal flow)        │
│                                                                          │
└─────────────────────────────────────────────────────────────────────────┘
```

### Input/Output Contract

**Invocation Example:**
```bash
python scripts/ppsa-installer-e2e.py \
  "H:/dev/palimage/v1.5.0/ppsa-installer-v1.5.0-nb.1.iso" \
  --vm-name "ppsa-e2e-test" \
  --vbox-path "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe" \
  --timeout-seconds 600 \
  --verbose
```

**Exit Codes:**
- `0` — PASS: Install + boot + smoke-test all succeeded
- `1` — FAIL: Any phase failed (TUI, first-boot hang, SSH unreachable, smoke-test failure)
- `2` — ERROR: Script invocation or prerequisites failed (missing ISO, VBox not found, etc.)

**Stdout Output:**
```
[PPSA E2E Installer Test] SUCCESS: ppsa-installer-v1.5.0-nb.1.iso
  Install: PASS (ISO→disk in 8m47s)
  Boot chain: PASS (signed shim/GRUB detected)
  First-boot: PASS (completed in 12m13s)
  Smoke test: PASS (26/26 checks)
  VM: ppsa-e2e-test (cleaned up)
```

**On Failure:**
```
[PPSA E2E Installer Test] FAILURE: ppsa-installer-v1.5.0-nb.1.iso
  Install: PASS (ISO→disk in 8m47s)
  Boot chain: PASS (signed shim/GRUB detected)
  First-boot: FAIL — Stalled on "Step 4: Deploying Docker stack" at 00:08:23, no progress after 5 min
  Reason: Possible soft-lockup or image pull timeout (Docker registry issue)
  Remediation: Check VM memory/CPU, run wsl --shutdown to unblock VBox, retry
  Raw logs: smoke-test-logs/ppsa-smoke-*.log
```

---

## Implementation Strategy

### Phase A: TUI Keystroke Sequencing (Deterministic, Non-Visual)

**Current manual approach from `ppsa-installer-test` skill:**
- GRUB wait ~75s, send ENTER
- TUI menu wait ~60s, send disk-select keystrokes
- Repeat YES+ENTER 3× with pauses

**New automated approach:**
- Use **wallclock time** between keystrokes (proven reliable in the skill; no screenshot polling needed)
- Store keystroke sequences as tuples: `(wait_secs, scancodes, description)`
- Example:
  ```python
  INSTALLER_TUI_SEQUENCE = [
      (75, [0x1c, 0x9c], "GRUB live menu: press ENTER"),
      (60, [0x02, 0x82, 0x1c, 0x9c], "Select disk 1 + ENTER"),
      (4, [0x2a, 0x15, 0x95, 0x12, 0x92, 0x1f, 0x9f, 0xaa, 0x1c, 0x9c], "YES+ENTER confirm 1"),
      (4, [0x2a, 0x15, 0x95, 0x12, 0x92, 0x1f, 0x9f, 0xaa, 0x1c, 0x9c], "YES+ENTER confirm 2"),
      (4, [0x2a, 0x15, 0x95, 0x12, 0x92, 0x1f, 0x9f, 0xaa, 0x1c, 0x9c], "YES+ENTER confirm 3"),
  ]
  ```
- **No screenshot comparison** — wallclock timing is sufficient and token-efficient

### Phase B: First-Boot Progress Monitoring

**Three possible strategies (in priority order):**

1. **Completion marker polling** (PREFERRED)
   - Poll for `/opt/ppsa/.installed` (file existence from inside guest via SSH)
   - Once exists → first-boot is done
   - Fallback: poll `/var/log/ppsa-install.log` for "First Boot Setup Complete" line
   - **Why:** Reliable, low-overhead, no console tricks needed
   - **Caveat:** Requires SSH access (provisioned during first-boot or via LAN hotspot)

2. **VBox serial console output** (FALLBACK)
   - Enable serial port on VM, redirect to named pipe, poll output
   - Look for systemd journal markers: `ppsa-install.service` state changes
   - **Why:** Works even if network is not up yet
   - **Caveat:** Windows named pipes are fragile; adds setup complexity

3. **TTY1 screenshot polling** (LAST RESORT)
   - Screenshot the VM, OCR or regex-match text on tty1
   - Detect state transitions: "Step 1" → "Step 2" → ... → "Setup Complete"
   - **Why:** Most visual; human-readable feedback
   - **Caveat:** OCR fails on variable fonts/colors; screenshotting every 10s is token-heavy

**Recommendation:** Use strategy 1 (completion marker). **If first-boot is not fully up yet, SSH will fail and the smoke test will handle that as a pre-requisite failure.** The orchestrator simply waits up to the timeout for `.installed` to exist, then proceeds to smoke-test. If the marker never appears, it's a timeout failure and the tester knows to blame first-boot.

### Phase C: Boot Chain Verification

**Requirement:** Verify Secure Boot chain came up (signed shim/GRUB) OR document the unsigned fallback.

**Implementation:**
- After first-boot completes, SSH to the box and check:
  ```bash
  # Query GRUB/shim via EFI variables (if available)
  efibootmgr 2>/dev/null | grep -i "ppsa\|debian" || echo "UEFI vars not accessible"
  
  # Check kernel command line (always available)
  cat /proc/cmdline | grep -i "efi\|secure"
  
  # Check dmessg for shim/GRUB security markers
  dmesg | grep -iE "shim|signature|secure" | head -5
  ```
- **Expected output (signed path):** Markers like "Secure Boot enabled", "shim" in dmesg
- **Expected output (unsigned fallback):** No shim/signature lines, possibly "Secure Boot disabled"
- **Verdict:** If `/EFI/BOOT/BOOTX64.EFI` exists (which it will from `build-live-usb.sh`), classify as "signed path" or "unsigned path" based on kernel output
- **Smoke test integration:** Add an optional check group "Boot Chain Verification" (1–2 checks, non-blocking on the overall PASS/FAIL but reported in the summary)

---

## Build & Test Order

### Prerequisites (Already Exist)

1. ✓ `scripts/build-live-usb.sh` — single-source image builder
2. ✓ `.github/workflows/build-installer.yml` — CI job that bundles into ISO
3. ✓ `scripts/ppsa-smoke-test.py` — SSH-based verification checklist
4. ✓ `ppsa-installer-test` skill — manual orchestration recipe (reference for new automation)
5. ✓ VirtualBox MCP tool — VM creation, keyboard injection, screenshots

### New Component Build Order

**Phase 1 (v1.5.0 Milestone):**
1. **Create `scripts/ppsa-installer-e2e.py`** (new, ~500 LOC)
   - Depends on: existing VBox MCP, `ppsa-smoke-test.py`, Python stdlib
   - Deliverable: Single orchestrator script
   
2. **Add E2E test script to `tests/test-e2e.ps1`** (new, ~200 LOC PowerShell)
   - Local runner for the e2e script (invokes Python, verifies exit codes, logs output)
   - Reuses patterns from `tests/test-virtualbox.ps1` (existing VBox module tests)
   
3. **Document in `.claude/skills/ppsa-installer-e2e/SKILL.md`** (new, ~150 LOC Markdown)
   - Skill invocation: `/ppsa-installer-e2e --iso-path <path> [--keep-vm]`
   - Wraps the new Python script with error handling and artifact curation
   - Useful for developers and CI when a one-click E2E is needed

4. **Update `.planning/MILESTONES.md` and `PROJECT.md`** (modified)
   - Mark v1.5.0 Phase 1 requirement as in-progress
   - Call-out the new E2E script as the primary test path for releases going forward

**Phase 2 (v1.6.0 or later, stretch):**
- Wire E2E into `.github/workflows/build-installer.yml` as a post-build job
  - Requires self-hosted GitHub Actions runner with VirtualBox (current blocker)
  - Once available, installer ISO builds automatically run E2E before artifact upload
  
---

## Error Handling & Diagnostics

### Failure Modes & Recovery

| Failure | Detection | Mitigation | Output |
|---------|-----------|------------|--------|
| ISO file missing or unreadable | File stat fails | Exit code 2, print usage | `PPSA_E2E: ERROR: ISO not found at <path>` |
| VBox not found on PATH | VBoxManage subprocess fails | Exit code 2, suggest installation | `PPSA_E2E: ERROR: VBoxManage not found. Install VirtualBox.` |
| VM creation fails (disk full, etc.) | VBox MCP returns error | Clean up, exit code 1 | `PPSA_E2E: VM creation failed: <stderr>` |
| GRUB menu never appears (timeout >120s) | No keystroke was sent (wallclock stall) | Assume kernel/bootloader failure, fail TUI phase | `PPSA_E2E: TUI phase failed — GRUB never booted within 120s` |
| Installer stops mid-write (disk full, etc.) | Keystrokes sent, but TUI never exits | Detect stall >configurable timeout (default 10 min) | `PPSA_E2E: Installer stalled at step X. Possible soft-lockup.` |
| First-boot never completes (Docker pull hangs) | `/opt/ppsa/.installed` never created, or log stalled >5 min | Timeout first-boot, log final step reached | `PPSA_E2E: First-boot failed — stalled on step 4 (Docker) after 10m30s` |
| SSH unreachable from test host | `plink`/`ssh` subprocess fails immediately | Retry once with LAN fallback (ufw exception), then fail | `PPSA_E2E: SSH to VM failed. Tried NetBird overlay + LAN fallback. Guest may not be ready.` |
| Smoke test fails (API integrity check) | `ppsa-smoke-test.py` returns exit code 1 | Aggregate failure, print check name | `PPSA_E2E: Smoke test failed: <check_name> — <assertion>. See smoke-test-logs/ for details.` |
| VM has junk WG identity (10.8.0.2 duplicate) | Manual check post-test via skill | Skill documents hub cleanup recipe | Documented in skill; automated cleanup is out of scope |

### Logging & Artifact Collection

- **Main script output:** stdout summary line (PASS/FAIL), brief reason
- **Detailed logs:** `smoke-test-logs/ppsa-smoke-<timestamp>.log` (from chained smoke-test script)
- **VM artifacts:** VDI file kept in `H:\dev\palimage\vms\ppsa-test-<timestamp>\` if `--keep-vm` passed
- **Diagnostic info:** Include in failure output:
  - TUI phase wall-clock times (was keystroke sent? when?)
  - First-boot progress (last step reached, time spent)
  - SSH connectivity (which path was attempted: overlay? LAN?)
  - Smoke-test failures (which checks failed, exact assertion)

---

## Integration Points: Explicit

### New → Existing Interfaces

| New Component | Calls | Method | Input | Output |
|---------------|-------|--------|-------|--------|
| `ppsa-installer-e2e.py` | VBoxManage | Subprocess (via VBox MCP if available, else direct) | VM name, ISO path, memory, CPUs | VM ID, running status |
| `ppsa-installer-e2e.py` | plink/ssh | Subprocess for keystrokes | VM IP, username, password | Exit code, stdout |
| `ppsa-installer-e2e.py` | `ppsa-smoke-test.py` | Subprocess invocation | VM address, SSH options | Exit code, log file path |
| `ppsa-installer-test` skill | `ppsa-installer-e2e.py` | Invocation via `/ppsa-installer-e2e` | ISO path, optional flags | Exit code + summary stdout |
| CI workflow (future) | `ppsa-installer-e2e.py` | Subprocess in GitHub Actions job | ISO artifact URL (via aria2c download first) | Exit code, test summary comment on release |

### No Changes to Existing Interfaces

- ✓ `build-live-usb.sh` — remains single-source builder
- ✓ `ppsa-smoke-test.py` — remains SSH-based checklist (invoked *after* install, not before)
- ✓ `.github/workflows/build-installer.yml` — remains ISO builder (E2E wiring is deferred/optional)
- ✓ `ppsa-installer-test` skill — remains manual reference (new script automates *exactly* what it documents)

---

## Suggested Development Phases

### Phase 1: Core Orchestrator (`ppsa-installer-e2e.py`)

**Deliverable:** Standalone Python script that:
- Takes ISO path + VM name as CLI args
- Creates VBox VM, runs TUI keystroke sequence, waits for first-boot
- Calls `ppsa-smoke-test.py` as subprocess
- Returns exit code 0 or 1

**Test:** Hand-run against a CI-built installer ISO, verify PASS output
**Estimated LOC:** ~500 (VM lifecycle, keystroke sequencing, first-boot polling, subprocess orchestration)

### Phase 2: Skill Wrapper & Local Test Suite

**Deliverable:**
- `tests/test-e2e.ps1` — PowerShell test runner (invoke script, check exit codes)
- `.claude/skills/ppsa-installer-e2e/SKILL.md` — usage documentation

**Test:** Run from skill invocation, verify skill output is clean and actionable
**Estimated LOC:** ~200 PowerShell + ~150 Markdown

### Phase 3: CI Integration (Deferred, Stretch Goal)

**Deliverable:** GitHub Actions job in `build-installer.yml` or new `test-installer.yml` workflow
- Trigger: Manual workflow_dispatch after successful build-installer.yml
- Requires: Self-hosted runner with VirtualBox installed
- Runs: `ppsa-installer-e2e.py` against the built ISO
- Reports: Pass/fail comment on the workflow run

**Blocker:** Self-hosted VirtualBox-capable runner not yet provisioned; current PPSA CI uses ubuntu-latest (Linux containers only)

---

## Success Criteria

- [ ] `ppsa-installer-e2e.py` exists and runs without manual VBox/SSH setup
- [ ] Script handles the full TUI → first-boot → smoke-test chain end-to-end
- [ ] One PASS/FAIL exit code + concise stdout summary (no raw logs in main context)
- [ ] Reuses existing `ppsa-smoke-test.py` — no duplication of install verification logic
- [ ] Script can be invoked from developer machine (Windows) with just an ISO path
- [ ] Documented in skill form so it's discoverable alongside `ppsa-installer-test` (manual) and `ppsa-release-build` (CI)
- [ ] Artifact logs (smoke-test output) preserved in `smoke-test-logs/` for debugging
- [ ] Optional `--keep-vm` flag allows inspection of failed test VMs without cleanup

---

## Architecture Diagram: Component Relationships

```
┌──────────────────────────────────────────────────────────────────────┐
│                    Development Workflow                               │
├──────────────────────────────────────────────────────────────────────┤
│                                                                       │
│  GitHub Actions                                                       │
│  (build-installer.yml)  ──→  ppsa-installer-v1.5.0-nb.1.iso.zst     │
│         │                            │                                │
│         │                            ├─ Download (aria2c)            │
│         │                            ├─ Decompress (zstd -d)         │
│         │                            │                                │
│         └────────────────────────────→ ppsa-installer-e2e.py         │
│                                        │                              │
│                                        ├─ [NEW] Orchestrator Script  │
│                                        │   ├─ VBox VM creation       │
│                                        │   ├─ TUI keystrokes         │
│                                        │   ├─ First-boot wait        │
│                                        │   └─ Boot chain check       │
│                                        │                              │
│                                        ├─ SSH into test VM           │
│                                        │                              │
│                                        └─ ppsa-smoke-test.py         │
│                                            (existing)                 │
│                                            ├─ ~26 checks              │
│                                            ├─ Pass/fail summary       │
│                                            └─ Artifact logs           │
│                                                                       │
│  Result: Exit code 0 (PASS) or 1 (FAIL)                             │
│                                                                       │
└──────────────────────────────────────────────────────────────────────┘

Manual Path (for development/debugging):
  developer machine → ppsa-installer-test skill (manual, documented in .claude/skills/)
    or
  developer machine → python scripts/ppsa-installer-e2e.py <iso>
```

---

## Known Constraints & Workarounds

### Constraint: No Guest Additions (By Design)

- **Issue:** VirtualBox guest additions allow high-level guest interaction (file sharing, seamless mouse), but PPSA images do not bake them in.
- **Workaround:** Use only VBox MCP keyboard injection (scancodes) and polling via SSH. No `VBoxGuest` service assumptions.
- **Mitigation:** Wallclock-based keystroke timing is proven reliable from manual `ppsa-installer-test` skill.

### Constraint: WSL2/Hyper-V Contention on Windows

- **Issue:** WSL2 and VirtualBox compete for CPU/memory; VMs can soft-lockup during heavy container pulls.
- **Workaround:** Script documents the mitigation: run `wsl --shutdown` before invoking E2E tester. Script can optionally detect and warn.
- **Fallback:** If first-boot stalls, timeout and recommend `wsl --shutdown` + retry.

### Constraint: TUI Detection Without OCR

- **Issue:** Cannot screenshot + OCR to detect TUI state precisely; too token-heavy.
- **Workaround:** Use wallclock timing (proven in manual skill) + system state markers (file existence, log tail, SSH readiness).
- **Acceptable:** Keystroke timing has margin of error (~10–15s buffer), which is safe given typical boot/install speeds.

### Constraint: NetBird Enrollment Timing

- **Issue:** First-boot NetBird enrollment happens in parallel with Docker pulls. If registration fails or takes >5 min, SSH over overlay may not be available.
- **Workaround:** E2E script attempts NetBird overlay IP first (if discoverable from local NetBird client), falls back to LAN hotspot + ufw exception (one-time, via console injection).
- **Risk:** If both paths fail, SSH is unreachable and smoke-test cannot run. This is a **first-boot failure**, not a smoke-test failure.

---

## Verification Checklist (For Phase Transition)

- [ ] Script handles ISO path resolution (local file, GitHub artifact URL if added later)
- [ ] VBoxManage create/modify/start/stop flow verified with test ISO
- [ ] TUI keystroke sequence sends correctly (scan code order, timing gaps)
- [ ] First-boot monitoring works (log polling or marker detection)
- [ ] SSH readiness detection works (NetBird overlay or LAN fallback)
- [ ] Smoke-test subprocess invocation captures exit code and aggregates result
- [ ] Failure modes produce actionable output (not raw dumps)
- [ ] VM cleanup (unregister/delete) works even on early exit (EXIT trap)
- [ ] Skill wrapper invocation (/ppsa-installer-e2e) is discoverable and documented
- [ ] Local PowerShell tests pass (test-e2e.ps1)

---

## Dependencies Summary

### Runtime Dependencies
- **Python 3.12+** (stdlib only: `subprocess`, `argparse`, `pathlib`, `time`, `json`, `logging`)
- **VirtualBox** (7.0+) with MCP tool or direct VBoxManage on PATH
- **plink** (PuTTY) or **ssh** (native on Linux/macOS) for SSH subprocess calls
- **Git** (optional, for artifact download integration in future phases)

### Logical Dependencies
- `scripts/build-live-usb.sh` — image builder (already exists, produces .img; CI wraps in ISO)
- `installer/config/includes.chroot/usr/local/bin/ppsa-install` — TUI script (already exists)
- `scripts/ppsa-smoke-test.py` — verification script (already exists, reused as subprocess)
- `ppsa-installer-test` skill — reference documentation (already exists)

### Zero Additional Infrastructure
- No new CI runners required (E2E runs locally during dev; CI integration is deferred)
- No new secrets or environment variables (uses same NetBird + WG config as existing)
- No changes to image build process (`build-live-usb.sh`)

---

## Future Extensibility

### Planned (Phase 2)

1. **GitHub Actions integration** — wire into `build-installer.yml` post-build job (requires self-hosted runner)
2. **Artifact upload** — store successful test summaries with release assets for traceability
3. **Performance metrics** — track install/boot times over releases to detect regressions

### Possible (Phase 3+)

1. **Signed/unsigned boot path verification** — automated check for Secure Boot chain integrity
2. **Custom environment variables** — allow CI to pass `SERVER_NAME`, `MAX_PLAYERS`, etc. during test install
3. **Palworld server functionality test** — verify game server is accepting connections post-install (requires test client or rcon-cli)
4. **Disk size variants** — test both minimal (8GB) and standard (40GB) installs in the same E2E run

---

## Sources & References

- **CLAUDE.md** — Boot chain design, installer ISO layout, first-boot flow
- **PROJECT.md** — v1.5.0 milestone requirements, E2E test scope
- **ppsa-installer-test skill** — Manual orchestration recipe (reference for automation)
- **ppsa-smoke-test.py** — Existing verification checklist (reused as subprocess)
- **build-installer.yml workflow** — Current ISO build pipeline (future CI integration point)
- **Memory artifact: PPSA installer is final product** — Design decision to test ISO, not VDI
- **Memory artifact: PPSA VBox/Hyper-V contention** — Known WSL2 soft-lockup workaround

---

**Phase 1 Recommendation:**

Start with `ppsa-installer-e2e.py` as a standalone script (no skill wrapper yet). Hand-run it against a recent CI build, verify end-to-end flow, then wrap in a skill. Focus on **getting the orchestration right** (VM lifecycle, timing, handoff to smoke-test) rather than optimizing diagnostics or adding bells-and-whistles in Phase 1.
