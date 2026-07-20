#!/usr/bin/env python3
"""PPSA Installer E2E Tester -- orchestrate a fresh installer-ISO VM lifecycle.

Standalone host-side script that creates, boots, and destroys a VirtualBox
VM to drive a PPSA installer ISO end-to-end (VM-01), gated by a pre-boot
WireGuard identity collision safety check against the production wg-easy
hub (NET-01). Stdlib only (no pip packages).

This is Plan 1 of 2 for Phase 6 (vm-orchestration-scripted-install). It
implements the VM lifecycle skeleton (create/attach/boot/state/destroy) and
the NET-01 safety check. Plan 2 extends this same file with blind TUI
keystroke driving and `/opt/ppsa/.installed` completion polling.

Usage:
    python scripts/ppsa-installer-e2e.py <iso_path>
    python scripts/ppsa-installer-e2e.py H:/dev/palimage/v1.5.0/ppsa-installer-v1.5.0-nb.1.iso --keep-vm --verbose

Exit codes: 0 = PASS, 1 = FAIL, 2 = setup/prerequisite ERROR (ISO missing,
VBoxManage missing).
"""

# NetBird enrollment timing note (for Plan 06-02):
# NetBird enrollment happens during first-boot, AFTER install completes --
# not during the VM lifecycle this plan covers. Any future polling loop that
# waits on NetBird overlay readiness (or `/opt/ppsa/.installed`) MUST use a
# bounded timeout with graceful "enrollment timed out; falling back to LAN"
# messaging rather than hanging indefinitely. See .planning/research/
# PITFALLS.md Pitfall 4 (NetBird Enrollment Stalls). No polling code exists
# yet in this plan -- that is Plan 06-02's first-boot monitoring work.

import argparse
import atexit
import json
import os
import re
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.request
from collections import namedtuple
from http.cookiejar import CookieJar
from pathlib import Path

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
DEFAULT_VM_NAME = "ppsa-e2e-test"
DEFAULT_MEMORY_MB = 10240  # Stall-gotcha minimum per ppsa-installer-test skill
DEFAULT_CPUS = 4
DEFAULT_DISK_SIZE_MB = 51200  # 50GB, per PITFALLS.md Pitfall 8 (40GB is marginal)
DEFAULT_BRIDGE_ADAPTER = "Realtek Gaming 2.5GbE Family Controller"
DEFAULT_TIMEOUT_SECONDS = 600
WINDOWS_VBOXMANAGE_FALLBACK = r"C:\Program Files\Oracle\VirtualBox\VBoxManage.exe"

# NET-01 safety check constants
WG_HUB_URL = "http://pleaseee.eu.org:51831"
WG_IDENTITY_PEER_NAME = "ppsa-server"
WG_HANDSHAKE_STALE_SECONDS = 3600  # 1 hour, per installer-test skill's abort threshold

CommandResult = namedtuple("CommandResult", ["stdout", "stderr", "returncode"])

# ---------------------------------------------------------------------------
# VM-02: blind scancode TUI-driving sequence
# ---------------------------------------------------------------------------
# Exact sequence/timings proven manually in .claude/skills/ppsa-installer-test/
# SKILL.md section "2. Drive the installer (blind, via scancodes)". Each entry
# is (wait_seconds, scancode_hex_string, description): wait that long (wall
# clock, since the last step) before sending the scancodes.
#
# The 3x YES-confirmation scancodes MUST stay uppercase ("2a 15 95 12 92 1f 9f
# aa 1c 9c" = Shift+Y Shift+E Shift+S + Enter). Lowercase "yes" ABORTS the
# installer per the skill -- do not "simplify" or re-derive these bytes; they
# are copied verbatim from the proven recipe.
INSTALLER_TUI_SEQUENCE = (
    (75, "1c 9c", "GRUB live menu: press ENTER"),
    (60, "02 82 1c 9c", "PPSA Installer TUI: select disk 1 + ENTER"),
    (4, "2a 15 95 12 92 1f 9f aa 1c 9c", "YES+ENTER confirmation 1 of 3 (uppercase)"),
    (4, "2a 15 95 12 92 1f 9f aa 1c 9c", "YES+ENTER confirmation 2 of 3 (uppercase)"),
    (4, "2a 15 95 12 92 1f 9f aa 1c 9c", "YES+ENTER confirmation 3 of 3 (uppercase)"),
)


class VBoxManageError(Exception):
    """Raised when a VBoxManage subprocess call returns a non-zero exit code."""


