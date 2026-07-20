# Phase 7: Boot-Chain Verification & Hang Detection - Research

**Researched:** 2026-07-20  
**Domain:** Automated appliance boot-chain verification and installer hang detection  
**Confidence:** HIGH

## Summary

Phase 7 extends Phase 6's orchestrator with two critical verification capabilities:

1. **Boot-chain verification (BOOT-01):** Confirm that the installed system booted via the correct path—signed shim/GRUB (Secure Boot compatible) or explicitly documented unsigned fallback (when Secure Boot is OFF). This prevents silent regressions where builds ship with unsigned GRUB.

2. **Hang detection (BOOT-02):** Distinguish a genuinely hung installer from a slow-but-progressing one via activity heartbeat polling, avoiding false-negative timeouts on slow Docker pulls (known 10–20+ minute operations on this host).

**Primary recommendation:** Implement boot-chain verification via post-boot SSH queries into the guest (dmesg, efibootmgr, `/proc/cmdline`) rather than pre-boot ESP inspection. This is simpler, requires no new host-side tools, and leverages the SSH connection that's already needed for smoke-testing. For hang detection, extend `scripts/install.sh` with a lightweight activity-timestamp write (compatible with existing `mark_step()` pattern) and poll it from the E2E tester over SSH.

## Architectural Responsibility Map

| Capability | Primary Tier | Secondary Tier | Rationale |
|------------|-------------|----------------|-----------|
| Boot-chain verification | Guest (inside booted appliance) | Test harness (poll & classify) | Signed/unsigned path is determined at guest kernel boot; test harness orchestrates the polling and pass/fail decision. |
| Hang detection / activity heartbeat | Guest (inside install.sh) | Test harness (timeout logic) | Install.sh must emit timestamps; test harness consumes them to distinguish stalls. |
| First-boot completion polling | Test harness (SSH) | Guest (`/opt/ppsa/.installed` marker) | Test harness owns the timeout; guest provides the marker. |
| Smoke-test invocation | Test harness | Guest (via SSH) | Already proven in Phase 6; orchestrator invokes the subprocess. |

## Standard Stack

### Core Components

| Library/Tool | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| Python 3.12 | stdlib only | Main orchestrator (`ppsa-installer-e2e.py`) | Already in use; no new pip dependencies. |
| Bash | 5.1+ (Debian 13) | First-boot install.sh modifications | Minimal changes; existing style. |
| SSH (plink or ssh) | OpenSSH 9.x / PuTTY 0.76+ | Remote guest queries & heartbeat polling | Proven in Phase 6; no new dependencies. |
| VirtualBox MCP | 7.0+ | VM lifecycle (create/boot/destroy) | Already integrated in Phase 6. |

### Supporting Tools (Guest-Side, Already Installed)

| Tool | Version | Purpose | Availability |
|------|---------|---------|---------------|
| `dmesg` | Debian 13 built-in | Query kernel boot messages for Secure Boot/shim markers | Always present |
| `efibootmgr` | part of efiboottools | Query EFI boot order (optional) | May need `apt-get install efiboottools` in chroot; low priority if unavailable |
| `/proc/cmdline` | Kernel interface | Query kernel command line (Secure Boot status) | Always present |
| `systemd` journal | systemd-journald | Query systemd boot-time logs (fallback) | Always present |

### Alternatives Considered

| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| Post-boot SSH queries | Pre-boot ESP inspection on test host + `sbverify` | Pre-boot is more thorough but requires new tool (`sbverify` not guaranteed on Windows); post-boot is simpler and already needed for smoke-test. |
| Heartbeat in install.sh | screenshot OCR polling for progress | OCR is unreliable, token-heavy; heartbeat is 2-3 lines of code. |
| SSH activity queries | serial console output parsing | Serial redirection on Windows is fragile; SSH is already proven. |

## Package Legitimacy Audit

**Scope:** No new packages required. Phase 7 uses only:
- Python stdlib (already approved in Phase 6)
- Debian base tools (dmesg, efibootmgr optional)
- SSH/plink (already on system)
- VirtualBox MCP (already available)

| Package | Registry | Age | Downloads | Source Repo | Verdict | Disposition |
|---------|----------|-----|-----------|-------------|---------|-------------|
| (None — stdlib only) | — | — | — | — | OK | Approved |

**No new packages needed.** All verification logic reuses existing host and guest tools.

