---
name: ppsa-installer-test
description: Install PPSA from an installer ISO into a fresh VirtualBox VM and run the full smoke/functional test. Use when asked to test an installer ISO, verify a release build, or reproduce the appliance install flow. Covers VM creation, blind TUI keystrokes (scancodes), first-boot phases, SSH access recipe, and the verification checklist.
---

# PPSA installer ISO test (VirtualBox)

End-to-end recipe: fresh VM → installer TUI → installed first boot → functional verification. All steps proven working on v1.2.15/v1.2.17.

## Hard rules

- Builds come from GitHub Actions only. ISO downloads: `aria2c -x16`, to `H:\dev\palimage\<ver>\` (never D:). Decompress `.iso.zst` with `zstd -d`.
- **Identity theft warning:** every image bakes the same WG identity `ppsa-server`/`10.8.0.2`. If the real remote server is LIVE, the test VM steals its tunnel on handshake. Either confirm the real box is down (hub API, below) or kill WG in the VM immediately after boot: `sudo systemctl disable --now ppsa-wireguard-register wg-quick@wg0; sudo wg-quick down wg0`.
- Hub check (wg-easy v15 API):
  ```bash
  curl -s -c cj.txt -X POST http://pleaseee.eu.org:51831/api/session -H 'Content-Type: application/json' -d '{"username":"admin","password":"overengineered","remember":false}'
  curl -s -b cj.txt http://pleaseee.eu.org:51831/api/client   # look at latestHandshakeAt/endpoint for "ppsa-server"
  ```

## Verification pipeline

```
CI build (GitHub Actions) --> boot ISO in VBox --> first boot completes
    --> [Phase 1: SSH overlay setup] --> [Phase 2: smoke-test.py] --> PASS / FAIL
```

Phase 1 (`docs/netbird-test-peer.md`) gives the test VM a stable NetBird DNS
label and SSH reachable over the overlay. Phase 2
(`scripts/ppsa-smoke-test.py`) drives the full install verification checklist
over that SSH connection and returns a single pass/fail summary.

## 1. Create VM (PowerShell)

```powershell
$vb = "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe"
$name = "ppsa-test"
& $vb createvm --name $name --ostype Debian_64 --register --basefolder "H:\dev\palimage\vms"
& $vb modifyvm $name --memory 10240 --cpus 4 --nic1 bridged --bridgeadapter1 "Realtek Gaming 2.5GbE Family Controller" --boot1 dvd --boot2 disk --firmware efi --graphicscontroller vmsvga --vram 16
& $vb createmedium disk --filename "H:\dev\palimage\vms\$name\$name.vdi" --size 40960 --format VDI
& $vb storagectl $name --name SATA --add sata --controller IntelAhci --portcount 2
& $vb storageattach $name --storagectl SATA --port 0 --device 0 --type hdd --medium "H:\dev\palimage\vms\$name\$name.vdi"
& $vb storageattach $name --storagectl SATA --port 1 --device 0 --type dvddrive --medium "H:\dev\palimage\<ver>\ppsa-installer-vX.Y.Z.iso"
& $vb startvm $name --type headless
```

- **Bridged, not NAT.** NAT breaks the WG test (can't reach hub from same host + hub pollution). Bridge to the active wired NIC.
- EFI mandatory (tests the signed shim/GRUB Secure Boot chain layout; VBox EFI doesn't enforce SB but the boot path is the same).
- No guest additions in the image — all guest interaction is screenshots + keyboard scancodes + (later) SSH.

## 2. Drive the installer (blind, via scancodes)

Screenshot to see state at each step:
```
VBoxManage controlvm <vm> screenshotpng <file.png>
```

1. **GRUB live menu** (~75s after start): press Enter → `keyboardputscancode 1c 9c`
2. **PPSA Installer TUI** (~60s later): lists whole disks. Select disk 1 + Enter:
   `keyboardputscancode 02 82 1c 9c`
3. **3× YES confirmation** — MUST be uppercase; lowercase "yes" aborts. Shifted YES + Enter scancode sequence, sent 3 times with ~4s pauses:
   `keyboardputscancode 2a 15 95 12 92 1f 9f aa 1c 9c`
4. Installer wipes the disk, decompresses + writes the image (~4 min for 40G VDI), grows the partition, then reboots into the installed system **by itself** (ISO can stay attached; it boots from disk). Detach ISO afterwards if you want to be tidy:
   `VBoxManage storageattach <vm> --storagectl SATA --port 1 --device 0 --type dvddrive --medium none` (VM must be off, or use `emptydrive` live).

## 3. First boot (installed system)

tty1 shows "PPSA First Boot Setup", 8 steps. Step 4 (Deploying Docker stack) pulls all images — **10–20+ min**, status line updates slowly; don't declare it stalled unless the SAME layer hash sits unchanged >10 min. Transient registry DNS failures happen; a reboot retries the pull (`ppsa-docker-compose.service` runs once `/opt/ppsa/.installed` exists).

**Stall gotcha (proven 2026-07-11 on ppsa-1217-fresh):** if the status line
freezes on the SAME layer hash / same log line >5-10 min, Ctrl-C + screenshot
— kernel `watchdog: BUG: soft lockup` / `rcu_preempt kthread starved` /
"OOM is now expected behavior" means the GUEST is resource-starved, from two
possible sources (check both):
1. **VM too small.** 4GB/2cpu is NOT enough once the palworld container
   starts (game server alone eats ~4GB+). Use 10240MB/4cpu minimum
   (`VBoxManage modifyvm <vm> --memory 10240 --cpus 4`, VM powered off).
2. **WSL2/Hyper-V starving VirtualBox** on the host: `wsl --shutdown`, then
   reset.
Recovery is safe either way: the first-boot service is idempotent and re-runs
install on next boot until step 8 marks `/opt/ppsa/.installed`; already-pulled
docker images are kept, so the retry is fast.

When done, tty1 shows the banner: `Web UI: http://<lan-ip>:8080  Login: admin/admin`, `SSH: ppsa@<lan-ip>  Password: ppsa`, and auto-logs-in `ppsa` on tty1.

