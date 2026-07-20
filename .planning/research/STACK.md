# Technology Stack: Automated Installer-ISO E2E Testing

**Project:** PPSA v1.5.0 — Automated Installer-ISO End-to-End Tester
**Researched:** 2026-07-20
**Domain:** VirtualBox automation + TUI-driven Debian installer scripting + boot-chain verification

## Executive Summary

Automating the installer-ISO test path requires three separate automation layers: **(1) VirtualBox VM orchestration** via VBoxManage subprocess calls (already partially done in `modules/VirtualBox.psm1` for the PowerShell builder); **(2) blind TUI keystroke driving** via timed scancode injection + screenshot polling (proven technique in `ppsa-installer-test` skill); and **(3) post-install verification** via SSH to the overlay and existing smoke-test reuse.

No single packaged framework handles all three seamlessly. Instead, layer the existing tools: extend the PowerShell VirtualBox module with ISO attachment + scancode/screenshot capabilities; add a Python orchestrator script that drives the whole pipeline (VM create → ISO boot → install → smoke test); leverage the existing `ppsa-smoke-test.py` for the final SSH-based verification without modification.

**Recommended stack:** PowerShell 7 for VirtualBox orchestration (VBoxManage subprocess wrapper); Python 3.12 (stdlib only + paramiko for SSH) for E2E orchestration; no TUI framework needed — use direct VBoxManage keyboardputscancode + screenshotpng polling (proven pattern from manual skill).

## Core Technology Decisions

### 1. VirtualBox Control Layer

| Technology | Version | Purpose | Why |
|------------|---------|---------|-----|
| **VBoxManage CLI** | 7.0+ | VM creation, ISO attachment, scancode injection, screenshot capture | Direct subprocess calls; proven in existing `Start-PpsaBuilder.ps1` builder. VirtualBox MCP tool available but designed for single operations (not orchestration loops); subprocess wrapper is more practical for script-based orchestration. |
| **PowerShell 7** | 7.x | Wrapper module around VBoxManage (extend existing module) | Project already has `modules/VirtualBox.psm1` (VM creation, disk attach, power control). Extend with new functions for ISO attachment, keyboardputscancode loops, screenshotpng polling. |

**Why not VirtualBox SDK (vboxapi / PyVBox)?**
- Overkill for headless installer automation; subprocess VBoxManage is proven + simpler.
- VBox SDK requires Windows COM server setup; subprocess works cross-platform (Linux CI future-proofs).
- Already have working PowerShell module patterns; no need to port to Python SDK.

**Why not Vagrant/Packer?**
- Both require guest-agent interop (no guest additions on PPSA); blind-scancode install does not.
- Over-engineered for a single use case (one fresh install per test run).
- VBoxManage direct CLI is transparent and debuggable.

### 2. TUI Installer Automation

| Technology | Version | Purpose | Why |
|------------|---------|---------|-----|
| **VBoxManage keyboardputscancode** | Built-in | Send raw USB scancodes to the running VM (GRUB menu, TUI prompts, YES confirmations) | Proven in `ppsa-installer-test` skill; works completely headless (no guest additions). Blind scancode injection is the only path that works on a Debian installer with no guest tools. |
| **VBoxManage screenshotpng** | Built-in | Capture PNG screenshots of the VM console for state detection | Proven technique; no OCR needed — timing + expected state progression (GRUB → TUI → installer → reboot) is sufficient for the linear install flow. |
| **Python PIL/Pillow** (optional) | 10.x | Image comparison for screenshot detection (if needed) | Optional fallback if timing-based detection proves unreliable; can detect when the installer has moved past a known screen state by comparing against a baseline PNG. Start without it; add only if timing is flaky. |

**Why not pexpect/tmux?**
- pexpect spawns a *new* pseudo-terminal; it does not control an already-running headless VirtualBox VM.
- tmux is a terminal multiplexer; it cannot inject into a running VirtualBox guest.
- Screenshot polling + blind scancodes is the only approach that works for headless VirtualBox without guest agent.

**Why not Expect (TCL)?**
- PPSA project uses Python for WebUI + smoke tests; maintaining TCL as a test dependency is not justified.
- Pure-Python timing-based orchestrator (no Expect needed) is simpler and more maintainable.