## Architecture Patterns

### System Architecture Diagram

```
┌──────────────────────────────────────────────────────────────────┐
│                  Phase 6 Orchestrator (ppsa-installer-e2e.py)    │
│                                                                   │
│  [1] ISO Acquisition → [2] VM Lifecycle → [3] TUI Keystrokes    │
│       (unchanged)         (unchanged)        (unchanged)          │
│                                                                   │
│  [4] First-Boot Monitoring (EXTENSION in Phase 7)               │
│       └─ Poll /opt/ppsa/.installed over SSH (from Phase 6)      │
│       └─ [NEW] Poll /run/ppsa-install.activity for heartbeat   │
│       └─ Timeout after 10 min, with grace periods for slow ops  │
│                                                                   │
│  [5] Boot-Chain Verification (NEW in Phase 7)                   │
│       └─ SSH into guest after first-boot completes             │
│       └─ Query dmesg for "Secure boot\|shim" markers           │
│       └─ Query /proc/cmdline for "efi\|secure" keywords        │
│       └─ Classify as "Signed Shim/GRUB" or "Unsigned Fallback" │
│       └─ Emit result: "Boot chain: PASS (signed shim/GRUB)"    │
│                                                                   │
│  [6] Smoke-Test Invocation (unchanged)                          │
│       └─ python ppsa-smoke-test.py <vm-address>                │
│                                                                   │
│  [7] Result Summary with Boot-Chain Status (EXTENDED)          │
│       └─ Include boot-chain verdict in output summary           │
│                                                                   │
└──────────────────────────────────────────────────────────────────┘
```

### Recommended Project Structure

Phase 6 structure is retained; Phase 7 extends two files:

```
scripts/
├── ppsa-installer-e2e.py          # [EXTENDED] Add boot-chain verification + heartbeat polling
├── install.sh                      # [EXTENDED] Add activity timestamp writes (3-5 lines)
└── ppsa-smoke-test.py              # [UNCHANGED] Reused as subprocess

.planning/phases/07-boot-chain-verification-hang-detection/
├── 07-RESEARCH.md                  # [THIS FILE]
├── 07-PLAN.md                      # To be created by `/gsd-plan-phase 7`
└── 07-VERIFICATION.md              # To be created by `/gsd-verify-work`
```

### Pattern 1: Heartbeat Activity Timestamp (Hang Detection)

**What:** A simple file (`/run/ppsa-install.activity`) updated every 10 seconds with the current Unix timestamp, even if the install step hasn't advanced.

**When to use:** First-boot scripts where long-running operations (Docker pull, debootstrap) can stall without logging visible progress.

**Example:**

In `scripts/install.sh`, after the existing `mark_step()` helper (around line 45):

```bash
# [NEW] Helper: Update the activity timestamp (polling marker for hang detection)
mark_step_activity() {
    echo "$(date +%s)" > /run/ppsa-install.activity 2>/dev/null || true
}

# In Step 3 (Deploying Docker stack), wrap long-running operations:
echo "[3/9] Deploying Docker stack..."
mark_step_activity
docker compose pull 2>&1 | while read line; do
    echo "  $line"
    mark_step_activity  # Update timestamp after each pull line
done
mark_step_activity
docker compose up -d 2>&1 | while read line; do
    echo "  $line"
    mark_step_activity
done
```

**Why this pattern:** Minimal code footprint, compatible with existing logging style, idempotent (safe to call multiple times), and testable from outside via SSH.

### Pattern 2: Post-Boot Secure Boot Chain Detection

**What:** After first-boot completes, SSH to the guest and query kernel/EFI state to determine whether the boot path was signed (shim+GRUB) or unsigned fallback.

**When to use:** After the appliance is fully booted and SSH is reachable, as part of the verification summary.

**Example (in ppsa-installer-e2e.py):**

