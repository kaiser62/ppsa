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
# Matches the proven manual recipe in .claude/skills/ppsa-installer-test/
# SKILL.md section "1. Create VM" (--basefolder "H:\dev\palimage\vms") --
# C: is repo/OS-only per CLAUDE.md's disk usage policy.
DEFAULT_VM_BASEFOLDER = r"H:\dev\palimage\vms"
WINDOWS_VBOXMANAGE_FALLBACK = r"C:\Program Files\Oracle\VirtualBox\VBoxManage.exe"

# NET-01 safety check constants
WG_HUB_URL = "http://pleaseee.eu.org:51831"
WG_IDENTITY_PEER_NAME = "ppsa-server"
WG_HANDSHAKE_STALE_SECONDS = 3600  # 1 hour, per installer-test skill's abort threshold

# VM-03 completion-poll constants. SSH_USER/DEFAULT_PASSWORD match the
# appliance's documented first-boot defaults (ppsa/ppsa), identical to the
# existing scripts/ppsa-smoke-test.py precedent.
SSH_USER = "ppsa"
DEFAULT_PASSWORD = "ppsa"
DEFAULT_SSH_PORT = 22
INSTALL_COMPLETE_MARKER = "/opt/ppsa/.installed"
POLL_INTERVAL_SECONDS = 15
SSH_STALE_THRESHOLD_SECONDS = 300  # 5 min continuous unreachability, Pitfall 2 heartbeat guidance

# BOOT-02 heartbeat constants. HEARTBEAT_FILE matches Plan 07-01's
# mark_step_activity() contract in scripts/install.sh (world-readable Unix
# epoch integer, updated during Step 3's Docker pull/up loops).
HEARTBEAT_FILE = "/run/ppsa-install.activity"
HEARTBEAT_STALE_THRESHOLD_SECONDS = 300  # 5 min grace period, matches SSH_STALE_THRESHOLD_SECONDS

