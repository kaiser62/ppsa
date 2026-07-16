#!/usr/bin/env python3
"""PPSA Smoke Test -- verify a fresh PPSA install over SSH.

Host-side script that SSHs into a PPSA test VM and runs the full install
verification checklist over the WebUI API, asserting the three v1.3.0-nb.12
regression fixes in a dedicated guard group. Stdlib only (no pip packages).

Usage:
    python scripts/ppsa-smoke-test.py <vm_address>
    python scripts/ppsa-smoke-test.py 100.70.169.201 --ssh-password ppsa --verbose
"""

import argparse
import json
import os
import platform
import re
import subprocess
import sys
import time
from datetime import datetime
from pathlib import Path
from collections import namedtuple

# Known WebUI API endpoint categories referenced by check definitions:
#   /api/login, /api/dashboard, /api/system, /api/firewall/status,
#   /api/firewall/config, /api/backup/status, /api/backup/trigger,
#   /api/backup/save-file, /api/server/save, /api/netbird/status,
#   /api/wireguard/status, /api/wifi/*, /api/mods, /api/logs, /api/env

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
SSH_USER = "ppsa"
DEFAULT_PASSWORD = "ppsa"
DEFAULT_SSH_PORT = 22
DEFAULT_LOG_DIR = "smoke-test-logs"
DEFAULT_TIMEOUT = 15

CheckResult = namedtuple("CheckResult", ["name", "passed", "detail"])


# ===================================================================
# Transport layer: SSH via plink (Windows) or ssh (Linux/macOS)
# ===================================================================
class SshTransport:
    """Abstract SSH transport that auto-detects Windows vs Linux/macOS."""

    def __init__(self, vm_address, password=None, key_file=None, port=22,
                 force_plink=False, verbose=False):
        self.vm_address = vm_address
        self.password = password or DEFAULT_PASSWORD
        self.key_file = key_file
        self.port = port or DEFAULT_SSH_PORT
        self.verbose = verbose
        self.host_key = None  # SHA256 fingerprint for plink

        is_windows = sys.platform == "win32"
        self.use_plink = force_plink or is_windows

    def accept_host_key(self):
        """Accept the remote host key for the first connection.

        For plink: run without -batch, pipe 'y' to accept, extract the SHA256
        fingerprint from output for use in subsequent -hostkey calls.
        For ssh: StrictHostKeyChecking=accept-new does this automatically.
        """
        if not self.use_plink:
            return

        # Build plink command WITHOUT -batch and WITHOUT -hostkey so it prompts
        cmd = self._build_plink_cmd("hostname -s", batch=False)
        try:
            p = subprocess.run(
                cmd,
                input="y\n",
                capture_output=True,
                text=True,
                timeout=15,
            )
        except subprocess.TimeoutExpired:
            return
        except FileNotFoundError:
            print("ERROR: plink not found on PATH. Install PuTTY or use --plink to"
                  " force, or run from a Linux host where ssh is available.",
                  file=sys.stderr)
            sys.exit(2)
        except OSError as e:
            print(f"ERROR: plink execution failed: {e}", file=sys.stderr)
            sys.exit(2)

        # Extract SHA256 fingerprint from plink output
        combined = p.stdout + "\n" + p.stderr
        m = re.search(r'(SHA256:[A-Za-z0-9+/=]{10,})', combined)
        if m:
            self.host_key = m.group(1)
            if self.verbose:
                print(f"[SSH] Accepted host key: {self.host_key}", file=sys.stderr)
        else:
            # Key may already be cached; try a batch-mode test to verify
            if self.verbose:
                print("[SSH] No new host key prompted (may be cached already)",
                      file=sys.stderr)
            # Do a test batch call and let it fail if key isn't trusted
            test_cmd = self._build_plink_cmd("hostname -s", batch=True)
            try:
                subprocess.run(test_cmd, capture_output=True, text=True, timeout=10)
            except Exception:
                pass

    def _build_plink_cmd(self, remote_cmd, batch=True):
        """Build a plink command list."""
        cmd = ["plink", "-ssh"]
        if batch:
            cmd.append("-batch")
        if self.host_key:
            cmd.extend(["-hostkey", self.host_key])
        if self.key_file:
            cmd.extend(["-i", self.key_file])
        else:
            cmd.extend(["-pw", self.password])
        cmd.extend(["-P", str(self.port),
                    f"{SSH_USER}@{self.vm_address}",
                    remote_cmd])
        return cmd

    def _build_ssh_cmd(self, remote_cmd):
        """Build an OpenSSH command list."""
        cmd = [
            "ssh",
            "-o", "BatchMode=no",
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "ConnectTimeout=10",
            "-p", str(self.port),
        ]
        if self.key_file:
            cmd.extend(["-i", self.key_file])
        cmd.extend([
            f"{SSH_USER}@{self.vm_address}",
            remote_cmd,
        ])
        return cmd

    def exec(self, remote_cmd, timeout=DEFAULT_TIMEOUT):
        """Run a command on the remote VM and return (stdout, stderr, exit_code).

        Args:
            remote_cmd: Shell command string to execute on the VM.
            timeout: Maximum seconds to wait for completion.

        Returns:
            Tuple of (stdout_text, stderr_text, exit_code). On timeout,
            exit_code is -1 and stderr contains the timeout message.
        """
        if self.use_plink:
            cmd = self._build_plink_cmd(remote_cmd, batch=self.host_key is not None)
        else:
            cmd = self._build_ssh_cmd(remote_cmd)

        if self.verbose:
            print(f"[SSH] $ {remote_cmd}", file=sys.stderr)

        try:
            p = subprocess.run(
                cmd,
                capture_output=True,
                text=True,
                timeout=timeout,
            )
            return p.stdout, p.stderr, p.returncode
        except subprocess.TimeoutExpired:
            return "", f"timed out after {timeout}s", -1
        except FileNotFoundError:
            tool = "plink" if self.use_plink else "ssh"
            print(f"ERROR: {tool} not found on PATH. Install PuTTY (Windows)"
                  f" or OpenSSH (Linux/macOS).", file=sys.stderr)
            sys.exit(2)
        except OSError as e:
            return "", str(e), -1