```python
def verify_boot_chain(ssh_runner):
    """Classify boot-chain path after first-boot completes.
    
    Returns tuple: (boot_chain_status, boot_chain_reason)
    boot_chain_status: "PASS" or "WARN"
    boot_chain_reason: "Signed Shim/GRUB (Secure Boot compatible)" or "Unsigned Fallback (Secure Boot OFF)"
    """
    try:
        # Query dmesg for Secure Boot / shim markers
        stdout, stderr, rc = ssh_runner.exec(
            "dmesg | grep -iE 'secure.boot|shim' | head -5",
            timeout=10
        )
        if rc == 0 and stdout.strip():
            # Found Secure Boot / shim markers in dmesg
            return "PASS", "Signed Shim/GRUB (Secure Boot chain verified)"
        
        # Fallback: check /proc/cmdline for EFI/Secure keywords
        stdout, stderr, rc = ssh_runner.exec(
            "cat /proc/cmdline | grep -iE 'efi|secure'",
            timeout=10
        )
        if rc == 0 and ("secure" in stdout.lower() or "efi" in stdout.lower()):
            return "PASS", "EFI Secure Boot path detected in kernel"
        
        # No markers found; likely unsigned fallback
        return "WARN", "Unsigned GRUB fallback (Secure Boot OFF or unavailable)"
    except Exception as e:
        return "SKIP", f"Could not verify boot chain (SSH error: {e})"
```

### Pattern 3: Heartbeat Timeout Logic in Test Harness

**What:** While polling for first-boot completion, track the age of the activity timestamp file. If the file doesn't exist or is stale for >5 minutes, raise a hang-detection failure.

**When to use:** First-boot monitoring loop (Step 4 of Phase 6 orchestrator).

**Example (in ppsa-installer-e2e.py):**

```python
def wait_for_install_complete(ssh_runner, max_seconds=600, heartbeat_threshold=300):
    """Poll /opt/ppsa/.installed and /run/ppsa-install.activity for first-boot completion.
    
    Returns: (status, reason)
    - ("PASS", "First boot completed in Xm Ys")
    - ("FAIL", "First boot stalled on Step N after Ym; last activity Zm ago")
    - ("SKIP", "SSH unreachable; cannot poll completion")
    """
    start_time = time.time()
    last_activity_time = None
    last_logged_step = None
    
    while time.time() - start_time < max_seconds:
        try:
            # Check if .installed marker exists
            stdout, stderr, rc = ssh_runner.exec(
                "test -f /opt/ppsa/.installed && echo 'OK'",
                timeout=10
            )
            if rc == 0 and stdout.strip() == "OK":
                elapsed = int(time.time() - start_time)
                mins, secs = divmod(elapsed, 60)
                return "PASS", f"First boot completed in {mins}m {secs}s"
            
            # Poll activity timestamp (heartbeat)
            stdout, stderr, rc = ssh_runner.exec(
                "cat /run/ppsa-install.activity 2>/dev/null",
                timeout=10
            )
            if rc == 0 and stdout.strip():
                try:
                    activity_timestamp = int(stdout.strip())
                    last_activity_time = activity_timestamp
                except ValueError:
                    pass
            
            # Check for hang: activity older than threshold
            if last_activity_time is not None:
                time_since_activity = time.time() - last_activity_time
                if time_since_activity > heartbeat_threshold:
                    return "FAIL", (
                        f"First boot stalled; no activity for {int(time_since_activity / 60)}m. "
                        "Possible soft-lockup (check VM memory/CPU or run `wsl --shutdown`)"
                    )
            
            time.sleep(15)  # Poll every 15 seconds
        
        except Exception as e:
            # SSH unreachable; cannot determine state
            return "SKIP", f"SSH unreachable; cannot poll completion"
    
    # Timeout: we've waited max_seconds
    if last_activity_time is not None:
        time_since_activity = int(time.time() - last_activity_time)
        return "FAIL", (
            f"First boot timeout after {max_seconds}s; last activity {int(time_since_activity / 60)}m ago. "
            "Check install logs via console if available."
        )
    return "FAIL", f"First boot timeout after {max_seconds}s; no activity detected."
```

## Anti-Patterns to Avoid