# Phase 8 (TEST-01/TEST-02): smoke-test subprocess integration. SMOKE_TEST_SCRIPT
# is a fixed sibling-script path (D-03 -- no CLI flag for its own location).
# DEFAULT_SMOKE_TEST_LOG_FILE is a fixed, overwritten-each-run relative path
# (D-02), consistent with ppsa-smoke-test.py's own DEFAULT_LOG_DIR convention
# of a plain relative default rather than an absolute system path.
SMOKE_TEST_SCRIPT = Path(__file__).parent / "ppsa-smoke-test.py"
DEFAULT_SMOKE_TEST_LOG_FILE = "ppsa-installer-e2e-smoke.log"

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
# VM-03: minimal SSH transport (ported from scripts/ppsa-smoke-test.py's
# SshTransport -- copied/adapted rather than imported across scripts, so this
# file stays runnable standalone with no cross-script dependency).
# ---------------------------------------------------------------------------
class SshRunner:
    """Auto-detecting SSH transport: plink (Windows/PuTTY) or ssh (Linux/
    macOS/OpenSSH). Same exec(remote_cmd, timeout) -> (stdout, stderr,
    exit_code) contract as ppsa-smoke-test.py's SshTransport.

    Host-key handling (T-06-05, spoofing threat -- accepted for a disposable,
    freshly-created test VM whose identity is not yet known): ssh uses
    StrictHostKeyChecking=accept-new; plink accepts-on-first-connect via a
    piped 'y' and pins the resulting SHA256 fingerprint for subsequent calls.
    """

    def __init__(self, ssh_target, password=None, port=DEFAULT_SSH_PORT, verbose=False):
        self.ssh_target = ssh_target
        self.password = password or DEFAULT_PASSWORD
        self.port = port or DEFAULT_SSH_PORT
        self.verbose = verbose
        self.host_key = None
        self.use_plink = sys.platform == "win32"

    def _build_plink_cmd(self, remote_cmd, batch=True):
        cmd = ["plink", "-ssh"]
        if batch:
            cmd.append("-batch")
        if self.host_key:
            cmd.extend(["-hostkey", self.host_key])
        cmd.extend(["-pw", self.password])
        cmd.extend(["-P", str(self.port), f"{SSH_USER}@{self.ssh_target}", remote_cmd])
        return cmd

    def _build_ssh_cmd(self, remote_cmd):
        return [
            "ssh",
            "-o", "BatchMode=no",
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "ConnectTimeout=10",
            "-p", str(self.port),
            f"{SSH_USER}@{self.ssh_target}",
            remote_cmd,
        ]

    def accept_host_key(self):
        """Accept the remote host key on first connection (plink only; ssh's
        accept-new handles this transparently)."""
        if not self.use_plink:
            return
        cmd = self._build_plink_cmd("hostname -s", batch=False)
        try:
            p = subprocess.run(cmd, input="y\n", capture_output=True, text=True, timeout=15)
        except (subprocess.TimeoutExpired, FileNotFoundError, OSError):
            return
        combined = p.stdout + "\n" + p.stderr
        match = re.search(r"(SHA256:[A-Za-z0-9+/=]{10,})", combined)
        if match:
            self.host_key = match.group(1)

    def exec(self, remote_cmd, timeout=15):
        """Run a command on the remote VM. Returns (stdout, stderr,
        exit_code). On timeout, exit_code is -1 and stderr describes it --
        this is a connection-level failure, distinct from a successful SSH
        call whose remote command simply exited non-zero."""
        cmd = (
            self._build_plink_cmd(remote_cmd, batch=self.host_key is not None)
            if self.use_plink
            else self._build_ssh_cmd(remote_cmd)
        )
        if self.verbose:
            print(f"[SSH] $ {remote_cmd}", file=sys.stderr)
        try:
            p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
            return p.stdout, p.stderr, p.returncode
        except subprocess.TimeoutExpired:
            return "", f"timed out after {timeout}s", -1
        except FileNotFoundError:
            tool = "plink" if self.use_plink else "ssh"
            return "", f"{tool} not found on PATH", -1
        except OSError as exc:
            return "", str(exc), -1


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
        basefolder=DEFAULT_VM_BASEFOLDER,
        keep_vm=False,
        timeout_seconds=DEFAULT_TIMEOUT_SECONDS,
        verbose=False,
        ssh_target=None,
        ssh_password=None,
        skip_smoke_test=False,
        log_file=DEFAULT_SMOKE_TEST_LOG_FILE,
    ):
        self.iso_path = Path(iso_path).resolve()
        self.vm_name = vm_name
        self.vbox_path = vbox_path
        self.memory_mb = memory_mb
        self.cpus = cpus
        self.disk_size_mb = disk_size_mb
        self.bridge_adapter = bridge_adapter
        self.basefolder = basefolder
        self.keep_vm = keep_vm
        self.timeout_seconds = timeout_seconds
        self.verbose = verbose
        self.ssh_target = ssh_target
        self.ssh_password = ssh_password
        self.skip_smoke_test = skip_smoke_test
        self.log_file = log_file
        self._mac_address = None
        # VM-03: set on wait_for_install_complete() timeout, distinguishing
        # "SSH never reachable" from "reachable but not yet installed" (NET-01
        # must_have on actionable/distinguishable timeout reporting).
        self.last_failure_reason = None

        # VM working directory: rooted at self.basefolder (default matches
        # the repo's H:-drive scratch convention; C: is repo/OS-only per
        # CLAUDE.md's disk usage policy) rather than the VirtualBox default
        # C:\Users\<user>\VirtualBox VMs\ location.
        self.vm_dir = Path(self.basefolder) / self.vm_name

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
        self._run(
            [
                "createvm",
                "--name",
                self.vm_name,
                "--ostype",
                "Debian_64",
                "--register",
                "--basefolder",
                str(self.basefolder),
            ]
        )

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

    def wait_for_install_complete(self, ssh_target, overall_timeout_seconds):
        """Poll /opt/ppsa/.installed over SSH until the install completes or
        the bounded overall timeout elapses (VM-03).

        Also polls Plan 07-01's heartbeat file (HEARTBEAT_FILE, BOOT-02) on
        each iteration so a slow-but-progressing Docker pull is not
        misreported as a hang. Distinguishes THREE distinct timeout reasons
        (NET-01's actionable-timeout-reporting must_have), stored in
        self.last_failure_reason:
          - SSH never reachable at all during the whole run (host/tunnel/
            NetBird enrollment issue)
          - SSH became reachable, the .installed marker never appeared, but
            the heartbeat (if any) stayed fresh -- installer is legitimately
            just slow, not hung
          - SSH became reachable, the .installed marker never appeared, AND
            the heartbeat has gone stale past HEARTBEAT_STALE_THRESHOLD_SECONDS
            -- SUSPECTED HANG

        Returns (True, elapsed_seconds) on success, (False, elapsed_seconds)
        on timeout. Never raises -- SSH connection failures are treated as
        "not yet reachable, keep polling" (Pitfall 7), not aborts.
        """
        runner = SshRunner(ssh_target, password=self.ssh_password, verbose=self.verbose)
        runner.accept_host_key()

        start = time.time()
        last_successful_contact = None  # timestamp of last SSH command that actually ran
        last_heartbeat_epoch = None  # parsed Unix epoch from HEARTBEAT_FILE, or None if never observed

        while True:
            elapsed = time.time() - start
            print(
                f"[ppsa-installer-e2e] Polling {ssh_target} for "
                f"{INSTALL_COMPLETE_MARKER} ... ({elapsed:.0f}s / "
                f"{overall_timeout_seconds}s elapsed)"
            )

            stdout, stderr, exit_code = runner.exec(
                f"test -f {INSTALL_COMPLETE_MARKER} && echo INSTALLED", timeout=15
            )

            # exit_code == -1 is this script's SshRunner convention for a
            # connection-level failure (timeout, plink/ssh not found, OSError)
            # -- distinct from a successful SSH call whose remote `test`
            # simply evaluated false (exit_code 1, empty stdout).
            connection_failed = exit_code == -1
            if not connection_failed:
                last_successful_contact = time.time()
                if "INSTALLED" in stdout:
                    elapsed = time.time() - start
                    print(
                        f"[ppsa-installer-e2e] {INSTALL_COMPLETE_MARKER} found "
                        f"after {elapsed:.0f}s -- install complete."
                    )
                    return True, elapsed
            else:
                print(
                    f"WARNING: SSH not yet reachable at {ssh_target}, "
                    f"retrying... ({stderr.strip()})",
                    file=sys.stderr,
                )

            # BOOT-02: poll the heartbeat file alongside the marker check.
            # Never crashes the loop -- unreadable/absent/garbage content all
            # fall back to "no heartbeat signal available" (Pitfall 3/T-07-07).
            hb_stdout, _hb_stderr, hb_exit_code = runner.exec(
                f"cat {HEARTBEAT_FILE} 2>/dev/null", timeout=10
            )
            if hb_exit_code == 0 and hb_stdout.strip():
                try:
                    last_heartbeat_epoch = int(hb_stdout.strip())
                except ValueError:
                    pass  # garbage content -- keep previous last_heartbeat_epoch, don't crash

            if last_heartbeat_epoch is not None:
                heartbeat_age = time.time() - last_heartbeat_epoch
                print(f"[ppsa-installer-e2e]   heartbeat: {heartbeat_age:.0f}s ago")
            else:
                print("[ppsa-installer-e2e]   heartbeat: none observed yet")

            elapsed = time.time() - start
            if elapsed >= overall_timeout_seconds:
                heartbeat_stale = (
                    last_heartbeat_epoch is not None
                    and (time.time() - last_heartbeat_epoch) > HEARTBEAT_STALE_THRESHOLD_SECONDS
                )
                if last_successful_contact is None:
                    self.last_failure_reason = (
                        f"SSH never became reachable at {ssh_target} within "
                        f"{overall_timeout_seconds}s (host/tunnel/NetBird "
                        f"enrollment likely never came up)"
                    )
                elif heartbeat_stale:
                    stale_for = time.time() - last_heartbeat_epoch
                    self.last_failure_reason = (
                        f"SUSPECTED HANG: {INSTALL_COMPLETE_MARKER} never "
                        f"appeared within {overall_timeout_seconds}s AND "
                        f"{HEARTBEAT_FILE} has been stale for {stale_for:.0f}s "
                        f"(> {HEARTBEAT_STALE_THRESHOLD_SECONDS}s threshold) -- "
                        f"installer appears genuinely stalled, not just slow"
                    )
                else:
                    stale_for = time.time() - last_successful_contact
                    self.last_failure_reason = (
                        f"SSH reached {ssh_target} but {INSTALL_COMPLETE_MARKER} "
                        f"never appeared within {overall_timeout_seconds}s "
                        f"(last successful SSH contact {stale_for:.0f}s ago -- "
                        f"installer itself may be hung or failed)"
                    )
                print(f"FAIL: {self.last_failure_reason}", file=sys.stderr)
                return False, elapsed

            # Heartbeat-style staleness check (Pitfall 2, ported to this
            # simpler polling model): if SSH has been unreachable for more
            # than SSH_STALE_THRESHOLD_SECONDS *and* the overall timeout has
            # also elapsed, the loop above already returns. This branch just
            # keeps the "last successful contact" distinction fresh in logs.
            if (
                last_successful_contact is not None
                and (time.time() - last_successful_contact) > SSH_STALE_THRESHOLD_SECONDS
            ):
                print(
                    f"WARNING: no successful SSH contact in over "
                    f"{SSH_STALE_THRESHOLD_SECONDS}s -- still within overall "
                    f"timeout, continuing to poll",
                    file=sys.stderr,
                )

            time.sleep(POLL_INTERVAL_SECONDS)

    def verify_boot_chain(self, ssh_target):
        """Classify the post-install boot path as signed shim/GRUB or
        unsigned grub-mkstandalone fallback (BOOT-01), by SSHing into the
        now-installed guest and querying dmesg then /proc/cmdline.

        Reuses the same SshRunner construction already established in
        wait_for_install_complete() -- no second SSH transport.

        Returns a (status, reason) tuple where status is one of "PASS",
        "WARN", or "SKIP" (never "FAIL" -- per Pitfall 4, an unsigned
        fallback is a documented, sometimes-intentional build posture to be
        surfaced and judged by the release process, not an automatic hard
        failure of this test run). Never raises -- SSH connection failures
        classify as SKIP.
        """
        runner = SshRunner(ssh_target, password=self.ssh_password, verbose=self.verbose)
        runner.accept_host_key()

        stdout, stderr, exit_code = runner.exec(
            "dmesg | grep -iE 'secure.boot|shim' | head -5", timeout=10
        )
        if exit_code == -1:
            return (
                "SKIP",
                f"Could not verify boot chain: SSH unreachable ({stderr.strip()})",
            )
        if exit_code == 0 and stdout.strip():
            return "PASS", "Signed Shim/GRUB (Secure Boot chain markers found in dmesg)"

        stdout, stderr, exit_code = runner.exec("cat /proc/cmdline", timeout=10)
        if exit_code == -1:
            return (
                "SKIP",
                f"Could not verify boot chain: SSH unreachable ({stderr.strip()})",
            )
        if exit_code == 0 and stdout.strip():
            lowered = stdout.lower()
            if "efi" in lowered or "secure" in lowered:
                return "PASS", "EFI/Secure Boot keyword found in /proc/cmdline"

        return (
            "WARN",
            "No signed shim/GRUB markers found via dmesg or /proc/cmdline -- "
            "likely Unsigned grub-mkstandalone fallback (expected/acceptable "
            "only when Secure Boot is off; see CLAUDE.md Boot chain section)",
        )

    def run_smoke_test(self, ssh_target):
        """Invoke scripts/ppsa-smoke-test.py as a subprocess (TEST-01) against
        the now-installed guest, mirroring the run_vboxmanage()/CommandResult
        subprocess-wrapper pattern already used elsewhere in this file (D-01
        -- never import SmokeTestRunner directly).

        All raw subprocess stdout/stderr is written to self.log_file (opened
        in "w" mode, overwritten every call per D-02) -- this method never
        prints that raw output to stdout/stderr itself, keeping SSH/check-
        detail noise out of this script's own console output.

        Returns a (status, reason) tuple, status one of "PASS" or "FAIL".
        Never raises -- subprocess.TimeoutExpired and OSError (including
        FileNotFoundError) are both caught so a smoke-test invocation
        failure never crashes the whole e2e run.
        """
        cmd = [
            sys.executable,
            str(SMOKE_TEST_SCRIPT),
            ssh_target,
            "--ssh-password",
            self.ssh_password or DEFAULT_PASSWORD,
        ]
        try:
            result = subprocess.run(cmd, capture_output=True, text=True, timeout=600)
        except subprocess.TimeoutExpired as exc:
            return "FAIL", f"could not invoke {SMOKE_TEST_SCRIPT.name}: {exc}"
        except OSError as exc:
            return "FAIL", f"could not invoke {SMOKE_TEST_SCRIPT.name}: {exc}"

        with open(self.log_file, "w") as f:
            f.write(f"=== {SMOKE_TEST_SCRIPT.name} raw subprocess output ===\n")
            f.write("--- stdout ---\n")
            f.write(result.stdout)
            f.write("\n--- stderr ---\n")
            f.write(result.stderr)

        if result.returncode == 0:
            return "PASS", f"see {self.log_file} for details"
        if result.returncode == 1:
            return (
                "FAIL",
                f"smoke test reported failures; see {self.log_file} for details",
            )
        if result.returncode == 2:
            return (
                "FAIL",
                f"smoke test hit a setup/prerequisite error (exit 2); see "
                f"{self.log_file} for details",
            )
        return (
            "FAIL",
            f"unexpected smoke-test exit code {result.returncode}; see "
            f"{self.log_file} for details",
        )

    def run(self):
        """Orchestrate the full pipeline: create -> attach -> boot -> drive
        TUI -> poll for install completion -> summary.

        check_wg_hub_identity_safe() already ran in main() before this method
        is ever called -- run() starts from VM creation, not the safety
        check. Each step is wrapped so the FIRST failure stops the pipeline
        immediately (remaining steps are skipped) and falls straight through
        to the summary + cleanup (cleanup itself is handled by main()'s
        atexit-registered destroy_vm(), not by this method).

        Boot-chain verification (BOOT-01) runs after a successful
        completion-poll, and heartbeat-aware hang detection (BOOT-02) is
        folded into wait_for_install_complete() itself -- both implemented
        in this phase (07-02).
        """
        steps = [
            ("create_vm", self.create_vm),
            ("attach_iso", self.attach_iso),
            ("boot_vm", self.boot_vm),
            ("drive_installer_tui", self.drive_installer_tui),
        ]
        results = []

        for step_name, step_fn in steps:
            try:
                step_fn()
                results.append((step_name, "PASS"))
            except Exception as exc:  # noqa: BLE001 -- record and stop, don't crash the run
                results.append((step_name, f"FAIL: {exc}"))
                break
        else:
            # All lifecycle/TUI steps passed -- now poll for install
            # completion, only if an --ssh-target was supplied.
            if not self.ssh_target:
                results.append(
                    (
                        "wait_for_install_complete",
                        "FAIL: no --ssh-target supplied; cannot poll for "
                        "install completion",
                    )
                )
            else:
                success, elapsed = self.wait_for_install_complete(
                    self.ssh_target, self.timeout_seconds
                )
                if success:
                    results.append(
                        ("wait_for_install_complete", f"PASS ({elapsed:.0f}s)")
                    )
                    boot_chain_status, boot_chain_reason = self.verify_boot_chain(self.ssh_target)
                    results.append(
                        ("verify_boot_chain", f"{boot_chain_status}: {boot_chain_reason}")
                    )

                    # TEST-01/TEST-02: smoke-test stage runs regardless of
                    # verify_boot_chain()'s own PASS/WARN/SKIP status -- per
                    # Phase 7's precedent, WARN/SKIP boot-chain results are
                    # informational, not blocking, so the box may still be
                    # fully functional even on an unsigned-fallback boot.
                    if self.skip_smoke_test:
                        results.append(
                            ("smoke_test", "SKIP: --skip-smoke-test set")
                        )
                    else:
                        status, reason = self.run_smoke_test(self.ssh_target)
                        results.append(("smoke_test", f"{status}: {reason}"))
                else:
                    results.append(
                        (
                            "wait_for_install_complete",
                            f"FAIL: {self.last_failure_reason}",
                        )
                    )

        # overall_pass keys strictly off any FAIL-prefixed status -- PASS,
        # WARN (e.g. unsigned boot-chain fallback), and SKIP (e.g. boot-chain
        # check itself unreachable after install already succeeded) are all
        # informational, not blocking. Backward-compatible with the existing
        # FAIL-producing steps (create_vm/attach_iso/boot_vm/
        # drive_installer_tui/wait_for_install_complete), which already only
        # ever emit "FAIL: {reason}" strings.
        overall_pass = all(not status.startswith("FAIL") for _, status in results)

        summary_word = "SUCCESS" if overall_pass else "FAILURE"
        print(f"[PPSA E2E Installer Test] {summary_word}: {self.iso_path.name}")
        for step_name, status in results:
            print(f"  {step_name}: {status}")

        # TEST-02: one-line summary naming the first failing stage on FAIL,
        # so a tester can diagnose which of install/boot-verify/smoke-test
        # broke without needing a re-run.
        if overall_pass:
            print(
                "[SUMMARY] PASS -- install, boot-verify, and smoke-test all "
                "succeeded"
            )
        else:
            first_fail = next(
                (
                    (step_name, status)
                    for step_name, status in results
                    if status.startswith("FAIL")
                ),
                None,
            )
            if first_fail is not None:
                step_name, status = first_fail
                print(
                    f"[SUMMARY] FAIL -- {step_name} failed: "
                    f"{status[len('FAIL: '):]}"
                )
            else:
                print("[SUMMARY] FAIL -- see per-step results above for details")

        return overall_pass, results


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
        "--basefolder",
        default=DEFAULT_VM_BASEFOLDER,
        help="Directory where VirtualBox registers the VM and stores its disk "
        f"(default: {DEFAULT_VM_BASEFOLDER}, matching the repo's H:-drive scratch "
        "convention; C: is repo/OS-only per CLAUDE.md's disk usage policy)",
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
    parser.add_argument(
        "--ssh-target",
        default=None,
        help="Address to poll for install completion over SSH (NetBird DNS label, "
        "overlay IP, or LAN IP). No default -- discovering the VM's address is out "
        "of scope for this phase; the caller supplies an already-reachable address.",
    )
    parser.add_argument(
        "--ssh-password",
        default=None,
        help=f"SSH password for the {SSH_USER} user (default: {DEFAULT_PASSWORD}, the "
        "documented first-boot default)",
    )
    parser.add_argument(
        "--skip-smoke-test",
        action="store_true",
        help="Stop after boot-verify; do not invoke scripts/ppsa-smoke-test.py "
        "(escape hatch for debugging install/boot in isolation)",
    )
    parser.add_argument(
        "--log-file",
        default=DEFAULT_SMOKE_TEST_LOG_FILE,
        help=f"Path to write raw smoke-test subprocess output to (default: "
        f"{DEFAULT_SMOKE_TEST_LOG_FILE}, overwritten each run)",
    )
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
        basefolder=args.basefolder,
        keep_vm=args.keep_vm,
        timeout_seconds=args.timeout_seconds,
        verbose=args.verbose,
        ssh_target=args.ssh_target,
        ssh_password=args.ssh_password,
        skip_smoke_test=args.skip_smoke_test,
        log_file=args.log_file,
    )

    if not args.keep_vm:
        atexit.register(tester.destroy_vm)

    try:
        overall_pass, _results = tester.run()
    except FileNotFoundError:
        print(
            f"ERROR: VBoxManage not found at {vbox_path}. Install VirtualBox or "
            f"pass --vbox-path.",
            file=sys.stderr,
        )
        sys.exit(2)

    sys.exit(0 if overall_pass else 1)


if __name__ == "__main__":
    main()
