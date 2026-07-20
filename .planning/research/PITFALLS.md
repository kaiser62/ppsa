# Domain Pitfalls: Automated Installer-ISO E2E Testing

**Domain:** OS installer automation in constrained CI/test environment (blind TUI, boot-chain verification, VM host contention, appliance integration)
**Researched:** 2026-07-20
**Based on:** v1.3.0 Phase 2 SSH smoke test, existing manual VBox flow (ppsa-installer-test skill), PPSA-specific constraints (Secure Boot chain, NetBird enrollment, WSL2/Hyper-V contention)

## Critical Pitfalls

These break the entire test pipeline or corrupt the release process. Prevention is non-negotiable.

### Pitfall 1: Boot-Chain Signature Corruption or Fallback Misdetection

**What goes wrong:**
The automation assumes a signed shim/GRUB boot succeeded, but either the signature is actually missing (unsigned fallback), Secure Boot is ON when it shouldn't be (or OFF when a signed chain should be tested), or the fallback grub-mkstandalone path is taken silently without logging the deviation. The resulting VM boots under unsigned GRUB, violating the security model, but the test reports PASS anyway — a release ships with a broken Secure Boot chain.

**Why it happens:**
- `build-live-usb.sh` conditionally installs signed shim/GRUB only if the Debian packages are available in the build chroot. If the build runner's apt cache is stale or a dependency is missing, it silently falls back to unsigned `grub-mkstandalone`.
- The ISO's signed status is baked at build time; the test runner has no way to introspect it before boot.
- VirtualBox EFI mode does NOT enforce Secure Boot (firmware will boot unsigned GRUB), so the test passes even if the signature is missing.
- Detecting which path was taken requires parsing EFI boot order, checking shim presence on ESP, or inspecting signed-GRUB's immutable `/EFI/debian/grub.cfg` prefix — all host-level checks unavailable from within the booted VM.
- No boot log capture from the EFI firmware layer to prove signature verification happened.

**Consequences:**
- Silent regression: a release ships with unsigned GRUB.
- Users with Secure Boot ON on real hardware cannot boot the appliance.
- Users with Secure Boot OFF still work, masking the regression until rollout.
- Incident: "v1.5.0 breaks on all my hardware" when users with Secure Boot enabled try to boot.

**Prevention:**
1. **Pre-boot ISO inspection (CRITICAL).** Before the VM boots, mount the ISO or VDI's ESP read-only on the test host and verify:
   - `EFI/BOOT/BOOTX64.EFI` exists and is identified as shim (file signature check or `file` command).
   - `EFI/BOOT/grubx64.efi` exists and is signed (signature check via `sbverify` if available, or fallback: size check — unsigned grub-mkstandalone is notably smaller).
   - `EFI/debian/grub.cfg` prefix matches the signed GRUB prefix expectation.
   - If ANY of these fail, mark the ISO as "unsigned fallback" and fail the test with a clear message: "Boot chain regression: unsigned fallback detected."

2. **VirtualBox Secure Boot simulation.** Set the test VM to enable EFI firmware with Secure Boot mock (VBox flags: `--firmware efi`, do NOT disable it). If the host has no real Secure Boot PKI, the test VM will simply boot unsigned code anyway, but the flag documents the intent. The real validation is the pre-boot ESP check above.

3. **Boot-chain version in test summary.** Log "Signed Shim/GRUB" or "Unsigned Fallback (Secure Boot OFF)" prominently in the test result, so release notes can declare the security posture.

4. **CI gate:** Any test that detects "unsigned fallback" must FAIL the milestone, not warn. This is a release-blocking check.

**Detection:**
- Pre-boot: Automated ESP inspection fails or reports "unsigned fallback."
- Post-boot (weak signal): No signed-GRUB-specific logs in dmesg; kernel shows `systemd-boot` or `GRUB 2.xx` generic banner without signature verification output.
- Release notes missing boot-chain declaration.

### Pitfall 2: Installer Hangs Masquerading as Successful Progress