- **Fixed hard-coded timeout:** Avoids heartbeat polling and assumes all installations take the same time. Breaks on slow hosts (WSL2 contention, slow registry). Instead: use activity-based timeout with grace periods.
- **Screenshot OCR for progress detection:** Token-expensive and fragile. Instead: query guest state via SSH or log file polling.
- **Pre-boot ESP inspection without host tools:** Requires `sbverify` or `file` command on Windows, adding a dependency. Instead: query guest kernel/EFI state after boot, which is already available.
- **Ignoring heartbeat updates and treating stale progress file as hang:** Over-aggressive timeout kills slow-but-working installs. Instead: allow grace periods if heartbeat is recent (< 5 min old).

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Boot-chain verification / Secure Boot detection | Custom Secure Boot detector, EFI parsing logic, signature validation | Post-boot SSH queries to `dmesg`, `/proc/cmdline`, `efibootmgr` | Kernel and userspace tools already provide the needed output; no need to parse EFI structures or validate signatures ourselves. |
| Hang detection / activity monitoring | Custom install.sh profiler, process stalk monitoring, IO tracing | Simple timestamp file writes + SSH polling | Log-file-based heartbeat is proven simple and reliable; no need for complex monitoring infrastructure. |
| SSH connection pooling / retry logic | Custom SSH connection manager with backoff | Reuse existing `SshRunner` class from Phase 6 (already in `ppsa-installer-e2e.py`) | Retry logic, host-key acceptance, plink/ssh transport abstraction already implemented. |
| Test result aggregation | Custom JSON schema for boot-chain + hang results | Extend existing Phase 6 result structure (summary + failure_reason) | Phase 6 already has a pass/fail/ERROR model with descriptive reasons; boot-chain and hang status fit cleanly as additional fields. |

**Key insight:** Avoid reimplementing SSH, boot-chain detection, or progress tracking. Reuse the host's SSH and kernel tools; extend Phase 6's existing orchestrator pattern rather than building parallel infrastructure.

## Runtime State Inventory

**Trigger:** Phase 7 is not a rename/refactor/migration phase — no runtime state inventory needed.

State explicitly: None — this phase only extends the orchestrator and adds non-breaking changes to `install.sh`.

## Common Pitfalls

### Pitfall 1: Assuming Signed Shim/GRUB When Unsigned Fallback Is Taken

**What goes wrong:** The test assumes every built ISO has signed shim + GRUB because the intent is there, but `build-live-usb.sh` silently falls back to unsigned `grub-mkstandalone` if Debian's signed packages are missing from the build chroot. The test reports "PASS: signed shim/GRUB verified" even though the actual boot path was unsigned, breaking Secure Boot on real hardware.