def run_vboxmanage(vbox_path, args, timeout=120):
    """Run a VBoxManage subprocess call with a bounded timeout.

    Returns a CommandResult(stdout, stderr, returncode). Raises VBoxManageError
    on FileNotFoundError is NOT handled here -- callers that need the
    "VBoxManage not found" exit(2) contract should catch FileNotFoundError
    themselves (see main()).
    """
    result = subprocess.run(
        [vbox_path, *args],
        capture_output=True,
        text=True,
        timeout=timeout,
    )
    return CommandResult(result.stdout, result.stderr, result.returncode)


def resolve_vbox_path(vbox_path):
    """Resolve the VBoxManage binary path, falling back to the default
    Windows install location if not found on PATH."""
    found = shutil.which(vbox_path)
    if found:
        return found
    if sys.platform == "win32" and Path(WINDOWS_VBOXMANAGE_FALLBACK).exists():
        return WINDOWS_VBOXMANAGE_FALLBACK
    return vbox_path  # let the subprocess call fail with FileNotFoundError


# ---------------------------------------------------------------------------
# NET-01: pre-boot WireGuard identity collision safety check
# ---------------------------------------------------------------------------
def check_wg_hub_identity_safe(hub_url=WG_HUB_URL, timeout=5, hub_password=None):
    """Query the wg-easy hub API for a live handshake on the shared
    'ppsa-server' / 10.8.0.2 identity, before any test VM is ever booted.

    Credentials are read from the `hub_password` argument (populated from
    --wg-hub-password or the PPSA_WG_HUB_PASSWORD env var by the caller) --
    NEVER hardcoded in this script. If no credentials are provided, this
    function does NOT attempt the login at all: PPSA test images ship with
    PPSA_WG_ENABLED=false by default (CLAUDE.md constraint), so this check is
    a defense-in-depth safety net, not a hard requirement to run at all.

    Returns (safe: bool, reason: str). Never raises -- any network error,
    JSON decode failure, or missing expected key is caught and treated as
    "could not verify, proceeding cautiously" (safe=True with a WARNING),
    because a hub outage must not brick every future test run.
    """
    if not hub_password:
        return (
            True,
            "no hub credentials provided; skipping live-check, proceeding on "
            "trust that WireGuard is disabled by default (PPSA_WG_ENABLED=false)",
        )

    try:
        cookie_jar = CookieJar()
        # Install a cookie-aware opener so the session cookie from /api/session
        # is carried into the subsequent /api/client urlopen() call -- both
        # calls below go through urllib.request.urlopen() with an explicit
        # bounded timeout= (NET-01's "never hangs" requirement).
        urllib.request.install_opener(
            urllib.request.build_opener(urllib.request.HTTPCookieProcessor(cookie_jar))
        )

        login_body = json.dumps(
            {"username": "admin", "password": hub_password, "remember": False}
        ).encode("utf-8")
        login_req = urllib.request.Request(
            f"{hub_url}/api/session",
            data=login_body,
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        urllib.request.urlopen(login_req, timeout=timeout)

        client_req = urllib.request.Request(f"{hub_url}/api/client", method="GET")
        with urllib.request.urlopen(client_req, timeout=timeout) as resp:
            clients = json.loads(resp.read().decode("utf-8"))

        peer = next(
            (c for c in clients if c.get("name") == WG_IDENTITY_PEER_NAME), None
        )
        if peer is None:
            return (True, f"peer '{WG_IDENTITY_PEER_NAME}' not found on hub; safe")

        handshake_raw = peer.get("latestHandshakeAt")
        if handshake_raw is None:
            return (
                True,
                f"peer '{WG_IDENTITY_PEER_NAME}' has never handshaked; safe",
            )

        # wg-easy v15 API: accept both epoch-ms int and ISO8601 datetime string.
        if isinstance(handshake_raw, (int, float)):
            handshake_epoch = handshake_raw / 1000.0
        else:
            from datetime import datetime

            parsed = datetime.fromisoformat(str(handshake_raw).replace("Z", "+00:00"))
            handshake_epoch = parsed.timestamp()

        age = time.time() - handshake_epoch
        if age < WG_HANDSHAKE_STALE_SECONDS:
            return (
                False,
                f"Real server '{WG_IDENTITY_PEER_NAME}' has a live handshake "
                f"{age:.0f}s ago on the hub. Booting the test VM now risks "
                f"stealing the shared 10.8.0.2 identity. Pass "
                f"--skip-identity-check to override at your own risk, or "
                f"confirm the real box is offline first.",
            )
        return (True, f"last handshake {age:.0f}s ago (stale); safe")

    except (urllib.error.URLError, TimeoutError, OSError) as exc:
        return (True, f"hub check failed ({exc}); could not verify, proceeding cautiously")
    except (json.JSONDecodeError, KeyError, ValueError) as exc:
        return (True, f"hub check failed ({exc}); could not verify, proceeding cautiously")


# ---------------------------------------------------------------------------
# InstallerE2ETester: VirtualBox VM lifecycle
# ---------------------------------------------------------------------------
class InstallerE2ETester:
    """Orchestrates a single VirtualBox VM's lifecycle for installer-ISO
    end-to-end testing: create, attach ISO, boot, query state, destroy.

    All VBoxManage flags/values reproduce the manually-proven recipe in
    .claude/skills/ppsa-installer-test/SKILL.md section "1. Create VM".
    """

    def __init__(
        self,
        iso_path,
        vm_name=DEFAULT_VM_NAME,
        vbox_path="VBoxManage",
        memory_mb=DEFAULT_MEMORY_MB,
        cpus=DEFAULT_CPUS,
        disk_size_mb=DEFAULT_DISK_SIZE_MB,
        bridge_adapter=DEFAULT_BRIDGE_ADAPTER,
        keep_vm=False,
        timeout_seconds=DEFAULT_TIMEOUT_SECONDS,
        verbose=False,
    ):
        self.iso_path = Path(iso_path).resolve()
        self.vm_name = vm_name
        self.vbox_path = vbox_path
        self.memory_mb = memory_mb
        self.cpus = cpus
        self.disk_size_mb = disk_size_mb
        self.bridge_adapter = bridge_adapter
        self.keep_vm = keep_vm
        self.timeout_seconds = timeout_seconds
        self.verbose = verbose
        self._mac_address = None

        # VM working directory: alongside the default VirtualBox VMs folder
        # convention, but namespaced under a predictable path for this tool.
        self.vm_dir = Path.home() / "VirtualBox VMs" / self.vm_name

    def _log(self, message):
        if self.verbose:
            print(f"[ppsa-installer-e2e] {message}", file=sys.stderr, flush=True)

    def _run(self, args, timeout=120):
        result = run_vboxmanage(self.vbox_path, args, timeout=timeout)
        if result.returncode != 0:
            raise VBoxManageError(
                f"VBoxManage {' '.join(args)} failed (exit {result.returncode}): "
                f"{result.stderr.strip()}"
            )
        return result

    def _generate_stable_mac(self):
        """Build a deterministic-per-run MAC using a cc:cc:cc: OUI prefix +
        3 random bytes, formatted cc:cc:cc:xx:xx:xx.

        Pitfall 9 mitigation (PITFALLS.md): stable enough to avoid ambiguity
        with the host's real NIC, distinguishable in DHCP/ARP logs as a PPSA
        test-run MAC, generated fresh per-instance so sequential runs don't
        collide on stale DHCP leases.
        """
        if self._mac_address is None:
            random_bytes = os.urandom(3)
            self._mac_address = "cc:cc:cc:" + ":".join(f"{b:02x}" for b in random_bytes)
        return self._mac_address

    def create_vm(self):
        """Create the VM, configure it, and attach a fresh VDI disk."""
        self._log(f"Creating VM '{self.vm_name}'...")
        self._run(["createvm", "--name", self.vm_name, "--ostype", "Debian_64", "--register"])

        mac = self._generate_stable_mac()
        self._run(["modifyvm", self.vm_name, "--memory", str(self.memory_mb)])
        self._run(["modifyvm", self.vm_name, "--cpus", str(self.cpus)])
        self._run(
            [
                "modifyvm",
                self.vm_name,
                "--nic1",
                "bridged",
                "--bridgeadapter1",
                self.bridge_adapter,
            ]
        )
        self._run(["modifyvm", self.vm_name, "--macaddress1", mac.replace(":", "")])
        self._run(["modifyvm", self.vm_name, "--boot1", "dvd", "--boot2", "disk"])
        self._run(["modifyvm", self.vm_name, "--firmware", "efi"])
        self._run(["modifyvm", self.vm_name, "--graphicscontroller", "vmsvga", "--vram", "16"])

        self.vm_dir.mkdir(parents=True, exist_ok=True)
        vdi_path = self.vm_dir / f"{self.vm_name}.vdi"
        self._run(
            [
                "createmedium",
                "disk",
                "--filename",
                str(vdi_path),
                "--size",
                str(self.disk_size_mb),
                "--format",
                "VDI",
            ]
        )
        self._run(
            [
                "storagectl",
                self.vm_name,
                "--name",
                "SATA",
                "--add",
                "sata",
                "--controller",
                "IntelAhci",
                "--portcount",
                "2",
            ]
        )
        self._run(
            [
                "storageattach",
                self.vm_name,
                "--storagectl",
                "SATA",
                "--port",
                "0",
                "--device",
                "0",
                "--type",
                "hdd",
                "--medium",
                str(vdi_path),
            ]
        )
        self._log(f"VM '{self.vm_name}' created (mac={mac}, disk={vdi_path})")

    def attach_iso(self):
        """Attach the installer ISO to the SATA DVD drive (port 1)."""
        self._log(f"Attaching ISO {self.iso_path}...")
        self._run(
            [
                "storageattach",
                self.vm_name,
                "--storagectl",
                "SATA",
                "--port",
                "1",
                "--device",
                "0",
                "--type",
                "dvddrive",
                "--medium",
                str(self.iso_path),
            ]
        )

    def boot_vm(self):
        """Boot the VM headless."""
        self._log(f"Booting VM '{self.vm_name}' headless...")
        self._run(["startvm", self.vm_name, "--type", "headless"], timeout=60)

    def send_scancodes(self, scancode_hex_string):
        """Inject a raw keyboard scancode sequence into the running VM via
        VBoxManage controlvm keyboardputscancode.

        A failed keystroke injection is a hard failure (VBoxManageError), not
        something to silently continue past -- if the VM can't receive input,
        the rest of the TUI-driving sequence is meaningless.
        """
        self._run(
            ["controlvm", self.vm_name, "keyboardputscancode", *scancode_hex_string.split()],
            timeout=15,
        )

    def drive_installer_tui(self):
        """Blindly drive the installer TUI (VM-02) using the exact proven
        scancode sequence + wallclock waits from INSTALLER_TUI_SEQUENCE.

        Zero screenshot/OCR dependency -- this reproduces
        .claude/skills/ppsa-installer-test/SKILL.md section 2 verbatim. Each
        step is logged with a timestamp so a developer debugging a stall can
        see exactly which step the run reached (PITFALLS.md Pitfall 5's
        keystroke-validation-log mitigation).
        """
        start = time.time()
        for wait_seconds, scancodes, description in INSTALLER_TUI_SEQUENCE:
            time.sleep(wait_seconds)
            self.send_scancodes(scancodes)
            elapsed = time.time() - start
            timestamp = time.strftime("%H:%M:%S")
            print(
                f"[{timestamp}] {description} -> scancodes sent "
                f"(+{elapsed:.0f}s since TUI-drive start)"
            )

        print(
            "[ppsa-installer-e2e] Installer is now wiping/writing/rebooting "
            "unattended (~4 min per the ppsa-installer-test skill). No fixed "
            "sleep is added here -- wait_for_install_complete() picks up from "
            "this point via bounded SSH polling."
        )

    def get_vm_state(self):
        """Query the VM's current power state via showvminfo
        --machinereadable. Mirrors Get-VmPowerState in VirtualBox.psm1."""
        try:
            result = run_vboxmanage(
                self.vbox_path, ["showvminfo", self.vm_name, "--machinereadable"]
            )
            if result.returncode == 0:
                match = re.search(r'VMState="(\w+)"', result.stdout)
                if match:
                    return match.group(1)
        except (subprocess.TimeoutExpired, FileNotFoundError):
            pass
        return "unknown"

    def destroy_vm(self, force=True):
        """Power off (if needed) and unregister+delete the VM. Never raises
        -- cleanup failures are logged as warnings, since cleanup must not
        mask the real test result."""
        try:
            state = self.get_vm_state()
            if state not in ("poweroff", "aborted"):
                self._log(f"VM '{self.vm_name}' is '{state}'; powering off...")
                try:
                    run_vboxmanage(self.vbox_path, ["controlvm", self.vm_name, "poweroff"])
                except Exception as exc:  # noqa: BLE001 -- cleanup must not raise
                    print(
                        f"WARNING: failed to poweroff VM '{self.vm_name}': {exc}",
                        file=sys.stderr,
                    )
                time.sleep(2)  # Pitfall: cleanup fails on locked VM if unregistered too fast

            result = run_vboxmanage(
                self.vbox_path, ["unregistervm", self.vm_name, "--delete"]
            )
            if result.returncode != 0:
                print(
                    f"WARNING: failed to delete VM '{self.vm_name}': "
                    f"{result.stderr.strip()}",
                    file=sys.stderr,
                )
            else:
                self._log(f"VM '{self.vm_name}' destroyed.")
        except Exception as exc:  # noqa: BLE001 -- never raise from cleanup
            print(f"WARNING: cleanup for VM '{self.vm_name}' failed: {exc}", file=sys.stderr)

    # TODO(Plan 06-02): implement run() -- TUI keystroke driving +
    # `/opt/ppsa/.installed` completion polling, boot-chain verification,
    # and smoke-test handoff. This plan (06-01) only stands up the VM
    # lifecycle skeleton and the NET-01 pre-boot safety check.
    def run(self):
        raise NotImplementedError(
            "run() is implemented in Plan 06-02 (TUI driving + first-boot polling)"
        )


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------
def build_arg_parser():
    parser = argparse.ArgumentParser(
        description="PPSA Installer E2E Tester -- orchestrate a fresh installer-ISO VM lifecycle.",
    )
    parser.add_argument("iso_path", help="Path to the installer ISO file")
    parser.add_argument("--vm-name", default=DEFAULT_VM_NAME, help="VirtualBox VM name")
    parser.add_argument(
        "--vbox-path",
        default="VBoxManage",
        help="Path to the VBoxManage binary (default: resolved via PATH, falls back to the "
        "default Windows install location)",
    )
    parser.add_argument(
        "--memory-mb",
        type=int,
        default=DEFAULT_MEMORY_MB,
        help="VM memory in MB (default: 10240, the Stall-gotcha minimum)",
    )
    parser.add_argument("--cpus", type=int, default=DEFAULT_CPUS, help="VM CPU count")
    parser.add_argument(
        "--disk-size-mb",
        type=int,
        default=DEFAULT_DISK_SIZE_MB,
        help="VM disk size in MB (default: 51200 = 50GB, per PITFALLS.md Pitfall 8)",
    )
    parser.add_argument(
        "--bridge-adapter",
        default=DEFAULT_BRIDGE_ADAPTER,
        help="Host network adapter to bridge the VM's NIC to",
    )
    parser.add_argument(
        "--keep-vm",
        action="store_true",
        help="Skip destroy-on-exit cleanup (leave the VM running/registered for inspection)",
    )
    parser.add_argument(
        "--skip-identity-check",
        action="store_true",
        default=False,
        help="Explicitly override the NET-01 WireGuard identity collision safety check "
        "(default: False -- the check always runs unless this flag is passed)",
    )
    parser.add_argument(
        "--wg-hub-password",
        default=None,
        help="wg-easy hub admin password (overrides PPSA_WG_HUB_PASSWORD env var). "
        "If neither is set, the identity check is gracefully skipped.",
    )
    parser.add_argument(
        "--timeout-seconds",
        type=int,
        default=DEFAULT_TIMEOUT_SECONDS,
        help="Overall pipeline timeout in seconds",
    )
    parser.add_argument("--verbose", action="store_true", help="Enable verbose diagnostic logging")
    return parser


def main():
    parser = build_arg_parser()
    args = parser.parse_args()

    iso_path = Path(args.iso_path)
    if not iso_path.exists():
        print(f"ERROR: ISO not found at {iso_path}", file=sys.stderr)
        sys.exit(2)

    vbox_path = resolve_vbox_path(args.vbox_path)

    # NET-01: pre-boot WireGuard identity collision safety check.
    # MUST run before create_vm()/boot_vm() are ever called.
    if args.skip_identity_check:
        print(
            "WARNING: --skip-identity-check set; NOT checking for live WireGuard "
            "identity collision",
            file=sys.stderr,
        )
    else:
        hub_password = args.wg_hub_password or os.environ.get("PPSA_WG_HUB_PASSWORD")
        safe, reason = check_wg_hub_identity_safe(hub_password=hub_password)
        if not safe:
            print(f"ABORT: {reason}", file=sys.stderr)
            sys.exit(1)
        else:
            print(f"WARNING: WG identity check: {reason}", file=sys.stderr)

    tester = InstallerE2ETester(
        iso_path=iso_path,
        vm_name=args.vm_name,
        vbox_path=vbox_path,
        memory_mb=args.memory_mb,
        cpus=args.cpus,
        disk_size_mb=args.disk_size_mb,
        bridge_adapter=args.bridge_adapter,
        keep_vm=args.keep_vm,
        timeout_seconds=args.timeout_seconds,
        verbose=args.verbose,
    )

    if not args.keep_vm:
        atexit.register(tester.destroy_vm)

    try:
        tester.create_vm()
        tester.attach_iso()
        state = tester.get_vm_state()
        print(f"[ppsa-installer-e2e] VM '{tester.vm_name}' ready. State: {state}")
    except FileNotFoundError:
        print(
            f"ERROR: VBoxManage not found at {vbox_path}. Install VirtualBox or "
            f"pass --vbox-path.",
            file=sys.stderr,
        )
        sys.exit(2)
    except VBoxManageError as exc:
        print(f"FAIL: {exc}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