## 4. Get shell access

LAN SSH is BLOCKED by design (WG-only). Recipe:

1. Console-inject a ufw exception (blind typing into tty1 — works because tty1 auto-logs-in `ppsa`):
   ```
   exec_command vm_name=<vm> use_console_injection=true command="sudo ufw insert 1 allow from 192.168.1.0/24 to any port 22 proto tcp"
   ```
   (virtualbox-mcp exec_command falls back to console injection; guest-exec service is absent.)
2. Screenshot to confirm "Rule inserted".
3. SSH from Windows with plink (sshpass absent). First run shows the host key; pin it:
   ```bash
   plink -ssh -batch -hostkey "SHA256:<from-first-attempt>" -pw ppsa ppsa@<vm-ip> "<cmd>"
   ```
   `ppsa` has passwordless sudo (`sudo -n`).
4. Copy files in with pscp (same -hostkey/-pw flags).

### Phase 1+ path: SSH over NetBird overlay (steady state)

After the one-time console bootstrap, the Phase 1 procedure
([`docs/netbird-test-peer.md`](../../docs/netbird-test-peer.md)) can set up a
persistent NetBird test-peer identity and stable DNS label. Once that's done,
subsequent access uses plain SSH to the NetBird address — no console injection
or ufw exception needed.

From the designated NetBird dev peer (verify with `netbird status` locally first):

```bash
# Windows (plink):
plink -ssh -batch -hostkey "SHA256:<from-first-attempt>" -pw ppsa ppsa@<netbird-dns-label> "<cmd>"

# Linux/macOS:
ssh -o StrictHostKeyChecking=accept-new ppsa@<netbird-dns-label>
```

The NetBird DNS label (e.g. `ppsa-ppsa-test.nb.pleaseee.eu.org`) is stable across
reboots and reinstalls of the same logical test VM. See
`docs/netbird-test-peer.md` for the full test-peer setup procedure including the
one-time console-inject enrollment step that creates this identity.

## 5. Verification checklist

### Automated smoke test (canonical)

After SSH access is established (via Phase 1 NetBird path or ufw bootstrap),
run the one-shot smoke test script from the developer host:

```bash
# On the dev host (Windows: uses plink, Linux: uses ssh):
python scripts/ppsa-smoke-test.py <netbird-dns-label>
# or if only the overlay IP is known:
python scripts/ppsa-smoke-test.py 100.70.169.201
```

The script runs ~26 checks across 10 groups (SSH, Auth, Stack, System,
Firewall, NetBird, WG Dormancy, Backup, nb.12 Regression Guard, API
Integrity). Output: one PASS/FAIL summary to stdout, raw output to
`smoke-test-logs/ppsa-smoke-*.log`.

A **PASS** result means the install is good. A **FAIL** result lists every
failed check with the assertion that triggered it, plus the full command
output in the log file for debugging.

See `scripts/ppsa-smoke-test.py --help` for CLI options (custom SSH port,
password, key file, log directory, verbose mode).

### Manual ad-hoc checks (for development)

Quick one-liners for investigation during development (not for release
verification):

```bash
# Container status
sudo -n docker ps --format '{{.Names}} {{.Status}}'

# Firewall chain (from the WebUI export, not raw iptables — see _host_exec limits)
curl -sf http://localhost:8080/api/firewall/status -H "Authorization: Bearer $TOKEN"

# NetBird connectivity
curl -sf http://localhost:8080/api/netbird/status -H "Authorization: Bearer $TOKEN"

# WebUI login + token (HTTP Basic on POST)
TOKEN=$(curl -s -X POST http://localhost:8080/api/login -u admin:admin | python -c 'import sys,json;print(json.load(sys.stdin)["token"])')
```

**Reboot survival:** run `python scripts/ppsa-smoke-test.py <address>` after
a reboot. Everything must come back with zero manual steps.

## 6. Patch-under-test deployment (when testing uncommitted fixes)

- WebUI code: `pscp main.py → /tmp`, then `sudo docker cp /tmp/main.py ppsa-webui:/app/main.py && sudo docker restart ppsa-webui`.
- Host scripts: `pscp → /tmp`, `sudo cp /tmp/<f> /opt/ppsa/scripts/ && sudo sed -i 's/\r$//' /opt/ppsa/scripts/<f> && sudo chmod +x ...` (CRLF strip essential — files come from Windows checkout).
- systemd units: `sudo cp /tmp/<unit> /etc/systemd/system/ && sudo systemctl daemon-reload && sudo systemctl enable --now <name>.path`.

## Cleanup

Power off releases the 10.8.0.2 identity. Delete VM: `VBoxManage unregistervm <vm> --delete`. If a junk duplicate `ppsa-server` peer appeared on the hub (old register.sh bug), delete via `DELETE /api/client/<id>` with the session cookie.