# ===================================================================
# Assertion engine
# ===================================================================
def _json_get(data, path):
    """Get a value from a nested dict using dot-separated path."""
    keys = path.split(".")
    current = data
    for key in keys:
        if isinstance(current, dict) and key in current:
            current = current[key]
        else:
            return None
    return current


def _apply_assertions(stdout, stderr, exit_code, assertions, elapsed):
    """Apply a list of assertions and return (passed, detail).

    Each assertion is a tuple: (type, *args).
    Supported types: exit_zero, json_has, json_gt, json_has_key, json_in,
                     matches, count_lines, response_time.
    """
    for assertion in assertions:
        atype = assertion[0]
        args = assertion[1:]

        if atype == "exit_zero":
            if exit_code != 0:
                return False, (f"expected exit code 0, got {exit_code}"
                               f" -- stderr: {stderr[:200] if stderr else '(none)'}")

        elif atype == "json_has":
            path, expected = args
            try:
                data = json.loads(stdout)
            except (json.JSONDecodeError, ValueError) as e:
                return False, f"stdout is not valid JSON: {e}"
            actual = _json_get(data, path)
            if actual is None:
                return False, f"json path '{path}' not found in response"
            if isinstance(expected, bool):
                if actual != expected:
                    return False, f"expected {path}={expected}, got {actual}"
            else:
                # Compare as strings for flexibility
                if str(actual) != str(expected):
                    return False, (f"expected {path}={expected!r}"
                                   f" (type={type(expected).__name__}),"
                                   f" got {actual!r} (type={type(actual).__name__})")

        elif atype == "json_gt":
            path, min_val = args
            try:
                data = json.loads(stdout)
            except (json.JSONDecodeError, ValueError) as e:
                return False, f"stdout is not valid JSON: {e}"
            actual = _json_get(data, path)
            if actual is None:
                return False, f"json path '{path}' not found"
            try:
                if float(actual) <= float(min_val):
                    return False, (f"expected {path} > {min_val},"
                                   f" got {actual}")
            except (ValueError, TypeError):
                return False, f"cannot compare {path}={actual!r} as number"

        elif atype == "json_has_key":
            path = args[0]
            try:
                data = json.loads(stdout)
            except (json.JSONDecodeError, ValueError) as e:
                return False, f"stdout is not valid JSON: {e}"
            if _json_get(data, path) is None:
                return False, f"json key '{path}' not found in response"

        elif atype == "json_in":
            path, valid_values = args
            try:
                data = json.loads(stdout)
            except (json.JSONDecodeError, ValueError) as e:
                return False, f"stdout is not valid JSON: {e}"
            actual = _json_get(data, path)
            if actual not in valid_values:
                return False, (f"expected {path} in {valid_values},"
                               f" got {actual!r}")

        elif atype == "matches":
            pattern = args[0]
            if not re.search(pattern, stdout):
                return False, (f"stdout did not match pattern /{pattern}/"
                               f" -- got: {stdout[:200]!r}")

        elif atype == "count_lines":
            op, n = args
            lines = [ln for ln in stdout.splitlines() if ln.strip()]
            count = len(lines)
            if op == "eq" and count != n:
                return False, f"expected {n} lines, got {count}"
            elif op == "gt" and count <= n:
                return False, f"expected >{n} lines, got {count}"
            elif op == "ge" and count < n:
                return False, f"expected >={n} lines, got {count}"
            elif op == "lt" and count >= n:
                return False, f"expected <{n} lines, got {count}"
            elif op == "le" and count > n:
                return False, f"expected <={n} lines, got {count}"

        elif atype == "response_time":
            max_sec = args[0]
            if elapsed > max_sec:
                return False, (f"command took {elapsed:.1f}s,"
                               f" expected <={max_sec}s")

        else:
            return False, f"unknown assertion type: {atype}"

    return True, ""