**What goes wrong:**
The installer begins writing the image to disk (`Step 3: Deploying ...`) but the I/O stalls (VM disk throttling, host CPU starvation, zstd decompression bottleneck). The status line stops updating for 30+ minutes. The test script, polling the progress file or screenshot OCR, sees no movement and assumes the VM is stuck. But the actual installer process is still alive — it's just slow. The test times out, reports FAIL, and the tester kills the VM. Meanwhile, the install WAS proceeding (slowly), and killing it leaves a corrupt on-disk state. On retry, the installer can't resume because the partition table is half-written.

**Why it happens:**
- `ppsa-install.sh` writes a progress file (`/run/ppsa-install.progress`) as each of 9 steps begins, but progress updates within Step 3 (Docker pull + debootstrap) are infrequent (one update per ~500MB decompressed).
- First-boot logs go to `/var/log/ppsa-install.log`, but the tty1 progress display is non-blocking — the installer can hang on a Docker pull while tty1 shows no new output for 15 min.
- On this host: WSL2/Hyper-V contention starves VirtualBox of CPU + disk I/O (known issue from memory notes). A 4GB VM on a congested host can appear frozen when it's just CPU-throttled.
- The test harness has no way to distinguish "installer is slow" from "installer is hung" without heartbeat signals embedded in the installer itself.

**Consequences:**
- False negatives: valid installers are killed mid-install, reported as failures.
- Corrupted on-disk state forces a manual `dd if=/dev/zero` cleanup before retry.
- Test flakiness: CI runs become unreliable; bisects fail.
- Development velocity killed: testers spend time debugging timeouts instead of logic errors.

**Prevention:**
1. **Heartbeat in the installer.** Modify `scripts/install.sh` Step 3 subsections (Docker pull, debootstrap unpack, partition grow) to write a "last-active" timestamp every 10 seconds, even if the step hasn't advanced. Example:
   ```bash
   mark_step_activity() {
     echo "$(date +%s)" > /run/ppsa-install.activity
   }
   # In loops: mark_step_activity after every meaningful operation
   ```
   Test harness watches `/run/ppsa-install.activity` — if it's older than 5 min (not 30 min), AND the VM is still responsive on SSH, something is genuinely stuck.

2. **VM resource pre-check.** Before boot, verify:
   - VM memory: 10240 MB minimum (Docker + palworld needs 4GB each; step 3 peak is ~8GB).
   - Host free disk I/O: `wsl --shutdown` before test to free WSL2 resources.
   - No competing Docker builds on the test host.
   - If any of these fail, skip the test with a clear message: "Host resources insufficient; cannot run installer test."

3. **Graceful timeout with disk state recovery.** If Step 3 status hasn't advanced in 20 min BUT the heartbeat is recent (< 5 min old), allow 20 min more. If the heartbeat is stale for 10+ min, the installer is genuinely hung — kill it and report FAIL. On retry, make the first-boot installer idempotent: if the partition is half-written, attempt a `parted` resize to fix it, or report "Disk corruption; manual `dd` cleanup required."

4. **Verbose logging in test harness.** Capture the full `/var/log/ppsa-install.log` during the test and report timing stats: "Step 3 took 14 min (expected 8-15 min). Heartbeat activity last seen 2 min ago." If a genuine bottleneck is found (slow Docker registry), the logs show it.

**Detection:**
- Test harness polls heartbeat file; if > 10 min stale, flag timeout.
- Post-mortem: Check `ps aux` via SSH for hung processes (Docker pull, tar decompress, parted).
- tty1 screenshot shows status line unchanged for 20+ min.
- Next boot: partition table is corrupt (parted error on resize), or `.installed` flag is missing.

### Pitfall 3: Identity Theft: Test VM Steals Shared WireGuard Identity

**What goes wrong:**
Every PPSA image bakes the same WireGuard peer identity (`ppsa-server` / `10.8.0.2`). If the real remote PPSA server is live while the test VM boots, both VMs compete for the same identity on the wg-easy hub. The test VM's handshake succeeds first, hijacking `10.8.0.2`. The real server's handshake fails (endpoint mismatch). Friends trying to reach the real server now reach the test VM instead. Data loss, service interruption, and privacy violation if the test VM's saved-game state leaks.