### 3. Post-Install SSH Verification Layer

| Technology | Version | Purpose | Why |
|------------|---------|---------|-----|
| **Python 3.12** | 3.12 | Main orchestrator script (vm-create → iso-boot → install → ssh-connect → smoke-test) | Stdlib-only design for smoke-test.py (existing); reuse the same language for the orchestrator to avoid dependency sprawl. |
| **paramiko** | 3.4+ | SSH client library for connecting to the installed VM over NetBird overlay (after install completes) | Minimal, pure-Python SSH; handles plink-like behavior on Windows via Python instead of shelling out to plink. Overkill for one command, but needed if the orchestrator is in Python. |
| **subprocess (stdlib)** | Built-in | Invoke VBoxManage commands, run smoke-test.py as subprocess | Proven pattern; ppsa-smoke-test.py already handles multi-platform (plink on Windows, ssh on Linux). Orchestrator can simply subprocess.run() it after VM is reachable. |

**Why not Fabric (over Paramiko)?**
- Fabric adds task/role abstractions; this orchestrator is a linear sequence, not a distributed deployment.
- Paramiko alone is sufficient (low-level SSH) or just use subprocess.run() on existing ppsa-smoke-test.py (even simpler).

**Why not subprocess.run() instead of Paramiko?**
- If using PowerShell for VBox orchestration, subprocess will be PowerShell native (simpler).
- If using Python for VBox orchestration, can use paramiko for a single unified Python flow (no plink fallback needed).
- Compromise: **orchestrator in Python with subprocess calls to VBoxManage, optional paramiko for direct SSH if polling-based retry is needed**.

### 4. Boot-Chain Verification

| Technology | Purpose | Why |
|------------|---------|-----|
| **dmesg + journalctl** (on test VM) | Detect signed/unsigned GRUB boot after install | After SSH is up, query the guest with `sudo dmesg \| grep -i 'secure.boot\|signature'` and `sudo journalctl -b \| grep -iE 'secure.boot\|uefi\|verification'`. PPSA's signed shim/GRUB configuration will leave audit trail in kernel logs. |
| **UEFI firmware boot messages** (dmesg) | Confirm shim signature verification chain | dmesg on the test VM logs shim's loading + kernel verification via `shim_lock`; presence of these messages indicates signed-boot path was taken. Absence (with graceful GRUB fallback on console) indicates unsigned path. |
| **Baseline screenshot comparison** (optional) | Visually confirm GRUB prompt vs shim-firmware-error state | If dmesg audit is insufficient, take screenshots at three moments: (1) ISO boot (UEFI firmware screen), (2) GRUB live menu appears, (3) after install reboots. Compare against baseline to confirm no shim errors were shown. |