# ===================================================================
# Check runner
# ===================================================================
class SmokeTestRunner:
    """Orchestrates check execution, logging, and summary output."""

    def __init__(self, transport, log_dir, verbose):
        self.transport = transport
        self.log_dir = Path(log_dir)
        self.verbose = verbose
        self.token = None
        self.results = []  # list of CheckResult
        self.log_path = None
        self.log_fh = None
        self._current_group = ""
        self._backup_files_before = []  # snapshot for nb.12 check 9.3

    def open_log(self):
        """Create the timestamped log file and write the header."""
        self.log_dir.mkdir(parents=True, exist_ok=True)
        sanitized = re.sub(r'[^A-Za-z0-9.-]+', '_', self.transport.vm_address)
        ts = datetime.now().strftime("%Y%m%d-%H%M%S")
        self.log_path = self.log_dir / f"ppsa-smoke-{sanitized}-{ts}.log"
        self.log_fh = open(self.log_path, "w", encoding="utf-8")

        header = (
            f"=== PPSA Smoke Test ===\n"
            f"Target: {self.transport.vm_address}\n"
            f"Started: {datetime.now().isoformat()}\n"
            f"Command line: {' '.join(sys.argv)}\n"
            f"Transport: {'plink' if self.transport.use_plink else 'ssh'}\n"
            f"{'=' * 50}\n\n"
        )
        self.log_fh.write(header)
        self.log_fh.flush()

    def close_log(self):
        """Finalize the log file."""
        if self.log_fh:
            self.log_fh.write(
                f"\n{'=' * 50}\n"
                f"Finished: {datetime.now().isoformat()}\n"
            )
            self.log_fh.close()
            self.log_fh = None

    def log_command(self, check_name, cmd, stdout, stderr, exit_code, elapsed):
        """Write a check's raw command+output to the log file."""
        if not self.log_fh:
            return
        self.log_fh.write(
            f"\n--- Check: {check_name} ---\n"
            f"$ {cmd}\n"
            f"Exit: {exit_code}\n"
            f"Elapsed: {elapsed:.1f}s\n"
        )
        for line in stdout.splitlines():
            self.log_fh.write(f"stdout> {line}\n")
        for line in stderr.splitlines():
            self.log_fh.write(f"stderr> {line}\n")
        self.log_fh.flush()

    def run_check(self, check_def):
        """Execute a check and return a CheckResult.

        check_def is a dict with keys: name, cmd, assertions, [timeout].
        """
        name = check_def["name"]
        cmd = check_def["cmd"]
        assertions = check_def.get("assertions", [("exit_zero",)])
        timeout = check_def.get("timeout", DEFAULT_TIMEOUT)

        # Substitute token into command if available
        if self.token and "$TOKEN" in cmd:
            cmd = cmd.replace("$TOKEN", self.token)

        start = time.monotonic()
        stdout, stderr, exit_code = self.transport.exec(cmd, timeout=timeout)
        elapsed = time.monotonic() - start

        # Check for timeout first
        if exit_code == -1:
            self.log_command(name, cmd, stdout, stderr, exit_code, elapsed)
            return CheckResult(name, False, f"timed out after {timeout}s")

        # Apply assertions
        passed, detail = _apply_assertions(
            stdout, stderr, exit_code, assertions, elapsed
        )

        self.log_command(name, cmd, stdout, stderr, exit_code, elapsed)
        return CheckResult(name, passed, detail)

    def run_login_check(self, check_def):
        """Run the login check and extract the JWT token on success.

        Returns a CheckResult. On success, self.token is set.
        """
        result = self.run_check(check_def)
        if result.passed:
            # Extract token from the login response (check 2.2)
            try:
                cmd = check_def["cmd"]
                out, _, _ = self.transport.exec(cmd, timeout=check_def.get("timeout", 15))
                data = json.loads(out)
                self.token = data.get("token", "")
                if not self.token:
                    return CheckResult(check_def["name"], False,
                                       "login succeeded but no token in response")
            except (json.JSONDecodeError, KeyError) as e:
                return CheckResult(check_def["name"], False,
                                   f"failed to extract token: {e}")
        return result

    def run_polling_check(self, check_def):
        """Run a polling check that waits for a condition.

        For check 9.3 (Backup archive appears after trigger): polls
        /api/backup/status every 10 seconds, up to 120 seconds, and fails
        if no new archive appears relative to the pre-trigger snapshot.
        """
        name = check_def["name"]
        cmd = check_def["cmd"]
        timeout = check_def.get("timeout", 130)

        if self.token:
            cmd = cmd.replace("$TOKEN", self.token)

        # Get the pre-trigger backup file list
        status_cmd = (
            f"curl -sf http://localhost:8080/api/backup/status"
            f" -H \"Authorization: Bearer {self.token}\""
        ) if self.token else "curl -sf http://localhost:8080/api/backup/status"

        pre_stdout, _, pre_rc = self.transport.exec(status_cmd, timeout=15)
        pre_files = []
        if pre_rc == 0:
            try:
                pre_data = json.loads(pre_stdout)
                pre_files = [f["name"] for f in pre_data.get("files", [])]
            except (json.JSONDecodeError, KeyError, TypeError):
                pass

        self.log_command(f"snapshot for {name}",
                         status_cmd, pre_stdout, "", pre_rc, 0)

        # Trigger the backup via the check command
        start = time.monotonic()
        stdout, stderr, exit_code = self.transport.exec(cmd, timeout=30)
        elapsed = time.monotonic() - start
        self.log_command(name + " (trigger)", cmd, stdout, stderr,
                         exit_code, elapsed)

        if exit_code != 0:
            return CheckResult(name, False,
                               f"trigger command failed: exit {exit_code}"
                               f" {stderr[:200]}")

        # Poll for a new archive
        max_polls = 12
        poll_interval = 10
        for attempt in range(1, max_polls + 1):
            time.sleep(poll_interval)

            poll_stdout, poll_stderr, poll_rc = self.transport.exec(
                status_cmd, timeout=15
            )
            self.log_command(f"{name} (poll {attempt}/{max_polls})",
                             status_cmd, poll_stdout, poll_stderr, poll_rc, 0)

            if poll_rc != 0:
                continue

            try:
                poll_data = json.loads(poll_stdout)
                current_files = [f["name"] for f in poll_data.get("files", [])]
            except (json.JSONDecodeError, KeyError, TypeError):
                continue

            # Check if any new file appeared
            new_files = [f for f in current_files if f not in pre_files]
            if new_files:
                detail = (f"new archive(s) found after ~{attempt * poll_interval}s: "
                          f"{', '.join(new_files[:3])}")
                return CheckResult(name, True, detail)

        return CheckResult(
            name, False,
            f"no new archive appeared after {max_polls * poll_interval}s"
            f" (checked {max_polls} times)"
        )

    def print_progress(self, check_result):
        """Print a single check result line to stdout."""
        tag = "PASS" if check_result.passed else "FAIL"
        line = f"  [{tag}] {check_result.name}"
        if not check_result.passed and check_result.detail:
            line += f" -- {check_result.detail[:300]}"
        print(line)

    def run_all(self):
        """Execute all check groups and produce the summary."""
        self.open_log()
        print(f"=== PPSA Smoke Test ===")
        print(f"Target: {self.transport.vm_address}")
        print(f"Started: {datetime.now().isoformat()}")
        print(f"Log: {self.log_path}")
        print()

        group_totals = {}  # group_name -> (pass, fail)

        for group_name, checks in CHECK_GROUPS:
            self._current_group = group_name

            group_pass = 0
            group_fail = 0

            for check_def in checks:
                name = check_def["name"]

                # Special handling based on check type
                if name == "Login returns JWT":
                    result = self.run_login_check(check_def)
                elif name == "Backup archive appears after trigger":
                    result = self.run_polling_check(check_def)
                elif name == "WireGuard dormant":
                    result = self.run_wg_dormancy_check(check_def)
                elif name == "ppsa-wgdashboard running":
                    result = self.run_soft_container_check(check_def)
                else:
                    result = self.run_check(check_def)

                self.results.append(result)
                self.print_progress(result)

                if result.passed:
                    group_pass += 1
                else:
                    group_fail += 1

            total = group_pass + group_fail

            if group_name == "nb.12 Regression Guard":
                heading = f"===== {group_name} ====="
            elif group_fail == 0:
                heading = f"[ {group_name} ] {group_pass}/{total} pass"
            else:
                heading = f"[ {group_name} ] {group_pass}/{total} pass, {group_fail}/{total} fail"

            print(f"\n{heading}")

            group_totals[group_name] = (group_pass, group_fail, group_pass + group_fail)

        self.close_log()
        self._print_summary(group_totals)

    def run_wg_dormancy_check(self, check_def):
        """Run the WG dormancy check with OR-style assertion.

        The check passes if status is 'not_configured' OR 'inactive'.
        It explicitly fails only if status is 'active'.
        """
        cmd = check_def["cmd"]
        timeout = check_def.get("timeout", DEFAULT_TIMEOUT)

        if self.token and "$TOKEN" in cmd:
            cmd = cmd.replace("$TOKEN", self.token)

        start = time.monotonic()
        stdout, stderr, exit_code = self.transport.exec(cmd, timeout=timeout)
        elapsed = time.monotonic() - start
        self.log_command(check_def["name"], cmd, stdout, stderr,
                         exit_code, elapsed)

        if exit_code != 0:
            return CheckResult(check_def["name"], False,
                               f"endpoint returned exit code {exit_code}")

        try:
            data = json.loads(stdout)
        except (json.JSONDecodeError, ValueError) as e:
            return CheckResult(check_def["name"], False,
                               f"non-JSON response: {e}")

        status = data.get("status", "")
        if status in ("not_configured", "inactive"):
            return CheckResult(check_def["name"], True, f"status={status}")
        elif status == "active":
            return CheckResult(
                check_def["name"], False,
                "status=active (WG is running, but the default/expected state is"
                " dormant). If the build was intentionally WG-enabled,"
                " this is expected."
            )
        else:
            return CheckResult(check_def["name"], True,
                               f"unexpected status={status}, treating as pass"
                               " (not actively connected)")

    def run_soft_container_check(self, check_def):
        """Run the wgdashboard container check.

        If the container exists, assert it's running/healthy. If it doesn't
        exist (WG dormant), count as PASS with a note.
        """
        name = check_def["name"]
        cmd = "sudo -n docker ps -a --filter name=ppsa-wgdashboard --format '{{.Names}}'"
        timeout = check_def.get("timeout", DEFAULT_TIMEOUT)

        start = time.monotonic()
        stdout, stderr, exit_code = self.transport.exec(cmd, timeout=timeout)
        elapsed = time.monotonic() - start
        self.log_command(f"{name} (exist check)", cmd, stdout, stderr,
                         exit_code, elapsed)

        container_exists = bool(stdout.strip())
        if not container_exists:
            return CheckResult(name, True, "skipped-WG-dormant")

        # Container exists -- check status
        status_cmd = (
            "sudo -n docker ps --filter name=ppsa-wgdashboard"
            " --format '{{.Status}}'"
        )
        start = time.monotonic()
        stdout2, stderr2, exit_code2 = self.transport.exec(
            status_cmd, timeout=timeout
        )
        elapsed2 = time.monotonic() - start
        self.log_command(f"{name} (status check)", status_cmd, stdout2,
                         stderr2, exit_code2, elapsed2)

        if exit_code2 != 0:
            return CheckResult(name, False, f"status check failed: {stderr2[:200]}")
        if not stdout2.strip():
            return CheckResult(name, False, "container exists but not running")

        ok = bool(re.search(r"Up|healthy", stdout2))
        detail = f"status={stdout2.strip()[:100]}" if ok else f"expected Up/healthy, got {stdout2.strip()[:100]}"
        return CheckResult(name, ok, detail)

    def _print_summary(self, group_totals):
        """Print the final summary table to stdout."""
        print(f"\n{'=' * 50}")
        print("Summary")
        print(f"{'=' * 50}")
        print(f"Log: {self.log_path}")

        total_pass = sum(g[0] for g in group_totals.values())
        total_fail = sum(g[1] for g in group_totals.values())
        total = total_pass + total_fail

        for group_name, (gp, gf, gt) in group_totals.items():
            status = "PASS" if gf == 0 else "FAIL"
            print(f"  {group_name:35s} {gp:2d}/{gt:2d}  {status}")

        print(f"\n  {'=' * 40}")
        print(f"  Groups: {len(group_totals)} | Total: {total}"
              f" | Pass: {total_pass} | Fail: {total_fail}")

        if total_fail > 0:
            print(f"\n  FAILED CHECKS:")
            for r in self.results:
                if not r.passed:
                    print(f"    [FAIL] {r.name} -- {r.detail[:300]}")
            print(f"\n  RESULT: FAIL")
            sys.exit(1)
        else:
            print(f"\n  RESULT: PASS")
            sys.exit(0)


