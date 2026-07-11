---
name: ppsa-guest-ops
description: Interact with a running PPSA appliance VM or box - console injection, LAN SSH access, deploying uncommitted patches (WebUI container code, host scripts, systemd units), WebUI API testing, and VirtualBox-on-this-host gotchas (soft lockups, no guest additions). Use for any hands-on work inside a booted PPSA system.
---

# PPSA guest operations (patch + test loop)

## Access ladder

1. **Console screenshots** (always works): `VBoxManage controlvm <vm> screenshotpng <file>`.
2. **Console injection** (blind typing into tty1, which auto-logs-in `ppsa`): virtualbox-mcp `exec_command` with `use_console_injection: true`. No guest additions in PPSA images — guest-exec never works; injection + screenshot is the bootstrap path.
3. **LAN SSH** (needs one injected command first — LAN SSH is blocked by design, WG-only):
   ```
   sudo ufw insert 1 allow from 192.168.1.0/24 to any port 22 proto tcp
   ```
   Then from Windows (sshpass absent, use PuTTY tools):
   ```bash
   plink -ssh -batch -hostkey "SHA256:<shown-on-first-attempt>" -pw ppsa ppsa@<vm-ip> "<cmd>"
   pscp  -batch -hostkey "SHA256:<...>" -pw ppsa <local-files> ppsa@<vm-ip>:/tmp/
   ```
   `ppsa` has passwordless sudo (`sudo -n`). Without `-hostkey` plink hangs on the interactive prompt even with `echo y |`.

## Deploying uncommitted patches

- **WebUI code** (FastAPI, `docker/webui/app/main.py`): `pscp` to `/tmp`, then
  `sudo docker cp /tmp/main.py ppsa-webui:/app/main.py && sudo docker restart ppsa-webui`. ~8s to healthy.
- **Host scripts** (`/opt/ppsa/scripts/`): `pscp` to `/tmp`, then
  `sudo cp /tmp/<f> /opt/ppsa/scripts/ && sudo sed -i 's/\r$//' /opt/ppsa/scripts/<f> && sudo chmod +x /opt/ppsa/scripts/<f>`.
  **CRLF strip is mandatory** — files come from a Windows checkout.
- **systemd units**: `sudo cp /tmp/<unit> /etc/systemd/system/ && sudo systemctl daemon-reload && sudo systemctl enable --now <name>.path` (or `.service`).

## WebUI API testing

Login = HTTP Basic on POST, returns JWT:
```bash
TOKEN=$(curl -s -X POST http://localhost:8080/api/login -u admin:admin | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])')
curl -s http://localhost:8080/api/<route> -H "Authorization: Bearer $TOKEN"
```
Routes: dashboard, system, players, logs, backup/{status,config,trigger}, mods, wireguard/{status,config,connect,disconnect}, wifi/*, firewall/{config,status,apply,reset}.

**Container namespace limits (do not re-learn this the hard way):** ppsa-webui is bridge-networked, NOT pid:host. `nsenter -t 1` inside it hits the CONTAINER's PID 1 — `_host_exec` only chroots into the RO `/:/host` bind. Works: nmcli/hostapd (socket-based via /host/run). Silently broken: iptables (lands in container netns), writes outside `/etc/ppsa` (EROFS). Host-privileged work goes through `/etc/ppsa` trigger files + host systemd `.path` units (`ppsa-wg-manual-apply.path`, `ppsa-firewall-request.path`). `/etc/ppsa` is rw-mounted into the container; `docker.sock:ro` still allows full API use (exec/restart).

## Runtime layout cheat sheet

- Stack: `cd /opt/ppsa/compose && sudo docker compose ...`; 5 containers: ppsa-webui, ppsa-palworld, ppsa-watchtower, ppsa-wgdashboard, ppsa-backup.
- First boot: `ppsa-firstboot.service` → `/opt/ppsa/scripts/install.sh`, marks `/opt/ppsa/.installed`; idempotent, re-runs after reset if unfinished.
- Boot chain: wg-quick@wg0 → ppsa-wireguard-register → ppsa-docker-compose → ppsa-firewall-restore.
- Firewall: WG_FRIENDS chain (INPUT jump for 10.8.0.0/24), config `/etc/ppsa/firewall.json`, chain export `/etc/ppsa/wg_friends.rules`, apply log `/etc/ppsa/firewall-apply.log`.
- WG files: `/etc/wireguard/wg0.conf`, `/etc/ppsa/wireguard.json` (baked), `/etc/ppsa/wireguard-fallback.conf`, status snapshot `/etc/ppsa/wg-status.json`.

## VirtualBox-on-this-host gotchas

- **Soft lockups:** first-boot docker pull "stalls" (same layer hash >10 min) + kernel `watchdog: BUG: soft lockup` on console = WSL2/Hyper-V starving VBox, not network. Fix: host `wsl --shutdown`, then `VBoxManage controlvm <vm> reset`.
- Registry pull DNS failures at first boot are transient; a reboot retries (ppsa-docker-compose.service).
- Always bridged NIC ("Realtek Gaming 2.5GbE Family Controller"), never NAT (breaks WG test).
- WG identity theft: see ppsa-wg-hub-ops skill — kill WG in test VMs if the real server is live.