**Why not parse EFI variables or MOK tools?**
- EFI variable access requires `efivarfs` on the test VM and elevated privileges; fragile.
- MOK (Machine Owner Key) enrollment is not used by PPSA (no custom certificates — Debian's signed shim/GRUB is sufficient).
- dmesg + journalctl audit trail is sufficient and portable.

## Recommended Stack

### VirtualBox Orchestration (PowerShell)

Extend the existing `modules/VirtualBox.psm1` with:

```powershell
function Attach-IsoToVm {
    param(
        [Parameter(Mandatory=$true)] [string]$Name,
        [Parameter(Mandatory=$true)] [string]$IsoPath,
        [int]$Port = 1
    )
    # Attach ISO to SATA port 1 (DVD drive)
    # Example: VBoxManage storageattach <vm> --storagectl SATA --port 1 --device 0 --type dvddrive --medium <iso>
}

function Send-VmKeyboardScancodes {
    param(
        [Parameter(Mandatory=$true)] [string]$Name,
        [Parameter(Mandatory=$true)] [string[]]$Scancodes
    )
    # Example: VBoxManage controlvm <vm> keyboardputscancode <hex bytes>
}

function Get-VmScreenshot {
    param(
        [Parameter(Mandatory=$true)] [string]$Name,
        [Parameter(Mandatory=$true)] [string]$OutputPath
    )
    # Example: VBoxManage controlvm <vm> screenshotpng <file.png>
}

function Wait-VmBootComplete {
    param(
        [Parameter(Mandatory=$true)] [string]$Name,
        [int]$TimeoutSeconds = 300
    )
    # Poll screenshots until GRUB live menu or installed-system login prompt detected
    # Use timing + screenshot polling; no OCR needed
}
```

### E2E Orchestrator (Python)

Create `scripts/ppsa-installer-e2e-test.py` (new):

```python
#!/usr/bin/env python3
"""
PPSA Installer ISO E2E Tester

Orchestrates the full test flow:
1. Download/decompress installer ISO (via ppsa-release-build skill)
2. Create fresh VirtualBox VM
3. Boot from ISO + drive TUI install via blind scancodes
4. Wait for post-install boot
5. Verify boot chain (signed/unsigned)
6. Connect over NetBird SSH
7. Run existing ppsa-smoke-test.py
8. Report pass/fail summary

Usage:
    python scripts/ppsa-installer-e2e-test.py v1.5.0-nb.1 --vm-name ppsa-test --iso-path H:/dev/palimage/v1.5.0/ppsa-installer-v1.5.0-nb.1.iso
"""

import argparse
import subprocess
import json
import time
import tempfile
import sys
from pathlib import Path

class InstallerE2ETester:
    def __init__(self, version, vm_name, iso_path, netbird_address=None):
        self.version = version
        self.vm_name = vm_name
        self.iso_path = Path(iso_path)
        self.netbird_address = netbird_address or f"ppsa-ppsa-test.nb.pleaseee.eu.org"
        self.log_dir = Path("installer-e2e-logs")
        self.log_dir.mkdir(exist_ok=True)
    
    def run(self):
        """Execute the full pipeline."""
        steps = [
            ("Create VM", self._create_vm),
            ("Attach ISO", self._attach_iso),
            ("Boot and install", self._boot_and_install),
            ("Wait for post-install boot", self._wait_postinstall_boot),
            ("Verify boot chain", self._verify_boot_chain),
            ("SSH connectivity check", self._check_ssh),
            ("Run smoke test", self._run_smoke_test),
        ]
        
        results = {}
        for step_name, step_func in steps:
            try:
                print(f"[{step_name}] Starting...", flush=True)
                step_func()
                results[step_name] = "PASS"
                print(f"[{step_name}] OK", flush=True)
            except Exception as e:
                results[step_name] = f"FAIL: {e}"
                print(f"[{step_name}] FAILED: {e}", file=sys.stderr, flush=True)
                return False, results
        
        return True, results
    
    def _create_vm(self):
        """Create VM via PowerShell VirtualBox module."""
        # Invoke PowerShell: Import-Module ./modules/VirtualBox.psm1; New-TestVm ...
        pass
    
    def _attach_iso(self):
        """Attach the installer ISO to the VM."""
        # VBoxManage storageattach ...
        pass
    
    def _boot_and_install(self):
        """Boot VM from ISO and drive the TUI install via scancodes."""
        # 1. Boot VM
        # 2. Wait ~75s for GRUB live menu (screenshot poll)
        # 3. Press Enter (scancode 1c 9c)
        # 4. Wait ~60s for PPSA Installer TUI (screenshot poll)
        # 5. Send disk selection + 3x YES scancodes
        # 6. Wait ~4 min for install to complete and reboot into installed system
        pass
    
    def _wait_postinstall_boot(self):
        """Wait for the installed system to boot up (login prompt or banner)."""
        # Screenshot poll until we see the first-boot banner
        # Timeout ~5 min
        pass
    
    def _verify_boot_chain(self):
        """Confirm the boot chain (signed or unsigned path)."""
        # SSH into the VM and run:
        #   sudo dmesg | grep -i 'secure.boot\|signature\|shim'
        #   sudo journalctl -b | grep -iE 'secure.boot\|uefi\|verification'
        # Log the output; verify no errors (if signed path expected)
        pass
    
    def _check_ssh(self):
        """Verify SSH connectivity over NetBird overlay."""
        # Try to SSH to ppsa@<netbird_address> (or overlay IP) with ppsa/ppsa creds
        # This is the gate before smoke test can run
        pass
    
    def _run_smoke_test(self):
        """Invoke the existing ppsa-smoke-test.py."""
        # subprocess.run([
        #     "python", "scripts/ppsa-smoke-test.py",
        #     self.netbird_address,
        #     "--ssh-password", "ppsa"
        # ])
        pass

if __name__ == "__main__":
    parser = argparse.ArgumentParser(__doc__)
    parser.add_argument("version", help="Version tag (v1.5.0-nb.1)")
    parser.add_argument("--vm-name", default="ppsa-test", help="VM name (default: ppsa-test)")
    parser.add_argument("--iso-path", required=True, help="Path to installer ISO")
    parser.add_argument("--netbird-address", help="NetBird DNS label or overlay IP (default: ppsa-ppsa-test.nb.pleaseee.eu.org)")
    args = parser.parse_args()
    
    tester = InstallerE2ETester(args.version, args.vm_name, args.iso_path, args.netbird_address)
    success, results = tester.run()
    
    print("\n" + "="*60)
    print("E2E INSTALLER TEST SUMMARY")
    print("="*60)
    for step, result in results.items():
        status = "✓ PASS" if result == "PASS" else f"✗ {result}"
        print(f"  {step:.<40} {status}")
    print("="*60)
    
    exit(0 if success else 1)
```

### SSH Integration Pattern (Python)

For the orchestrator to wait for SSH readiness and connect:

```python
import paramiko
import time

def wait_for_ssh(address, username="ppsa", password="ppsa", timeout=120):
    """Poll for SSH connectivity, retry with backoff."""
    client = paramiko.SSHClient()
    client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    
    start = time.time()
    while time.time() - start < timeout:
        try:
            client.connect(address, username=username, password=password, timeout=5)
            client.close()
            return True
        except (paramiko.AuthenticationException, paramiko.SSHException, OSError):
            time.sleep(5)
    
    return False
```

### Smoke Test Reuse (No Changes Needed)

The existing `scripts/ppsa-smoke-test.py` already:
- Detects Windows vs Linux and uses plink/ssh accordingly
- Connects to a NetBird DNS label or overlay IP
- Returns structured pass/fail output

Simply invoke it as:
```python
result = subprocess.run([
    "python", "scripts/ppsa-smoke-test.py", netbird_address,
    "--ssh-password", "ppsa", "--verbose"
], capture_output=True, text=True)
```

## Alternatives Considered

| Layer | Recommended | Alternative | Why Not |
|-------|-------------|-------------|---------|
| VirtualBox control | VBoxManage (subprocess) | VirtualBox SDK (vboxapi) | SDK requires Windows COM setup; subprocess is simpler and proven. |
| VirtualBox control | PowerShell module extension | Python ctypes/pywin32 | PowerShell already has working module; reuse it. |
| TUI automation | VBoxManage scancodes + screenshot polling | Expect / autoexpect | Expect is TCL; PPSA project is Python/Bash/PowerShell. Scancodes work headless without guest agent. |
| TUI automation | Timing-based detection | Pillow OCR or template matching | Debian installer TUI has linear flow; timing + screenshot polling is sufficient. OCR is overkill and brittle. |
| SSH | subprocess.run(ppsa-smoke-test.py) | Paramiko direct calls | Smoke test already handles multi-platform SSH; reuse it via subprocess. Simpler than reimplementing checks. |
| Boot verification | dmesg/journalctl audit logs | EFI variable parsing | dmesg is portable; EFI vars are fragile (need efivarfs). PPSA uses standard Debian signed shim (no MOK needed). |

## Installation & Setup

### Dependencies

```bash
# PowerShell 7+
# Already present on Windows; install on Linux: sudo apt install -y powershell

# Python 3.12+
pip install paramiko  # For SSH if orchestrator is Python

# VirtualBox 7.0+
# Already present on test host

# Existing modules (no new installs)
# - modules/VirtualBox.psm1 (extend with new functions)
# - scripts/ppsa-smoke-test.py (reuse as-is)
```

### New Files to Create

1. **Extend `modules/VirtualBox.psm1`** with:
   - `Attach-IsoToVm`
   - `Send-VmKeyboardScancodes`
   - `Get-VmScreenshot`
   - `Wait-VmBootComplete` (or move to orchestrator as it's more complex)

2. **Create `scripts/ppsa-installer-e2e-test.py`**:
   - Main orchestrator class (`InstallerE2ETester`)
   - Step-by-step pipeline
   - Pass/fail summary reporting
   - Stdout stays clean; raw logs go to `installer-e2e-logs/`

3. **Create `docs/installer-e2e-testing.md`**:
   - How to run the test locally
   - Expected duration (~15-20 min per run)
   - Troubleshooting guide (timing issues, SSH timeouts, screenshot polling edge cases)

## Confidence & Tradeoffs

### High-Confidence Decisions

- **VBoxManage subprocess approach:** Proven pattern in `Start-PpsaBuilder.ps1` (already in production); same pattern used in manual `ppsa-installer-test` skill.
- **Existing smoke-test reuse:** Test already handles multi-platform SSH, NetBird overlay addressing, structured output; no reason to rewrite.
- **dmesg boot-chain verification:** Simple, portable audit trail; aligns with existing Debian Secure Boot design.

### Medium-Confidence Decisions

- **Timing-based vs screenshot-based detection:** Debian installer TUI is linear (GRUB → TUI → wipe/write → reboot); timing should be reliable, but *screenshot confirmation as fallback is essential*. If timing drifts, polling will detect the state change via screenshot comparison.
- **Python orchestrator vs PowerShell:** Python enables reuse of the SSH/smoke-test flow (both Python), but orchestrator could equally be PowerShell. Python chosen for consistency with existing test suite; PowerShell equally valid.

### Known Limitations

- **No guest-agent interop:** Blind scancodes work, but there's no programmatic way to know if a keystroke was actually processed; screenshot polling is the only confirmation. Rare edge case (fast system, screenshot poll misses a state) is acceptable since installer is idempotent (can retry from last known step).
- **Timing sensitivity:** First-boot Docker pull can take 10+ min (transient DNS failures, layer cache misses); timeout values must be conservative (~5 min per major step). See PPSA installer-test skill for known stall symptoms (resource contention, WSL2/Hyper-V interference).
- **NetBird DNS availability:** Test assumes NetBird overlay is up and DNS label resolves. If NetBird control plane is down, test must fall back to overlay IP (100.x.x.x). Orchestrator should handle both with a fallback.

## Integration with Existing Skills

- **ppsa-release-build skill:** Downloads the ISO artifact. New orchestrator invokes this skill's download logic (or reruns `aria2c -x16` directly).
- **ppsa-installer-test skill:** Manual version of the same flow (VM creation, blind scancodes, SSH, smoke test). New automation scripts the exact same steps but unattended.
- **ppsa-smoke-test.py:** Reused as-is; orchestrator calls it as subprocess after SSH is up.

## Phase Roadmap

**Phase 1: VirtualBox Module Extensions**
- Extend `modules/VirtualBox.psm1` with ISO attachment, scancode/screenshot functions.
- Unit test each function (mock VBoxManage if needed).

**Phase 2: Orchestrator Script & Boot-Chain Verification**
- Write `scripts/ppsa-installer-e2e-test.py` orchestrator.
- Implement boot-chain verification (dmesg/journalctl checks).
- Manual end-to-end test against a real CI-built ISO.

**Phase 3: CI Integration (Stretch)**
- Integrate orchestrator into GitHub Actions workflow (requires self-hosted runner with VirtualBox).
- Auto-trigger on release builds or manual workflow_dispatch.
- Report results back to GitHub (commit status, release notes).

## Sources

- [Fabric: Python deployment & execution library](https://www.fabfile.org/)
- [Paramiko: Python SSHv2 implementation](https://www.paramiko.org/)
- [pexpect: Pseudo-terminal for Python](https://pexpect.readthedocs.io/en/stable/)
- [pytest-tmux: tmux-driven testing for pytest](https://pytest-tmux.readthedocs.io/)
- [Debian Secure Boot documentation](https://wiki.debian.org/SecureBoot)
- [Debian boot chain verification (UEFI/shim/GRUB)](https://debamax.com/blog/2019/04/19/an-overview-of-secure-boot-in-debian/)
- [PyVBox: VirtualBox Python SDK wrapper](https://pypi.org/project/pyvbox/)
- [VBoxManage reference](https://www.virtualbox.org/manual/ch08.html)