**Why it happens:**
- The WireGuard identity is baked into `/etc/wireguard/wg0.conf` at build time. Changing it per-build is out of scope (would require build-time parametrization, which wasn't implemented).
- The existing ppsa-installer-test skill explicitly warns: "If the real remote server is LIVE, the test VM steals its tunnel on handshake." But automation may not have this human check gate.
- Both WireGuard (deprecated, default-disabled) AND NetBird enroll at first boot. If only WireGuard is re-enabled (`PPSA_WG_ENABLED=true`), identity theft is a risk. If NetBird is also enabled, the test still competes for `10.8.0.2` on the WireGuard hub.
- No guard rails: the test harness doesn't verify the real server is offline before booting the test VM.

**Consequences:**
- Service interruption for real users.
- Test VM saves corrupt game data that might contaminate backups if uploaded.
- Debugging nightmare: logs show two VMs claiming the same identity.
- Incident: "v1.5.0 broke my server when I tested it; friends couldn't log in."

**Prevention:**
1. **Mandatory pre-boot hub check.** Before booting the test VM, query the wg-easy hub API (if WireGuard is enabled in the build):
   ```bash
   curl -s -b cj.txt http://hub-url/api/client | jq '.[] | select(.name=="ppsa-server")'
   ```
   If `ppsa-server` is found with a recent `latestHandshakeAt` (< 1 hour ago), **ABORT the test** with error message: "Real server is live on the hub. Kill it or disable WireGuard before testing."

2. **Disable WireGuard by default in test builds.** Build the test ISO with `PPSA_WG_ENABLED=false` (the default), so even if the identity exists, it's not registered. The test still validates NetBird enrollment and firewall, which is the primary path.

3. **Unique WireGuard identity per test run (stretch).** If re-enabling WireGuard testing, modify the first-boot script to accept an injection point:
   ```bash
   # Pseudo-code
   WG_PEER_NAME="${PPSA_WG_PEER_NAME:-ppsa-server}"
   ```
   The CI test harness can pass `PPSA_WG_PEER_NAME="ppsa-test-$(date +%s)"` to create a unique identity per run. This requires careful compose/.env parametrization and is a Phase 5/6 enhancement.

4. **Post-boot cleanup mandate.** If the test accidentally steals the identity, the cleanup script must immediately disable WireGuard:
   ```bash
   sudo systemctl disable --now ppsa-wireguard-register wg-quick@wg0
   sudo wg-quick down wg0 2>/dev/null || true
   ```
   Include this in the test shutdown sequence unconditionally.

**Detection:**
- Hub check returns `ppsa-server` with recent handshake → abort test.
- After test VM boots, hub shows TWO endpoints for `ppsa-server` → data corruption risk.
- Real server logs show "WireGuard handshake failed" while test VM is up.
- Friends report service outage coinciding with test run.

### Pitfall 4: NetBird Enrollment Stalls Due to Network Isolation or Registration Timeout

**What goes wrong:**
The test VM boots, and `ppsa-netbird-up.sh` attempts to enroll in the NetBird control plane (`nb.pleaseee.eu.org`) using credentials injected as environment variables. The enrollment request hangs or times out because:
- The ISO was built without the `PPSA_NB_SETUP_KEY` or `PPSA_NB_MANAGEMENT_URL` env vars set (credentials are missing).
- The test host cannot reach `nb.pleaseee.eu.org:443` (network isolation, firewall block, or control plane down).
- The control plane's DNS is not resolvable inside the test VM (systemd-resolved not yet configured, or public-only resolvers ignore private names).
- The enrollment succeeds but takes > 30 seconds, and the test harness assumes the first boot is hung.

First boot stalls at "Step 5: Configuring NetBird", displaying no progress. The test times out without ever getting an overlay IP, so SSH access fails, and the smoke test cannot run.

**Why it happens:**
- The existing manual ppsa-installer-test skill does not cover NetBird enrollment — it relies on WireGuard or LAN console injection. Automating enrollment requires network access outside the test VM's local subnet.
- CI builds inject `PPSA_NB_SETUP_KEY` and `PPSA_NB_MANAGEMENT_URL` as GitHub secrets, but the test harness must explicitly pass them to the test VM's first-boot environment. If the CI job doesn't export these secrets to the ISO build, the test VM is built without credentials.
- The first-boot script tries to enroll but gets a 404 or timeout, logs a warning, and continues. It's not a hard failure. But without an overlay IP, the test cannot reach the appliance.
- DNS resolution for `nb.pleaseee.eu.org` may fail if the test VM uses a public-only resolver (baked at build time) instead of accepting DHCP or systemd-resolved.

**Consequences:**
- Test VM is isolated: no NetBird IP, no SSH access from dev peer, smoke test cannot run.
- Test reports FAIL incorrectly (the appliance itself is fine; the environment is broken).
- False blame: "Installer broke NetBird" when actually the test harness did.
- Development delay: testers manually console into the VM to debug enrollment, token-intensive.

**Prevention:**
1. **Pre-build credentials injection (CRITICAL).** The CI job must:
   - Resolve `PPSA_NB_SETUP_KEY` and `PPSA_NB_MANAGEMENT_URL` from GitHub secrets.
   - Pass them as build args to the image builder (`build-live-usb.sh` must accept `--nb-setup-key` and `--nb-management-url` arguments).
   - The `.env.example` baked into the image MUST include these keys so the first-boot script can source them.
   - Document the required GitHub secrets in `.github/workflows/build-installer.yml`.

2. **Network connectivity pre-check.** Before booting the test VM, verify from the test host:
   ```bash
   curl -s --max-time 5 https://nb.pleaseee.eu.org:443 > /dev/null
   if [ $? -ne 0 ]; then
     echo "SKIP: NetBird control plane unreachable; cannot enroll test VM."
     exit 0  # Graceful skip, not failure
   fi
   ```

3. **Enrollment timeout and fallback.** The first-boot script's NetBird enrollment step should timeout after 30 seconds with a clear log message: "NetBird enrollment timeout (network down or control plane unavailable); continuing without overlay." The appliance still boots and is reachable via LAN fallback. The test harness detects this in the logs and adjusts expectations: "Test VM lacks overlay IP; falling back to LAN SSH bootstrap."

4. **Overlay IP detection in test harness.** After first boot, query the test VM for its NetBird IP:
   ```bash
   ssh ppsa@<lan-ip> 'netbird status | grep IPv4 | head -1'
   ```
   If no overlay IP is detected, log a WARNING and proceed with LAN SSH (ufw bootstrap). If LAN SSH also fails, FAIL the test with reason: "No network access (overlay or LAN)."

**Detection:**
- Pre-build: `PPSA_NB_SETUP_KEY` and `PPSA_NB_MANAGEMENT_URL` not in GitHub secrets or workflow env.
- Pre-boot: `curl` to control plane times out or returns error.
- Post-boot: Test VM's `/var/log/ppsa-install.log` shows "NetBird enrollment timeout" warning.
- Test harness: Cannot query overlay IP via `netbird status`.
- tty1 screenshot: "Step 5: Configuring NetBird" displayed for > 60 seconds with no progress.

## Moderate Pitfalls

Mistakes that require workarounds or cause data loss, but do not invalidate the release.

### Pitfall 5: Blind Scancode Keystroke Sequence Timing Errors

**What goes wrong:**
The installer's TUI presents multiple screens (GRUB menu, disk selection, YES confirmations), each expecting keystroke input at specific moments. The automation script sends keycodes (scancodes), but the timing is off:
- GRUB menu appears, but the script sends "Enter" (code `1c 9c`) too early, before GRUB is fully rendered. GRUB ignores the keypress; the menu doesn't advance.
- Disk selection screen appears. The script sends "2" + "Enter" (codes `02 82` + `1c 9c`) immediately, but the screen isn't fully painted yet. The "2" keypress is buffered and interpreted later as part of the next screen, causing wrong input.
- The three YES confirmation prompts require uppercase (scancode `2a 15 95` = shift+Y). If timing is off, lowercase "y" is sent, and the prompt aborts with "Invalid input. Exiting."

The installer hangs or exits with "User aborted" before reaching the disk-write step.

**Why it happens:**
- No feedback from the TUI to the test harness: the script doesn't know when each screen is ready.
- Screenshot OCR could detect readiness, but OCR on a 1024x768 terminal with small fonts is unreliable (word wrapping, color codes, rendering artifacts).
- The existing ppsa-installer-test skill uses fixed 2-4 second delays between keystrokes, calibrated for the manual human flow. Automation may try to speed this up, introducing race conditions.
- UEFI BIOS/GRUB boot order and rendering can vary per VirtualBox version or host load.

**Consequences:**
- Installer fails silently: test script reports FAIL without clear reason.
- Troubleshooting requires manual console inspection or screenshot capture to see which screen was reached before failure.
- Flakiness: same script passes on one host, fails on another due to timing jitter.

**Prevention:**
1. **Screenshot-based readiness detection (with fallback).** After each keystroke send, wait for up to 10 seconds and poll screenshots every 1 second:
   ```bash
   for i in {1..10}; do
     VBoxManage controlvm <vm> screenshotpng /tmp/screenshot.png
     if grep_text_in_screenshot "disk.*selection" || grep_text_in_screenshot "PPSA Installer"; then
       break  # Screen ready
     fi
     sleep 1
   done
   ```
   If OCR is unavailable or unreliable, fall back to fixed 3-second delays (safe but slow).

2. **Keystroke validation log.** Record each keystroke sent and the elapsed time since the previous one. Example log:
   ```
   [00:00] GRUB menu → send Enter (1c 9c)
   [00:03] Disk selection → send "2 Enter" (02 82 1c 9c)
   [00:06] Confirmation 1 → send Shift+Y+Enter (2a 15 95 12 92 1f 9f aa 1c 9c)
   ```
   This helps debugging: if the test stalls, the log shows exactly where.

3. **Interactive mode for development.** Add a `--screenshot-on-pause` flag to the test harness:
   ```bash
   ./ppsa-installer-test.sh --iso <path> --screenshot-on-pause
   ```
   After each keystroke, pause and display the screenshot to the terminal, so a developer can see the exact screen state and adjust timing.

4. **Capture full serial/console output.** VirtualBox serial port output can capture tty1 text output (including GRUB and installer progress). Route GRUB's serial output to a file:
   ```bash
   VBoxManage modifyvm <vm> --uart1 0x3f8 4 --uartmode1 file /tmp/serial.log
   ```
   Parse `/tmp/serial.log` for keywords ("Disk Selection", "Confirmation", "Installation complete") to detect screen transitions reliably. This is more robust than screenshot OCR.

**Detection:**
- Installer exits early with "User aborted" or "Invalid input" message in logs.
- Screenshot shows GRUB/TUI screen still displayed; no progress to disk write.
- Screenshot timestamps show <1 second between keystroke and transition (race condition).
- Manual retry with longer delays succeeds.

### Pitfall 6: Docker Pull Timeouts or Registry Transients During First Boot

**What goes wrong:**
First boot's Step 4 ("Deploying Docker stack") pulls container images (`palworld`, `webui`, `grafana`, etc.). The Docker daemon inside the test VM pulls from Docker Hub or other registries. Registry rate limits, transient 502 errors, or slow network cause a pull to timeout after 5-10 minutes. The `docker compose up` command fails with "failed to pull image; HTTP 503 Service Unavailable". The first-boot script logs a warning and continues, but some containers remain unstarted. The smoke test attempts to SSH and check the game server, but `docker ps` shows only 2 of 5 containers running. The test reports FAIL incorrectly.

**Why it happens:**
- Docker's default pull timeout is 10-30 minutes depending on layer size, but registry transients can abort early.
- The first-boot script has a retry loop, but it may give up after 3 retries if the registry is genuinely overloaded.
- The test harness doesn't distinguish between "image pull failed; appliance is broken" and "temporary registry issue; retry later."
- On this host: if Docker on the test host is also pulling images (CI cache warming), the test VM's registry requests compete for bandwidth.

**Consequences:**
- False negative: test reports FAIL even though the appliance logic is correct.
- Flaky tests: 1 in 20 runs fails due to registry transient; CI is unreliable.
- Misleading release notes: "v1.5.0 has container startup issues" when actually it was a 5-minute registry hiccup.

**Prevention:**
1. **Pre-pull images on test host.** Before the test VM boots, pull all required images on the test host:
   ```bash
   for img in thijsvanloef/palworld-server-docker:latest kaiser62/ppsa-webui:latest ...; do
     docker pull $img || echo "Pre-pull failed for $img; may retry in VM"
   done
   ```
   Docker's local layer cache will speed up the VM's pull significantly.

2. **Extended timeout with per-layer logging.** The first-boot script should log each layer hash and timestamp:
   ```bash
   docker compose pull 2>&1 | tee -a /var/log/ppsa-install.log | while read line; do
     echo "[$(date --iso-8601=seconds)] $line" >> /var/log/ppsa-docker-pull.log
   done
   ```
   If a pull takes > 3 min on any single layer, log a diagnostic: "Slow registry detected."

3. **Graceful container-count fallback.** The first-boot script should check how many containers are running:
   ```bash
   RUNNING_COUNT=$(docker ps --format '{{.Names}}' | wc -l)
   if [ $RUNNING_COUNT -lt 4 ]; then
     echo "WARNING: Only $RUNNING_COUNT of 5 containers started. Retrying docker compose up..."
     sleep 10
     docker compose up -d 2>&1 | tee -a /var/log/ppsa-install.log
   fi
   ```

4. **Test harness: Defer to logs on partial failure.** If the smoke test finds some containers missing, query `/var/log/ppsa-docker-pull.log`:
   - If the log shows "HTTP 503 Service Unavailable" or timeout, mark it as PARTIAL_FAIL (flaky, may retry).
   - If the log shows clean pull success but containers are still down, mark it as FAIL (real bug).
   - Report both in the summary: "FAIL: Containers did not start (pull succeeded; check compose configuration)."

**Detection:**
- Test VM: `docker ps` shows < 5 containers running.
- `/var/log/ppsa-docker-pull.log` shows "HTTP 503" or "timeout" errors.
- Immediate retry (without rebooting the test host) succeeds, indicating transient.
- Manual pull from test host succeeds quickly, but first-boot pull was slow.

### Pitfall 7: SSH Bootstrap Unreachable (LAN Firewall or DHCP Failure)

**What goes wrong:**
The test VM completes first boot and should be reachable via LAN SSH. But the automation script tries to SSH to the test VM's IP and gets "Connection refused" or "Host unreachable". Reasons:
- DHCP failed; the test VM has no IP on the bridged NIC.
- The firewall rules aren't yet applied; the test VM's SSH is listening, but `ufw` (installed during first boot) is blocking it.
- The appliance's `ppsa-firewall-apply.sh` runs and applies the `WG_FRIENDS` chain, which restricts SSH to the `100.64.0.0/10` (NetBird) subnet. Since this is the LAN fallback, SSH from the LAN is now blocked.
- The tty1 banner says "SSH: ppsa@<lan-ip>", but that IP is outdated (DHCP lease renewal changed it).

SSH bootstrap fails before the smoke test can run. The test harness cannot reach the appliance and reports FAIL.

**Why it happens:**
- The test harness assumes DHCP will assign an IP quickly (< 10 seconds), but Debian boot and interface negotiation can take 20-30 seconds.
- The firewall chain is applied early in the first-boot script (Step 6), before a console user could have registered a NetBird peer or adjusted settings. SSH from LAN is then blocked by default.
- The tty1 banner is printed from `scripts/ppsa-firstboot.sh` and is not updated if DHCP renews the IP later.
- No heartbeat or status endpoint accessible before the Docker stack is fully up.

**Consequences:**
- SSH bootstrap times out; test harness reports FAIL before the appliance is even reached.
- The appliance is actually fine, but unreachable during the critical test window.
- Debugging requires console inspection to see the real IP and logs; very token-heavy.

**Prevention:**
1. **DHCP discovery with polling.** After the test VM boots, poll its IP address from the VirtualBox bridge or use `arp-scan`:
   ```bash
   for i in {1..30}; do
     BRIDGE_IP=$(arp-scan -I "Realtek Gaming 2.5GbE Family Controller" -l 2>/dev/null | grep -i "ppsa" | awk '{print $1}' | head -1)
     if [ -n "$BRIDGE_IP" ]; then break; fi
     sleep 1
   done
   if [ -z "$BRIDGE_IP" ]; then
     echo "FAIL: Test VM did not obtain DHCP IP in 30 seconds"
     exit 1
   fi
   ```

2. **Health check endpoint before Docker is up.** Add a simple systemd one-shot unit that starts a minimal HTTP server on port 8081 (before Docker) to signal boot progress:
   ```bash
   # In chroot during build:
   cat > /etc/systemd/system/ppsa-boot-probe.service <<EOF
   [Unit]
   Description=PPSA Boot Health Probe
   After=network-online.target
   [Service]
   Type=simple
   ExecStart=/bin/bash -c 'while true; do echo "OK"; done | nc -l -p 8081 -q 1'
   [Install]
   WantedBy=multi-user.target
   EOF
   ```
   The test harness can poll `curl -sf http://<lan-ip>:8081` to detect boot is underway.

3. **Firewall rule: Allow LAN SSH during first boot.** Modify the first-boot script to allow LAN SSH until a NetBird peer is registered:
   ```bash
   # Step 1 (before firewall): whitelist LAN SSH
   UFW_ALLOW_LAN="192.168.1.0/24"  # Match the bridged NIC subnet
   ufw allow from $UFW_ALLOW_LAN to any port 22 proto tcp
   
   # Step 8 (after NetBird registration): remove the LAN rule if overlay is up
   if netbird status | grep -q "Connected"; then
     ufw delete allow from $UFW_ALLOW_LAN to any port 22 proto tcp
   fi
   ```

4. **SSH with retry and diagnostic output.** The test harness should retry SSH with exponential backoff and report the reason if it fails:
   ```bash
   ssh_with_retry() {
     local host="$1" cmd="$2" max_tries=10 try=0
     while [ $try -lt $max_tries ]; do
       if ssh -o ConnectTimeout=5 "ppsa@$host" "$cmd"; then
         return 0
       fi
       try=$((try + 1))
       echo "[SSH try $try/$max_tries] Retrying in 3s..." >&2
       sleep 3
     done
     echo "FAIL: SSH to $host exhausted after $max_tries tries"
     return 1
   }
   ```

**Detection:**
- SSH connection times out or refused immediately after test VM boot.
- `arp-scan` shows no IP for the test VM's MAC.
- DHCP server logs (on the bridged NIC) show no lease granted to the test VM.
- Firewall logs on the test VM show SSH packets dropped (if logs are captured).
- `netbird status` on test VM shows "Disconnected" (overlay not up yet).

## Minor Pitfalls

Low-impact mistakes with straightforward mitigations.

### Pitfall 8: VM Disk Not Large Enough for Docker Image Decompression

**What goes wrong:**
The installer decompresses the seed image from the zstd-compressed ISO. The 40GB VDI allocated disk is just barely large enough, but if the test host's filesystem is full or nearly full, the decompress fails with "No space left on device". The install aborts at "Step 3: Deploying". The test reports FAIL.

**Why it happens:**
- The test harness creates a 40GB VDI, which is sufficient for the final installed image. But during decompression, temporary files (partial tar, block device buffers) consume disk space. Peak space usage can hit 45-48GB.
- If the test harness runs on a shared volume or on the host's default D: drive, and disk space is < 50GB free, the decompress will fail.

**Consequences:**
- Test fails; actual appliance image is fine.
- Debugging requires checking disk space on the test host.
- Retry after freeing space works fine.

**Prevention:**
1. **Pre-flight disk-space check.** Before creating the VDI:
   ```bash
   FREE_GB=$(df "H:\dev\palimage" | awk 'NR==2 {print $4 / 1024 / 1024}')
   if [ $(echo "$FREE_GB < 60" | bc -l) -eq 1 ]; then
     echo "FAIL: Only ${FREE_GB}GB free; need 60GB for decompression. Clean up and retry."
     exit 1
   fi
   ```

2. **VDI size recommendation.** Document that test VMs should be 50GB minimum (not 40GB). Update the ppsa-installer-test skill.

**Detection:**
- Installer logs show "No space left on device" during tar decompression.
- `df` on test host shows < 5GB free during first boot.
- Retry after `rm -rf H:\dev\palimage\<ver>\temp*` succeeds.

### Pitfall 9: Test VM's Random MAC Address Causes Duplicate DHCP Leases

**What goes wrong:**
Each test run creates a new VM with a random MAC address. If the DHCP server is not configured to clean up old leases (or leases are long-lived), multiple stale IPs may be assigned across sequential test runs. A test script might attempt to connect to an old IP that was assigned to a previous VM, finding a different box (or no box). Or the new test VM doesn't get an IP because the DHCP server thinks it's already assigned to another MAC.

This is rare on well-configured DHCP servers but can happen in lab/dev environments.

**Consequences:**
- Intermittent SSH failures to wrong IP or stale host key mismatches.
- Cleanup scripts try to tear down a different VM.

**Prevention:**
1. **Assign stable MAC per test run.** Generate a stable MAC based on the test run ID or timestamp:
   ```bash
   TEST_MAC=$(echo "cccccc$(printf '%06x' $((RANDOM % 16777215)))" | sed 's/\(..\)/\1:/g')
   VBoxManage modifyvm <vm> --macaddress1 "$TEST_MAC"
   ```

2. **Query current IP from VirtualBox guest properties or ARP.** Use `arp-scan` (already recommended above) to find the test VM's current IP, rather than relying on DHCP reservation.

**Detection:**
- SSH attempts to outdated IP (from previous run).
- Host key mismatch warning (connecting to a different host with the same IP).
- DHCP server shows multiple leases for similar hostnames (ppsa-test-1, ppsa-test-2, ...).

## Phase-Specific Warnings

| Phase Topic | Likely Pitfall | Mitigation |
|-------------|---------------|------------|
| Boot-chain verification | Signature corruption or fallback misdetection | Pre-boot ESP inspection + VBox EFI flag + signed-chain logging |
| Installer automation | Hangs masquerading as progress; flakiness | Heartbeat timestamps, activity polling, verbose logging, host resource pre-check |
| WireGuard tests (if re-enabled) | Identity theft; shared `10.8.0.2` on live server | Hub API check before boot, disable WG by default, cleanup mandate |
| NetBird enrollment | Missing credentials or control-plane unreachable | Pre-build credential injection, network pre-check, enrollment timeout fallback |
| Blind TUI keystrokes | Timing races, wrong input buffering | Screenshot/serial-port detection, keystroke logging, interactive mode for dev |
| Docker first-boot | Registry transients masquerading as application failures | Pre-pull on test host, per-layer logging, graceful degradation |
| SSH bootstrap | Firewall or DHCP blocking LAN access | DHCP discovery polling, health-check port, allow-LAN rule during first boot |
| Disk space | Decompression fails due to full filesystem | Pre-flight disk-space check (60GB), VDI size recommendation |

## Sources

- PPSA existing manual flow: `.claude/skills/ppsa-installer-test/SKILL.md` (blind scancode timings, first-boot phases, SSH bootstrap, known VBox/WSL2 hazards)
- Project constraints: `.planning/PROJECT.md` (Secure Boot chain, NetBird setup, identity theft warning, build policy)
- Build script: `scripts/build-live-usb.sh` (signed shim/GRUB conditional logic, fallback to grub-mkstandalone, zstd decompression)
- First-boot script: `scripts/install.sh` (9-step orchestration, Docker pull retry, progress file updates)
- Docker Compose: `compose/docker-compose.yml` (service definitions, health checks, volume mounts)
- PPSA memory notes: `~/.claude/projects/.../memory/MEMORY.md` (WSL2/Hyper-V contention, WG dormancy fixes, DNS public-only bug)