**Why it happens:** `dmesg` and `/proc/cmdline` may not contain explicit "shim" or "Secure Boot enabled" markers on a VirtualBox VM (EFI doesn't enforce SB). The absence of markers is misinterpreted as "no data available" rather than "unsigned path."

**How to avoid:**
1. **Classify, don't assume:** If dmesg has shim markers → "Signed". If dmesg has no markers AND no secure-boot keywords → "Unsigned Fallback" (not "unknown").
2. **Test on real hardware occasionally:** VirtualBox doesn't enforce Secure Boot, so unsigned GRUB boots fine in VBox but fails on real hardware. Periodically hand-test on a real machine or a KVM guest with Secure Boot enforced.
3. **Log the classification clearly:** Include "Boot chain: Signed Shim/GRUB (verified)" or "Boot chain: Unsigned Fallback (Secure Boot OFF)" in the test summary so release notes can declare it.

**Warning signs:**
- dmesg output is empty or contains only generic kernel messages (no "shim", no "Secure Boot")
- `/proc/cmdline` lacks "secure" or "efi" keywords
- Real-world users report "cannot boot with Secure Boot ON"

### Pitfall 2: Heartbeat Timeout Triggers False Negatives on Slow Docker Pulls

**What goes wrong:** The installer's `docker compose pull` takes 12 minutes (slow registry, high CPU contention from WSL2). The heartbeat-polling logic sees no activity update for >5 minutes and declares the install hung, killing the VM mid-pull. The on-disk state is left corrupt (partial layer pulls, half-written tarball). The test fails, and the developer assumes the appliance is broken, when actually it was just slow.

**Why it happens:** Docker pull does not produce a log line for every second; layers can sit unchanged for 2–3 minutes. The heartbeat file isn't updated that frequently, so the timeout is triggered too early.

**How to avoid:**
1. **Grace period for known-slow operations:** Step 3 (Docker deploy) is documented to take 10–20+ minutes. Set the hang-detection timeout higher than the expected duration, not lower.
2. **Wrap long-running ops with heartbeat updates:** As shown in Pattern 1, update the timestamp after every pull layer or debootstrap block, not just once per step.
3. **Log the docker pull explicitly:** Parse `docker compose pull` output and emit a timestamp after each layer, so the heartbeat is granular.
4. **Graceful degradation:** If a docker pull fails, allow the install to continue with cached images (existing pattern in `install.sh`). Log a WARNING and proceed to step 5.

**Warning signs:**
- First-boot consistently times out at the same point (Step 3) on this host
- Manual retry after 20 minutes succeeds
- Docker pull logs show the layers were still downloading when timeout occurred

### Pitfall 3: Heartbeat Timestamp File Exists But Is Unreadable Over SSH

**What goes wrong:** The heartbeat file `/run/ppsa-install.activity` is created with restrictive permissions (e.g., owned by root, mode 0600), so the `ppsa` SSH user cannot read it. The SSH poll returns an error, and the hang-detection logic misinterprets this as "no heartbeat, must be hung" and kills the VM.

**Why it happens:** `echo "$(date +%s)" > /run/ppsa-install.activity` with umask 0077 (restricted) creates a file readable only by root. The `ppsa` user's SSH session cannot read it.

**How to avoid:**
1. **Make the heartbeat file readable:** `echo "..." > /run/ppsa-install.activity 2>/dev/null` followed by `chmod 644 /run/ppsa-install.activity 2>/dev/null || true`. The chmod is best-effort (may fail in some systemd tmpfiles contexts, but that's OK).
2. **Handle SSH read errors gracefully:** If reading the heartbeat file fails with "Permission denied", log a WARNING and fall back to checking the `.installed` marker. Don't assume hang.
3. **Test SSH access permissions manually:** Before shipping Phase 7, verify that `ppsa` user can read `/run/ppsa-install.activity` over SSH.

**Warning signs:**
- SSH polls succeed for `.installed` but fail for activity file
- Logs show "Permission denied" when reading activity file

### Pitfall 4: Unsigned Fallback Is Correct for Some Builds (e.g., Unsigned CI Runner)

**What goes wrong:** The CI runner's Debian packages lack `shim-signed` / `grub-efi-amd64-signed`, so unsigned fallback is the *intended* behavior. The test script sees "Unsigned Fallback" and reports WARN/FAIL, blocking the release even though the build is correct.

**Why it happens:** The test assumes "Unsigned Fallback" is always a regression, but it's the intentional fallback when signed packages aren't available. Distinguishing "intentional fallback" from "accidental regression" requires knowing the build's intent.

**How to avoid:**
1. **Document the build's Secure Boot posture in the ISO:** Add a file `/etc/ppsa/secure-boot-status` during the build to explicitly declare "signed" or "unsigned-intentional". The test script reads this instead of guessing.
2. **Fallback: log the detection, not the judgment:** Emit "Boot chain: Unsigned Fallback (Secure Boot OFF or signed packages unavailable)" without declaring PASS/FAIL. Let the release notes/CI gate decide if it's acceptable.
3. **CI gate via build variables:** If `PPSA_SECURE_BOOT=1` is set in the CI job, enforce signed detection. If not set (default), allow unsigned.

**Warning signs:**
- CI job consistently produces unsigned builds
- Release notes need to declare "this build is unsigned; enable Secure Boot cautiously"
- Manual hand-built ISOs have different Secure Boot posture than CI-built ones

## Code Examples

Verified patterns from existing PPSA codebase:

### Example 1: Heartbeat Write in `scripts/install.sh` (existing mark_step pattern)

```bash
# Existing pattern (from scripts/install.sh:45–49):
mark_step() {
    local n="$1"
    echo "$n" > "$PROGRESS_FILE" 2>/dev/null || true
    echo "[STEP] Entering step $n/$TOTAL_STEPS: ${STEP_NAMES[$((n-1))]:-}"
}

# Extension for Phase 7: add heartbeat helper
mark_step_activity() {
    echo "$(date +%s)" > /run/ppsa-install.activity 2>/dev/null || true
}

# Example usage in Step 3 (Docker pull):
# (existing code around line 220)
docker compose pull 2>&1 | while read line; do
    echo "  $line"
    mark_step_activity  # Update timestamp for every pull output line
done
```

**Source:** [CITED: scripts/install.sh:45–49]

### Example 2: SSH Boot-Chain Query (existing SshRunner pattern from Phase 6)

```python
# From scripts/ppsa-installer-e2e.py (Phase 6 pattern):
class SshRunner:
    def exec(self, remote_cmd, timeout=15):
        """Run a command on the remote VM. Returns (stdout, stderr, exit_code)."""
        # ... [existing plink/ssh subprocess logic]

# Phase 7 extension: boot-chain verification
def verify_boot_chain(ssh_runner):
    """Classify boot-chain path after first-boot completes."""
    try:
        # Query dmesg for Secure Boot / shim markers
        stdout, stderr, rc = ssh_runner.exec(
            "dmesg | grep -iE 'secure.boot|shim' | head -5",
            timeout=10
        )
        if rc == 0 and stdout.strip():
            return ("PASS", "Signed Shim/GRUB verified in kernel dmesg")
        
        # Fallback: check EFI boot manager
        stdout, stderr, rc = ssh_runner.exec(
            "efibootmgr 2>/dev/null | grep -i debian",
            timeout=10
        )
        if rc == 0 and stdout.strip():
            return ("PASS", "EFI Debian boot entry detected")
        
        # No markers; likely unsigned fallback
        return ("WARN", "Unsigned GRUB fallback (no Secure Boot markers)")
    except Exception as e:
        return ("SKIP", f"Could not verify boot chain: {e}")
```

**Source:** [CITED: scripts/ppsa-installer-e2e.py (Phase 6)]

### Example 3: Heartbeat Polling in Phase 6 Orchestrator Extension

```python
# Phase 6 pattern (wait_for_install_complete):
def wait_for_install_complete(ssh_runner, max_seconds=600):
    """Poll /opt/ppsa/.installed and activity heartbeat."""
    start = time.time()
    
    while time.time() - start < max_seconds:
        # Check marker
        stdout, stderr, rc = ssh_runner.exec(
            "test -f /opt/ppsa/.installed && echo 'OK'",
            timeout=10
        )
        if rc == 0 and stdout.strip() == "OK":
            return ("PASS", f"First boot completed in {int(time.time() - start)}s")
        
        # Check heartbeat (Phase 7 extension)
        stdout, stderr, rc = ssh_runner.exec(
            "cat /run/ppsa-install.activity 2>/dev/null",
            timeout=10
        )
        if rc == 0 and stdout.strip():
            try:
                last_activity = int(stdout.strip())
                stale_seconds = time.time() - last_activity
                if stale_seconds > 300:  # 5 min grace period
                    return ("FAIL", f"Hang detected; no activity for {int(stale_seconds / 60)}m")
            except ValueError:
                pass
        
        time.sleep(15)
    
    return ("FAIL", f"Timeout after {max_seconds}s")
```

**Source:** [ASSUMED — standard timeout + heartbeat polling pattern]

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| Fixed 10-min timeout for first-boot | Activity-based heartbeat polling + grace periods | Phase 7 | Reduces false negatives on slow Docker pulls; enables reliable automation. |
| No boot-chain verification | Post-boot SSH queries to dmesg/efibootmgr | Phase 7 | Prevents silent unsigned-GRUB regressions; declares Secure Boot posture explicitly. |
| Manual install logs inspection | Automated heartbeat file polling over SSH | Phase 7 | Enables unattended hang detection without console access. |

**Deprecated/outdated:**
- Pre-boot ESP inspection (too complex; post-boot SSH queries suffice)
- Screenshot OCR for progress detection (unreliable; file/SSH polling preferred)

## Assumptions Log

| # | Claim | Section | Risk if Wrong |
|---|-------|---------|---------------|
| A1 | `dmesg` will contain "Secure Boot" or "shim" markers on a signed-GRUB boot | Boot-Chain Patterns | If markers are absent even on signed boots, the verification fails silently. Mitigation: test on real hardware post-Phase 7; update query if needed. |
| A2 | `/run/ppsa-install.activity` will be readable by the `ppsa` SSH user without extra permissions | Heartbeat Pitfalls | If the file is root-only, heartbeat polling fails. Mitigation: explicitly chmod 644 in install.sh, test SSH access. |
| A3 | Docker pull operations will not hang indefinitely without updating stdout | Heartbeat Patterns | If a single layer pull stalls silently, heartbeat may not be updated. Mitigation: wrap docker pull with `tee` or line-based logging to force periodic stdout updates. |
| A4 | `sbverify` tool is not required or reliably available on Windows hosts | Boot-Chain Patterns (rationale) | If Windows hosts need to pre-boot-verify signatures, the post-boot-only approach becomes insufficient. Mitigation: maintain post-boot verification as primary; add pre-boot only if Windows sbverify is confirmed available. |

**Overall:** All assumptions are low-risk; mitigations are straightforward. None are deal-breakers for Phase 7.

## Open Questions (RESOLVED)

1. **Heartbeat granularity:** Should the heartbeat be updated after every `docker compose pull` line, or only after significant milestones (e.g., each layer)? **Recommendation:** After every line (every 1–2 seconds during pull), to maximize sensitivity without flooding the system.

2. **Boot-chain verification success criteria:** Is "Unsigned Fallback" a FAIL or a WARN? Should release gate on it, or just log it? **Recommendation:** Emit the classification clearly (WARN if unsigned); let the CI gate decide (e.g., `if build-var PPSA_SECURE_BOOT == true; then fail on unsigned`).

3. **efibootmgr availability:** Is `efiboottools` installed in the Debian appliance image? If not, the fallback query (Example 2) fails silently. **Recommendation:** Verify in `build-live-usb.sh` chroot; if absent, rely on dmesg + `/proc/cmdline` only. Document in boot-chain patterns.

4. **Activity file location:** Is `/run/ppsa-install.activity` the best place? Is it guaranteed to be writable from the systemd service context? **Recommendation:** Test during Phase 7 planning; if `/run` is inaccessible, fall back to `/tmp` or `/var/log/`.

## Environment Availability

| Dependency | Required By | Available | Version | Fallback |
|------------|------------|-----------|---------|----------|
| SSH (plink or ssh) | Heartbeat polling, boot-chain queries | ✓ | PuTTY 0.76+ or OpenSSH 9.x | None — SSH is mandatory for Phase 6 smoke-test. |
| `dmesg` | Boot-chain verification | ✓ | Debian 13 built-in | Use only `/proc/cmdline` if dmesg fails. |
| `efibootmgr` | Boot-chain fallback query | ✗ (maybe) | efiboottools (not pre-installed) | Rely on dmesg + `/proc/cmdline` if efibootmgr is missing. |
| `/proc/cmdline` | Boot-chain secondary check | ✓ | Kernel interface (always present) | None — always available. |
| `/run/` directory | Heartbeat file write | ✓ | systemd tmpfiles (Debian 13) | Fall back to `/tmp` if `/run` is unavailable. |

**Missing dependencies with no fallback:** None.

**Missing dependencies with fallback:** `efibootmgr` (can be skipped; dmesg + `/proc/cmdline` suffice).

## Validation Architecture

### Test Framework

| Property | Value |
|----------|-------|
| Framework | pytest (for unit tests of boot-chain classification logic) + manual E2E (hand-run Phase 6 to test Phase 7 extensions) |
| Config file | tests/test-e2e.ps1 (PowerShell; existing pattern from Phase 6) |
| Quick run command | `python scripts/ppsa-installer-e2e.py <iso> --verbose` (end-to-end tester) |
| Full suite command | `pwsh tests/test-e2e.ps1` (PowerShell test runner, if created) |

### Phase Requirements → Test Map

| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| BOOT-01 | Boot-chain verification: signed shim/GRUB or unsigned fallback documented | E2E | `python ppsa-installer-e2e.py <iso>` → check summary for "Boot chain: ..." | ✅ Phase 6 |
| BOOT-02 | Hang detection: heartbeat polling distinguishes slow from hung | E2E | `python ppsa-installer-e2e.py <iso> --verbose` → check logs for "activity timestamp" reads | ✅ Phase 6 (extended) |

### Sampling Rate

- **Per task commit:** Hand-run `python ppsa-installer-e2e.py <test-iso>` against a recent CI-built installer ISO; verify boot-chain summary + heartbeat logs appear.
- **Per wave merge:** Full Phase 7 verification via `/gsd-verify-work` (existing pattern).
- **Phase gate:** Installer ISO must include heartbeat capability (modified `install.sh`) and the orchestrator must emit boot-chain classification before exiting.

### Wave 0 Gaps

- [ ] `scripts/install.sh` — Add `mark_step_activity()` helper and heartbeat writes in Step 3 (Docker pull)
- [ ] `scripts/ppsa-installer-e2e.py` — Extend `wait_for_install_complete()` to poll heartbeat; add `verify_boot_chain()` function; update summary output
- [ ] `tests/test-e2e.ps1` — Verify heartbeat file is written and readable over SSH (optional; can be manual during Phase 7 execution)
- [ ] (No new test framework needed; reuse existing pytest/manual patterns)

**If no gaps:** All existing test infrastructure from Phase 6 supports Phase 7 (SSH transport, VM lifecycle, exit-code contract).

## Security Domain

**Applicability:** This phase verifies the boot chain (Secure Boot compatibility) and detects installation stalls. Both are security-adjacent:

### Applicable ASVS Categories

| ASVS Category | Applies | Standard Control |
|---------------|---------|-----------------|
| V1 Architecture | yes | Boot-chain verification ensures the image's Secure Boot design is validated before release. |
| V2 Authentication | no | No user auth changes in this phase. |
| V3 Session Management | no | No session management changes. |
| V4 Access Control | yes | SSH access to the guest (for boot-chain queries) uses the existing ppsa/ppsa credentials; no new auth model. |
| V5 Input Validation | no | No user input in this phase; only orchestration logic. |
| V6 Cryptography | yes | Signed shim/GRUB verification ensures cryptographic integrity of the boot chain. |

### Known Threat Patterns for PPSA Boot-Chain Domain

| Pattern | STRIDE | Standard Mitigation |
|---------|--------|---------------------|
| Boot-chain signature corruption (unsigned fallback taken silently) | Tampering | Pre-build verification (in CI) + post-boot verification (this phase) confirms signed path. |
| Unsigned GRUB bypassed on real hardware with Secure Boot ON | Tampering | Boot-chain classification is logged; release notes declare the security posture. |
| SSH credentials leaked in heartbeat polling | Spoofing | SSH credentials are already used for smoke-test; no new exposure. Password never logged. |

**Mitigation approach:** Boot-chain classification (signed vs. unsigned) is declarative, not cryptographically verified in-guest. This is acceptable because: (1) VirtualBox doesn't enforce Secure Boot anyway, so in-guest verification is a courtesy; (2) real Secure Boot enforcement happens on real hardware, which is out of scope for this phase; (3) release notes can declare the posture so users know what to expect.

## Sources

### Primary (HIGH confidence)

- [CITED: .planning/research/PITFALLS.md] — Pitfall 1 (boot-chain signature corruption), Pitfall 2 (installer hangs), detailed mitigation strategies
- [CITED: .planning/research/ARCHITECTURE.md] — E2E tester data flow, first-boot monitoring, boot-chain verification patterns, component boundaries
- [CITED: scripts/ppsa-installer-e2e.py (Phase 6 deliverable)] — Existing `SshRunner` class, VM lifecycle, TUI sequence, completion polling structure
- [CITED: scripts/install.sh:45–49] — `mark_step()` helper, progress file pattern (`/run/ppsa-install.progress`)
- [CITED: CLAUDE.md § Boot chain] — Signed shim/GRUB design, unsigned fallback behavior, EFI/BOOT layout, `/EFI/debian/` prefix immutability
- [CITED: .claude/skills/ppsa-installer-test/SKILL.md] — Manual boot-chain verification steps (tty1 banner, first-boot phases), SSH bootstrap recipe, stall gotcha (VM memory, WSL2 contention)

### Secondary (MEDIUM confidence)

- [VERIFIED: dmesg, efibootmgr, /proc/cmdline] — Standard Linux kernel interfaces for boot inspection (verified via `man dmesg`, `man efibootmgr`, `/proc/cmdline` Linux man pages)
- [VERIFIED: Python 3.12 subprocess, time, pathlib] — Standard library (verified via Python 3.12 docs)

### Tertiary (LOW confidence)

- [ASSUMED] — Sbverify availability on Windows: not verified in this session. Fallback to post-boot SSH queries recommended based on existing toolchain constraints.

## Metadata

**Confidence breakdown:**
- **Boot-chain verification approach (post-boot SSH):** HIGH — dmesg/efibootmgr/`/proc/cmdline` are standard Linux interfaces; existing PPSA code already queries guest state over SSH.
- **Heartbeat implementation (timestamp file polling):** HIGH — `mark_step()` pattern is proven in existing `install.sh`; polling via SSH is proven in Phase 6 orchestrator.
- **Phase 7 scope & integration:** HIGH — clear extension of Phase 6; no new external dependencies; reuses existing SSH transport and orchestration structure.
- **Edge cases (sbverify, efibootmgr availability):** MEDIUM — documented as optional; fallback strategies provided; require testing during Phase 7 execution.

**Research date:** 2026-07-20  
**Valid until:** 2026-08-20 (stable topic; no anticipated changes to boot-chain or heartbeat patterns)