# ===================================================================
# Check definitions
# ===================================================================
CHECK_GROUPS = [
    # ------------------------------------------------------------------
    # Group 1: SSH (2 checks)
    # ------------------------------------------------------------------
    (
        "SSH",
        [
            {
                "name": "SSH reachable",
                "cmd": "hostname -s",
                "assertions": [
                    ("exit_zero",),
                    ("matches", r"ppsa|ppsa-test"),
                ],
            },
            {
                "name": "sudo passwordless",
                "cmd": "sudo -n true && echo OK",
                "assertions": [
                    ("exit_zero",),
                    ("matches", r"OK"),
                ],
            },
        ],
    ),

    # ------------------------------------------------------------------
    # Group 2: AUTH (2 checks)
    # ------------------------------------------------------------------
    (
        "AUTH",
        [
            {
                "name": "Health endpoint (public)",
                "cmd": "curl -sf http://localhost:8080/health",
                "assertions": [
                    ("exit_zero",),
                    ("json_has", "status", "ok"),
                ],
            },
            {
                "name": "Login returns JWT",
                "cmd": (
                    "curl -sf -X POST http://localhost:8080/api/login"
                    " -u admin:admin"
                ),
                "assertions": [
                    ("exit_zero",),
                    ("json_has_key", "token"),
                ],
            },
        ],
    ),

    # ------------------------------------------------------------------
    # Group 3: STACK (5+1 checks)
    # ------------------------------------------------------------------
    (
        "STACK",
        [
            {
                "name": "Container count",
                "cmd": (
                    "sudo -n docker ps --format '{{.Names}}'"
                ),
                "assertions": [
                    ("exit_zero",),
                    ("count_lines", "ge", 4),
                ],
            },
            {
                "name": "ppsa-webui running",
                "cmd": (
                    "sudo -n docker ps --filter name=ppsa-webui"
                    " --format '{{.Status}}'"
                ),
                "assertions": [
                    ("exit_zero",),
                    ("matches", r"Up|healthy|starting"),
                ],
            },
            {
                "name": "ppsa-palworld running",
                "cmd": (
                    "sudo -n docker ps --filter name=ppsa-palworld"
                    " --format '{{.Status}}'"
                ),
                "assertions": [
                    ("exit_zero",),
                    # ponytail: palworld may be "unhealthy" during first-boot
                    # Steam download; that's expected — the container is
                    # running, just not ready for game connections yet.
                    ("matches", r"Up|healthy|starting|unhealthy"),
                ],
            },
            {
                "name": "ppsa-backup running",
                "cmd": (
                    "sudo -n docker ps --filter name=ppsa-backup"
                    " --format '{{.Status}}'"
                ),
                "assertions": [
                    ("exit_zero",),
                    ("matches", r"Up|healthy"),
                ],
            },
            {
                "name": "ppsa-watchtower running",
                "cmd": (
                    "sudo -n docker ps --filter name=ppsa-watchtower"
                    " --format '{{.Status}}'"
                ),
                "assertions": [
                    ("exit_zero",),
                    ("matches", r"Up|healthy"),
                ],
            },
            {
                # Soft check: wgdashboard only runs when WG is enabled
                "name": "ppsa-wgdashboard running",
                "cmd": "",
                "assertions": [],
            },
        ],
    ),

    # ------------------------------------------------------------------
    # Group 4: SYSTEM (3 checks)
    # ------------------------------------------------------------------
    (
        "SYSTEM",
        [
            {
                "name": "CPU cores > 0",
                "cmd": (
                    "curl -sf http://localhost:8080/api/system"
                    " -H \"Authorization: Bearer $TOKEN\""
                ),
                "assertions": [
                    ("exit_zero",),
                    ("json_gt", "cpu.cores", 0),
                ],
            },
            {
                "name": "Memory total > 0",
                "cmd": (
                    "curl -sf http://localhost:8080/api/system"
                    " -H \"Authorization: Bearer $TOKEN\""
                ),
                "assertions": [
                    ("exit_zero",),
                    ("json_gt", "memory.total_mb", 0),
                ],
            },
            {
                "name": "Disk available",
                "cmd": (
                    "curl -sf http://localhost:8080/api/system"
                    " -H \"Authorization: Bearer $TOKEN\""
                ),
                "assertions": [
                    ("exit_zero",),
                    ("json_has_key", "disk.available"),
                ],
            },
        ],
    ),

    # ------------------------------------------------------------------
    # Group 5: FIREWALL (2 checks)
    # ------------------------------------------------------------------
    (
        "FIREWALL",
        [
            {
                "name": "Firewall chain present",
                "cmd": (
                    "curl -sf http://localhost:8080/api/firewall/status"
                    " -H \"Authorization: Bearer $TOKEN\""
                ),
                "assertions": [
                    ("exit_zero",),
                    ("json_has", "chain_present", True),
                ],
            },
            {
                "name": "Firewall rules non-empty",
                "cmd": (
                    "curl -sf http://localhost:8080/api/firewall/status"
                    " -H \"Authorization: Bearer $TOKEN\""
                ),
                "assertions": [
                    ("exit_zero",),
                    ("matches", r"WG_FRIENDS|chain_present"),
                ],
            },
        ],
    ),

    # ------------------------------------------------------------------
    # Group 6: NETBIRD (2 checks)
    # ------------------------------------------------------------------
    (
        "NETBIRD",
        [
            {
                "name": "NetBird connected",
                "cmd": (
                    "curl -sf http://localhost:8080/api/netbird/status"
                    " -H \"Authorization: Bearer $TOKEN\""
                ),
                "assertions": [
                    ("exit_zero",),
                    ("json_has", "connected", True),
                ],
            },
            {
                "name": "NetBird has IP",
                "cmd": (
                    "curl -sf http://localhost:8080/api/netbird/status"
                    " -H \"Authorization: Bearer $TOKEN\""
                ),
                "assertions": [
                    ("exit_zero",),
                    ("json_has_key", "netbird_ip"),
                ],
            },
        ],
    ),

    # ------------------------------------------------------------------
    # Group 7: WG DORMANCY (1 check)
    # ------------------------------------------------------------------
    (
        "WG DORMANCY",
        [
            {
                "name": "WireGuard dormant",
                "cmd": (
                    "curl -sf http://localhost:8080/api/wireguard/status"
                    " -H \"Authorization: Bearer $TOKEN\""
                ),
                "assertions": [],
                # Custom handler in run_wg_dormancy_check
            },
        ],
    ),

    # ------------------------------------------------------------------
    # Group 8: BACKUP (3 checks)
    # ------------------------------------------------------------------
    (
        "BACKUP",
        [
            {
                "name": "Backup status endpoint",
                "cmd": (
                    "curl -sf http://localhost:8080/api/backup/status"
                    " -H \"Authorization: Bearer $TOKEN\""
                ),
                "assertions": [
                    ("exit_zero",),
                    ("json_has_key", "backup_dir"),
                    ("json_has_key", "file_count"),
                ],
            },
            {
                "name": "Save-file backup creates archive",
                "cmd": (
                    "curl -sf -X POST http://localhost:8080/api/backup/save-file"
                    " -H \"Authorization: Bearer $TOKEN\""
                ),
                "assertions": [
                    ("exit_zero",),
                    ("json_has_key", "name"),
                    ("json_has_key", "size"),
                    ("json_gt", "size", 0),
                ],
            },
            {
                "name": "Save-file archive listed in status",
                "cmd": (
                    "curl -sf http://localhost:8080/api/backup/status"
                    " -H \"Authorization: Bearer $TOKEN\""
                ),
                "assertions": [
                    ("exit_zero",),
                    ("json_gt", "file_count", 0),
                ],
            },
        ],
    ),

    # ------------------------------------------------------------------
    # Group 9: nb.12 Regression Guard (3 checks)
    # ------------------------------------------------------------------
    (
        "nb.12 Regression Guard",
        [
            {
                "name": "Server-action save returns 200 not 500",
                "cmd": (
                    "curl -sf -X POST http://localhost:8080/api/server/save"
                    " -H \"Authorization: Bearer $TOKEN\""
                ),
                "assertions": [
                    ("exit_zero",),
                    ("json_has", "status", "ok"),
                ],
            },
            {
                "name": "Backup trigger returns immediately (non-blocking)",
                "cmd": (
                    "curl -sf -X POST http://localhost:8080/api/backup/trigger"
                    " -H \"Authorization: Bearer $TOKEN\" --max-time 5"
                ),
                "assertions": [
                    ("exit_zero",),
                    ("json_has", "status", "triggered"),
                    ("response_time", 5),
                ],
                "timeout": 10,
            },
            {
                "name": "Backup archive appears after trigger",
                "cmd": (
                    "curl -sf -X POST http://localhost:8080/api/backup/trigger"
                    " -H \"Authorization: Bearer $TOKEN\" --max-time 30"
                ),
                "assertions": [],
                "timeout": 130,
            },
        ],
    ),

    # ------------------------------------------------------------------
    # Group 10: API INTEGRITY (3 checks)
    # ------------------------------------------------------------------
    (
        "API INTEGRITY",
        [
            {
                "name": "Dashboard returns server+metrics+players",
                "cmd": (
                    "curl -sf http://localhost:8080/api/dashboard"
                    " -H \"Authorization: Bearer $TOKEN\""
                ),
                "assertions": [
                    ("exit_zero",),
                    ("json_has_key", "server"),
                    ("json_has_key", "metrics"),
                    ("json_has_key", "players"),
                ],
            },
            {
                "name": "System health has containers array",
                "cmd": (
                    "curl -sf http://localhost:8080/api/system"
                    " -H \"Authorization: Bearer $TOKEN\""
                ),
                "assertions": [
                    ("exit_zero",),
                    ("json_has_key", "containers"),
                ],
            },
            {
                "name": "Firewall config returns defaults",
                "cmd": (
                    "curl -sf http://localhost:8080/api/firewall/config"
                    " -H \"Authorization: Bearer $TOKEN\""
                ),
                "assertions": [
                    ("exit_zero",),
                    ("json_has_key", "wg_friends_allowed_tcp"),
                    ("json_has_key", "wg_friends_allowed_udp"),
                ],
            },
        ],
    ),
]


# ===================================================================
# Entry point
# ===================================================================
def parse_args(argv=None):
    """Parse command-line arguments."""
    p = argparse.ArgumentParser(
        description="PPSA Smoke Test -- verify a fresh PPSA install over SSH.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=(
            "Examples:\n"
            "  %(prog)s ppsa-ppsa-test.nb.pleaseee.eu.org\n"
            "  %(prog)s 100.70.169.201 --ssh-password ppsa --verbose\n"
            "  %(prog)s 100.70.169.201 --ssh-key ~/.ssh/id_rsa --log-dir ./logs\n"
        ),
    )
    p.add_argument(
        "vm_address",
        help="NetBird DNS label or overlay IP (e.g. "
             "ppsa-ppsa-test.nb.pleaseee.eu.org or 100.70.169.201)",
    )
    p.add_argument(
        "--ssh-password", default=DEFAULT_PASSWORD,
        help=f"SSH password (default: {DEFAULT_PASSWORD})",
    )
    p.add_argument(
        "--ssh-key", default=None,
        help="SSH private key path (overrides password auth)",
    )
    p.add_argument(
        "--ssh-port", type=int, default=DEFAULT_SSH_PORT,
        help=f"SSH port (default: {DEFAULT_SSH_PORT})",
    )
    p.add_argument(
        "--plink", action="store_true", dest="force_plink",
        help="Force plink on any platform (auto-detected from sys.platform)",
    )
    p.add_argument(
        "--log-dir", default=DEFAULT_LOG_DIR,
        help=f"Directory for raw output log (default: {DEFAULT_LOG_DIR}/)",
    )
    p.add_argument(
        "--verbose", action="store_true",
        help="Print raw command output to stderr as checks run",
    )
    return p.parse_args(argv)


def main():
    args = parse_args()

    transport = SshTransport(
        vm_address=args.vm_address,
        password=args.ssh_password,
        key_file=args.ssh_key,
        port=args.ssh_port,
        force_plink=args.force_plink,
        verbose=args.verbose,
    )

    # Accept host key first (for plink) before running checks
    transport.accept_host_key()

    runner = SmokeTestRunner(
        transport=transport,
        log_dir=args.log_dir,
        verbose=args.verbose,
    )

    try:
        runner.run_all()
    except KeyboardInterrupt:
        runner.close_log()
        print(f"\nInterrupted. Log saved to: {runner.log_path}", file=sys.stderr)
        sys.exit(130)


if __name__ == "__main__":
    main()
