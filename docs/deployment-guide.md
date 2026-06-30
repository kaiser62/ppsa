# PPSA Deployment Guide

**Version:** v1.1.11 (commit `75f990c`, master branch)
**Last updated:** 2026-06-30
**Applies to:** PPSA v1.1.10+

Tested on:
- v1.1.10 — VM at `192.168.1.158`
- v1.1.11 — VM at `192.168.1.118`

---

## 1. Overview

PPSA (Palworld Portable Server Appliance) is a self-contained, bootable image
that turns any x86_64 machine into a dedicated Palworld game server. The image
runs Debian 13 (Trixie) and the entire PPSA stack (Palworld server, WebUI,
WireGuard dashboard, backup agent, Watchtower) as Docker containers. You write
the image to a USB drive (or run it as a VDI/VM), boot the target machine,
and a web-based control panel comes up on port 8080.

This guide is for two roles:

- **Server admin (you).** The person who owns the host, runs the build, deploys
  the image, and operates the PPSA WebUI.
- **Players (your friends).** The people who install the WireGuard app, import
  a `.conf` file, and play Palworld on the server.

When you finish this guide you will have:

- A running PPSA host reachable at `http://<ppsa-ip>:8080` (LAN).
- A WireGuard tunnel from the PPSA host to a wg-easy v15 instance
  (`10.8.0.0/24`).
- A Palworld dedicated server reachable on the WireGuard subnet at
  `<ppsa-wg-ip>:8211/udp`.
- Per-player onboarding via the wg-easy web UI.

---

## 2. Prerequisites

### Server admin (you)

- An x86_64 host (USB boot or VirtualBox). Minimum 1 vCPU / 4 GB RAM; 4 vCPU
  / 8 GB RAM is the production target. v1.1.11 is verified working on
  1 vCPU / 4 GB.
- A home network with a router that can do DHCP (any consumer router does).
- A Linux, WSL, or macOS machine for the local builder (only needed if you
  build from source; otherwise you can download a release).
- For WireGuard: access to a wg-easy v15 instance. The reference deployment
  in this guide is the homeserver at `192.168.1.140` running wg-easy on
  `10.8.0.0/24`.
- For external player access: a router that can forward UDP and TCP ports
  (the homeserver's router in this guide — UDP 51830 and TCP 51831 to the
  wg-easy host). The PPSA host itself needs no port forwards.

### Players (your friends)

- A Palworld game client (Steam).
- The WireGuard app on their platform (Windows / macOS / Linux / iOS / Android).
- A `.conf` file from the wg-easy admin.

---

## 3. Choose your deployment method

| Method | Best for | Trade-offs |
|--------|----------|------------|
| **USB** (`.img`) | Dedicated hardware with no hypervisor | Needs a USB 3.0+ stick (8 GB+); auto-resize fills the drive on first boot |
| **VirtualBox VDI** (`.vdi`) | Testing, lab, dev | Runs in a VM on Windows / macOS / Linux; convenient snapshots |
| **Bare metal / SSD** | Best performance | Write the same `.img` to an internal SSD via a USB-SATA adapter, or boot from USB and `dd` to `/dev/sda` |

The image is identical across all three. Pick the disk format you need
during release download (section 4).

---

## 4. Get the image

### Option A — Download a release (easiest)

```bash
# From a machine with gh CLI
gh release download v1.1.11 -R kaiser62/ppsa \
  -p "ppsa-*.zst" -p "ppsa-*.sha256" \
  -D ./ppsa-release
```

Or browse to [github.com/kaiser62/ppsa/releases](https://github.com/kaiser62/ppsa/releases)
and download the assets manually:

| Asset | Use for |
|-------|---------|
| `ppsa-usb-v1.1.11.img.zst` | Physical USB / SSD (recommended) |
| `ppsa-vbox-v1.1.11.vdi.zst` | VirtualBox VM |

### Option B — Trigger a CI build (medium)

You need the GitHub Actions secrets configured first (see "CI build" below).
Then:

```bash
gh workflow run build-release.yml -f version=vX.Y.Z
```

CI builds both `.img` and `.vdi` in roughly 5 minutes. The release is a draft
— review it, then publish from the GitHub UI.

### Option C — Build locally (full control)

```bash
git clone https://github.com/kaiser62/ppsa.git
cd ppsa
sudo bash scripts/build-live-usb.sh --output ppsa-usb.img
```

The PowerShell orchestrator on Windows is `scripts/Start-PpsaBuilder.ps1`:

```powershell
pwsh ./scripts/Start-PpsaBuilder.ps1 -Version v1.1.11
```

### Bake WireGuard creds at build time (v1.1.10+)

If you want the PPSA host to auto-register on first boot, copy the WG config
template and fill in your wg-easy credentials before building:

```bash
# Repo root
cp wireguard.local.json.example wireguard.local.json
```

Edit `wireguard.local.json`:

```json
{
  "enabled": true,
  "api_url": "http://192.168.1.140:51831",
  "api_user": "admin",
  "api_password": "your-wg-easy-admin-password",
  "peer_name": "ppsa-server",
  "preferred_ip": "10.8.0.2"
}
```

`wireguard.local.json` is git-ignored. The builder writes it into
`/etc/ppsa/wireguard.json` (chmod 600) inside the image. First boot will
auto-register as a peer — no WebUI interaction needed.

CI builds use repo secrets instead. Add these at
**Settings → Secrets and variables → Actions** in the GitHub repo:

| Secret | Example |
|--------|---------|
| `PPSA_WG_API_URL` | `http://pleaseee.eu.org:51831` |
| `PPSA_WG_API_USER` | `admin` |
| `PPSA_WG_API_PASS` | `your-wg-easy-admin-password` |
| `PPSA_WG_PEER_NAME` | `ppsa-server` (optional) |
| `PPSA_WG_PREFERRED_IP` | `10.8.0.2` (optional) |

---

## 5. Deploy to USB

```bash
zstd -d ppsa-usb-v1.1.11.img.zst
```

### Windows (Rufus)

1. Open **Rufus** → select your USB drive.
2. Click **SELECT** → choose `ppsa-usb-v1.1.11.img`.
3. Click **START** → choose **DD image mode** (not ISO mode!) → OK.
4. Wait for the write to complete (3-10 minutes on USB 3.0).
5. Eject the USB safely.

### Linux / macOS

```bash
sudo dd if=ppsa-usb-v1.1.11.img of=/dev/sdX bs=4M status=progress conv=fsync
sync
```

Replace `/dev/sdX` with your actual USB device. Triple-check the target —
`dd` does not warn.

---

## 6. Deploy to VirtualBox

```bash
zstd -d ppsa-vbox-v1.1.11.vdi.zst
```

In VirtualBox:

1. **Machine → New** → Name: `ppsa`.
2. Type: **Linux**, Version: **Debian (64-bit)**.
3. Memory: **4096 MB** minimum, **8192 MB** recommended.
4. CPU: **1** for testing (a vboxguest bug affects 2+ vCPU on some hosts
   with kernel RCU stalls; see Troubleshooting). **4** vCPU for production.
5. **Use an existing virtual hard disk file** → select `ppsa-vbox-v1.1.11.vdi`.
6. **Settings → Network → Adapter 1**: Attach to **Bridged Adapter** (so the
   VM gets a real LAN IP). Choose the NIC that connects to your router.
7. **Settings → System → Enable EFI** (recommended; legacy BIOS also works).
8. **Start** the VM.

### From PowerShell

```powershell
VBoxManage createvm --name "ppsa" --ostype "Debian_64" --register
VBoxManage modifyvm "ppsa" --memory 4096 --cpus 1 --vram 32 `
  --nic1 bridged --bridgeadapter1 "<your-nic-name>" `
  --boot1 disk --boot2 none --boot3 none --boot4 none `
  --firmware efi64 --macaddress1 auto
VBoxManage storagectl "ppsa" --name "SATA" --add sata --controller IntelAhci
VBoxManage storageattach "ppsa" --storagectl "SATA" --port 0 --device 0 `
  --type hdd --medium "ppsa-vbox-v1.1.11.vdi"
VBoxManage startvm "ppsa" --type gui
```

---

## 7. First boot — what to expect

1. BIOS/EFI → GRUB menu → auto-boots into PPSA Linux.
2. Console login prompt appears on tty1 within a few seconds.
3. The `ppsa-install.service` starts in the background.
4. **Watch progress on tty1.** The `ppsa-firstboot.service` replaces the getty
   and shows an 8-step progress UI:

   ```
   1/8 Resizing root partition
   2/8 Starting Docker
   3/8 Configuring environment
   4/8 Deploying Docker stack
   5/8 Installing Wi-Fi onboarding
   6/8 Connecting to PPSA WireGuard network   <-- auto-registers with wg-easy
   7/8 Configuring firewall
   8/8 Marking installation complete
   ```

5. **Step 6** is the WireGuard registration. v1.1.10+ polls the wg-easy API
   for up to **120 seconds** with 2/4/8/10/10s backoff before failing, so
   a briefly-unreachable wg-easy host will not abort the install.
6. The first boot takes **3-10 minutes** total, mostly waiting for Docker
   to pull images and Palworld to download its ~3.8 GB Steam update.
7. When you see `Setup Complete!` the WebUI is reachable.

Find the PPSA IP from the tty1 banner (it shows `Web UI: http://...`),
or SSH in:

```bash
ssh ppsa@<ppsa-ip>
# password: ppsa
```

---

## 8. Open the WebUI

Open a browser on any machine on the same network:

```
http://<ppsa-ip>:8080
```

Default login: **`admin` / `admin`**. Change the admin password immediately
in **Settings**.

Click through every tab once to confirm the stack is healthy:

- **Dashboard** — server FPS, version, player count
- **Players** — connected player list
- **Controls** — start / stop / restart Palworld container
- **Config** — server settings (server name, password, max players)
- **System** — host info, Docker container status
- **Backup** — last backup timestamp, backup volume
- **Wi-Fi** — Wi-Fi network selection (only on hardware with a wireless NIC)
- **Firewall** — `WG_FRIENDS` chain management
- **WireGuard** — tunnel status, IP, register / disconnect actions
- **Settings** — admin password

If a tab hangs on "Loading..." or returns a 500, the underlying container
is still starting. See Troubleshooting.

---

## 9. Configure WireGuard

### 9a. You baked creds in at build time

Nothing to do. First boot already auto-registered the PPSA host as a peer
in your wg-easy network. Verify:

1. WebUI → **WireGuard** tab → status shows `Connected` with an IP in
   `10.8.0.0/24` (typically `10.8.0.2`).
2. The tty1 completion banner also shows the assigned WG IP.
3. The firstboot screen has three states:
   - `registered` — handshake done, IP visible
   - `registering` — the 120s polling is still in progress
   - `not configured` — `wireguard.json` has `enabled:false`; fill it in
     via the WebUI

Sanity check from SSH:

```bash
ssh ppsa@<ppsa-ip>
wg show                      # wg0 with a peer, latest handshake
cat /run/ppsa-wireguard-ip   # e.g. 10.8.0.2
ping -c 3 10.8.0.1           # reach wg-easy server
```

### 9b. You did not bake creds in

1. Get the wg-easy URL, username, and password from your wg-easy admin.
2. WebUI → **WireGuard** tab → fill in:
   - **API URL** — e.g. `http://192.168.1.140:51831`
   - **API user** — always `admin` on wg-easy v15
   - **API password** — the wg-easy admin password
3. Click **Save**, then **Connect**.
4. The register script runs (it polls the API for up to 120s, then
   registers as a peer, downloads the `.conf`, and brings up `wg0`).
5. The assigned WG IP appears in the WebUI WireGuard tab.

### Verify the tunnel

```bash
ssh ppsa@<ppsa-ip>
```

```bash
sudo wg show
#   interface: wg0
#     public key: ...
#   peer: <wg-easy server pubkey>
#     endpoint: <public-ip>:51830
#     latest handshake: 12 seconds ago
#     transfer: 1.2 KiB received, 1.4 KiB sent

cat /run/ppsa-wireguard-ip
# 10.8.0.2

ping -c 3 10.8.0.1
# PING 10.8.0.1 ... 64 bytes from 10.8.0.1: icmp_seq=1 ttl=64 time=2.4 ms
```

If there is no handshake after a minute, check:

- UDP 51830 is forwarded on the homeserver's router to the wg-easy host.
- DNS for the wg-easy hostname (if you used one) resolves on the PPSA host.
- `/etc/ppsa/wireguard.json` has the correct `api_url`, `api_user`,
  `api_password`.

---

## 10. Configure the Palworld server

1. WebUI → **Config** tab.
2. Set the values you care about:

   | Field | Example | Notes |
   |-------|---------|-------|
   | `SERVER_NAME` | `My Palworld Server` | Shown in the server browser |
   | `SERVER_DESCRIPTION` | `Welcome!` | Server browser detail |
   | `MAX_PLAYERS` | `16` | Cap simultaneous players |
   | `ADMIN_PASSWORD` | `strong-pass-here` | In-game admin login |
   | `SERVER_PASSWORD` | (empty) | Set only if you want to gate the server |
   | `RESTAPI_ENABLED` | `true` | Required for the WebUI Players tab |
   | `RCON_ENABLED` | `true` | Required for the WebUI Controls tab |

3. Click **Save Changes**.
4. Click **Restart Palworld Container** (Controls tab).
5. The Palworld container downloads its Steam update on first launch
   (~3.8 GB, takes 10-30 minutes depending on bandwidth).
6. Watch **Controls → Logs** to see the download progress.
7. When the container reports `healthy` and the Dashboard shows
   `Server FPS` and `Version`, the server is ready for players.

The Palworld container resource limits default to **1 vCPU / 2 GB**
(suitable for small VMs). For a production host, raise them in
`/opt/ppsa/.env`:

```bash
PPSA_CPUS=4.0
PPSA_MEMORY=6G
```

Then restart the stack:

```bash
ssh ppsa@<ppsa-ip>
cd /opt/ppsa
sudo docker compose -f compose/docker-compose.yml up -d
```

---

## 11. Connect a player

1. Player installs the WireGuard app on their platform
   ([wireguard.com/install](https://www.wireguard.com/install/)).
2. Player opens the wg-easy web UI in a browser:

   ```
   http://<wg-easy-host>:51831
   ```

   For example: `http://192.168.1.140:51831` on LAN, or
   `http://pleaseee.eu.org:51831` externally.

3. Login as the wg-easy admin.
4. Click **New Client** → enter a name (e.g. `PlayerName`) → **Generate**.
5. Player downloads the `.conf` file.
6. Player imports the `.conf` into the WireGuard app.
7. Player activates the tunnel. They now have a WireGuard IP like
   `10.8.0.4`.
8. In Palworld: **Multiplayer → Add Server** → Address: `<PPSA's WG IP>`
   (e.g. `10.8.0.2`) → Port: `8211` → **Connect**.

If the player gets `Disconnected from server`:

- Wait for the Palworld container to finish the Steam download
  (check the Controls tab; status must be `healthy`).
- Confirm the player's `AllowedIPs` in the imported `.conf` includes
  `10.8.0.0/24` (the default does).
- From the player's machine: `ping 10.8.0.2` should succeed.

---

## 12. Port forwarding (external player access)

The PPSA host itself needs **no port forwards**. Players reach it via the
wg-easy WireGuard tunnel.

The **wg-easy host's router** needs the following forwards:

| Protocol | External port | Forward to | Purpose |
|----------|---------------|------------|---------|
| UDP | 51830 | wg-easy host:51830 | WireGuard tunnel |
| TCP | 51831 | wg-easy host:51831 | wg-easy web UI |

If the wg-easy host is on the same LAN as the PPSA, only the wg-easy
host's router needs forwarding. The PPSA host stays behind the user's
home router with no inbound ports open.

**Do not** forward port 22 (SSH) on the wg-easy host. SSH stays on the
cloudflared tunnel.

---

## 13. Firewall configuration

The PPSA host runs a `WG_FRIENDS` iptables chain that controls what
WireGuard peers (from `10.8.0.0/24`) can reach on the host.

### Defaults (from `10.8.0.0/24 → PPSA`)

| Protocol | Allowed ports | Notes |
|----------|---------------|-------|
| TCP | 22, 80, 443, 8080, 10086, 25575 | SSH, Web, WebUI, WG Dashboard, RCON |
| UDP | 8211, 27015 | Palworld game, Steam query |
| ICMP | enabled | Ping |
| Everything else | DROP | — |

The defaults are baked into `scripts/ppsa-firewall-apply.sh` and the
WebUI data volume.

### Change via WebUI

WebUI → **Firewall** tab → edit the TCP/UDP port lists and the ICMP
toggle → **Save & Apply**.

### Change via the host file

```bash
ssh ppsa@<ppsa-ip>
sudo nano /etc/ppsa/firewall.json
```

```json
{
  "wg_friends_allowed_tcp": [22, 80, 443, 8080, 10086, 25575],
  "wg_friends_allowed_udp": [8211, 27015],
  "wg_friends_allow_icmp": true
}
```

Apply the changes:

```bash
sudo /opt/ppsa/scripts/ppsa-firewall-apply.sh
```

The script rebuilds the `WG_FRIENDS` chain idempotently and persists
the ruleset to `/etc/iptables/rules.v4` and `/etc/ppsa/iptables.rules.v4`.
The `ppsa-firewall-restore.service` brings the rules back on every boot.

---

## 14. Troubleshooting

### The PPSA VM gets no IP

| Cause | Fix |
|-------|-----|
| Bridged adapter pointed at the wrong NIC | VirtualBox → Settings → Network → Adapter 1 → Bridged Adapter → pick the NIC connected to your router |
| DHCP not available | Some guest networks block DHCP. Try a different network or assign a static IP via the WebUI later |
| VM is on `192.168.1.0/24` but your LAN uses a different subnet | Expected. The IP still works, just adjust the URL |

### WebUI shows 500 / Connecting...

Docker is still pulling images, or the Palworld container is downloading
its 3.8 GB Steam update. Wait 5-10 minutes and refresh.

From SSH:

```bash
sudo docker ps -a
sudo docker logs ppsa-palworld --tail 50
```

### Players tab stuck on "Loading..."

Fixed in v1.1.10+. In earlier versions, the `/api/players` endpoint
could return 500 + plain text instead of JSON when the Palworld REST
API was slow to respond. Upgrade to v1.1.10 or later.

### WireGuard tab shows "Not Configured"

`/etc/ppsa/wireguard.json` has `enabled: false` or doesn't exist.
Fill in the creds via the WebUI → WireGuard tab, or write the file
directly on the host (see section 9b).

### WireGuard "registering" forever

The wg-easy API is unreachable. Check, in order:

```bash
ssh ppsa@<ppsa-ip>

# Is the URL reachable from the PPSA host?
curl -sS -m 5 -o /dev/null -w "%{http_code}\n" http://<wg-easy>:51831/api/client
# 000 = network unreachable, 401 = reachable, creds wrong

# DNS resolves?
getent hosts wg.pleaseee.eu.org
# 118.179.74.23

# Is the wg-easy container running? (from the homeserver)
ssh artho@192.168.1.140
docker ps | grep wg-easy
```

If you can reach the URL from a browser but not from the PPSA host,
UDP 51830 is not forwarded on the homeserver's router (the registration
uses the same network path as the tunnel).

### Palworld container "unhealthy"

Normal on first launch — Steam update is downloading. Watch progress:

```bash
sudo docker logs -f ppsa-palworld
```

If the container stays `unhealthy` for more than 30 minutes:

```bash
# Can the container reach Steam?
sudo docker exec ppsa-palworld sh -c "nslookup steamcdn-a.akamaihd.net"
# Or:
sudo docker exec ppsa-palworld sh -c "wget -q -O - https://api.steamcmd.net | head"
```

If DNS is failing, check `/etc/resolv.conf` on the PPSA host and inside
the container.

### SSH works from LAN but not via WireGuard

UDP 51830 is not forwarded on the homeserver's router. The WireGuard
tunnel never establishes, so no traffic flows. See section 12.

### Player connects but immediately gets "Disconnected from server"

Two common causes:

1. **Palworld container not yet ready** — wait until the container is
   `healthy` and the dashboard shows the server version.
2. **Wrong AllowedIPs in the player's `.conf`** — the wg-easy v15 default
   is `0.0.0.0/0` (full tunnel) which works fine. If the file was edited
   to only allow `10.8.0.0/24`, the player can reach the WireGuard subnet
   but not the public internet while the tunnel is up — usually what you
   want. Confirm the config includes the PPSA's WG IP range.

### `favicon.ico 404` in the browser console

Cosmetic. The WebUI SPA does not ship a favicon. Ignore.

### Console tty1 is stuck mid-step

If the firstboot UI is stuck on a single step, the install log is at
`/var/log/ppsa-install.log`:

```bash
ssh ppsa@<ppsa-ip>
sudo tail -100 /var/log/ppsa-install.log
```

To force a re-run:

```bash
sudo rm /opt/ppsa/.installed
sudo systemctl restart ppsa-install.service
```

### Rebuilt vboxguest fix (1-vCPU workaround)

The shipped `vboxguest.ko` may not match the host VirtualBox version.
Symptoms: kernel RCU stalls during `docker compose up`, especially on
2+ vCPUs. Workarounds:

```bash
ssh ppsa@<ppsa-ip>
# Reinstall the dkms module
sudo apt install --reinstall virtualbox-guest-dkms
sudo reboot

# Or disable vboxguest entirely
sudo systemctl disable --now vboxservice
```

The 1-vCPU configuration is not affected.

---

## 15. Maintenance

### Update the PPSA image

Configs in `/opt/ppsa/data` (and the Docker volumes `palworld_data`,
`webui_data`, `wgdashboard_data`) persist across rebuilds. To upgrade:

1. Trigger a new CI build (or download a release).
2. Write the new image to a fresh USB (or replace the VDI in VirtualBox).
3. Boot the new image.
4. The first-boot installer detects the existing data and skips the
   destructive steps. To force a clean install, SSH in and run:

   ```bash
   sudo rm /opt/ppsa/.installed
   sudo docker volume rm compose_palworld_data compose_webui_data compose_wgdashboard_data
   sudo reboot
   ```

### Backup

The `ppsa-backup` container runs `offen/docker-volume-backup` on the
schedule defined in `/opt/ppsa/.env`:

```bash
BACKUP_SCHEDULE=0 3 * * *        # default: daily at 3am
BACKUP_RETENTION_DAYS=7          # default: keep 7 days
```

Backups land in the `backups/` volume, which is also mounted at
`/mnt/backups` on the host (and at `../backups` relative to the
compose file). The WebUI → **Backup** tab shows the most recent backup
filename and timestamp.

Restore from a backup is a manual process:

```bash
ssh ppsa@<ppsa-ip>
cd /opt/ppsa

# Stop the stack
sudo docker compose -f compose/docker-compose.yml down

# Restore a tarball
sudo docker run --rm \
  -v compose_palworld_data:/volume \
  -v /mnt/backups:/backup:ro \
  alpine sh -c "rm -rf /volume/* && tar xzf /backup/ppsa-palworld-20260630-030000.tar.gz -C /volume"

# Restart
sudo docker compose -f compose/docker-compose.yml up -d
```

### Rotate the wg-easy admin password

wg-easy v15 stores the admin password as an argon2id hash in its
SQLite DB, written once on first start from `INIT_PASSWORD` (or
`PASSWORD` on v14 — but you are on v15, use `INIT_PASSWORD`). To
rotate it without losing peers:

```bash
# On the wg-easy host
docker exec -it wg-easy-ppsa sqlite3 /etc/wireguard/wg-easy.db
# UPDATE users SET password = '<new argon2id hash>' WHERE id = 1;
```

Or, simpler, if you do not mind losing the existing peers:

```bash
# On the wg-easy host
docker compose down
sudo rm -rf ./config/wg-easy.db
# Edit your .env (or compose env) and set INIT_PASSWORD=newpass
docker compose up -d
# Re-create every peer (the PPSA host's peer is re-baked on its next boot)
```

### Reset the PPSA WebUI admin password

Via WebUI: **Settings** → change password.

Via the host:

```bash
ssh ppsa@<ppsa-ip>
sudo docker compose -f /opt/ppsa/compose/docker-compose.yml stop webui
sudo nano /var/lib/docker/volumes/compose_webui_data/_data/auth.json
# Edit the password hash (FastAPI uses passlib bcrypt)
sudo docker compose -f /opt/ppsa/compose/docker-compose.yml start webui
```

### Housekeeping

```bash
# Old container images
sudo docker image prune -a

# Old backups
ls /mnt/backups
sudo rm ppsa-palworld-20260501-030000.tar.gz   # example

# Rotate WireGuard peer keys (regenerate the .conf)
# In wg-easy: click the peer → Regenerate Key → download the new .conf
# Then re-import on every client.
```

---

## Quick reference

### Default credentials

| User | Password | Where to change |
|------|----------|-----------------|
| `admin` (WebUI) | `admin` | WebUI → Settings |
| `ppsa` (SSH) | `ppsa` | `passwd ppsa` |
| `artho` (SSH, port 10022) | `arthoroy` | `passwd artho` |
| Palworld in-game admin | `changeme` | WebUI → Config |
| wg-easy admin | (set on first start) | see section 15 |

### Ports on the PPSA host

| Service | Port | Protocol | Notes |
|---------|------|----------|-------|
| WebUI | 8080 | TCP | Main management UI |
| WG Dashboard | 10086 | TCP | Secondary peer UI |
| Palworld game | 8211 | UDP | Player connections |
| Steam query | 27015 | UDP | Server browser ping |
| Palworld REST | 8212 | TCP | WebUI reads this |
| Palworld RCON | 25575 | TCP | WebUI controls this |
| SSH (ppsa) | 22 | TCP | Primary SSH |
| SSH (artho) | 10022 | TCP | Backup SSH |

### Ports on the wg-easy host

| Service | Port | Protocol |
|---------|------|----------|
| WireGuard tunnel | 51830 | UDP |
| wg-easy web UI | 51831 | TCP |

### WireGuard subnet

| Network | Range | Purpose |
|---------|-------|---------|
| wg-easy default | `10.8.0.0/24` | All WireGuard peers, including the PPSA host and players |
| wg-easy server | `10.8.0.1` | The wg-easy host itself |
| PPSA host | `10.8.0.2` (default) | The PPSA server peer |
| Players | `10.8.0.3+` | Assigned by wg-easy in creation order |

### Key file paths on the PPSA host

| Path | Purpose |
|------|---------|
| `/etc/ppsa/wireguard.json` | wg-easy creds (chmod 600) |
| `/etc/ppsa/firewall.json` | WG_FRIENDS chain config |
| `/etc/ppsa/iptables.rules.v4` | Persisted iptables ruleset |
| `/etc/wireguard/wg0.conf` | WireGuard tunnel config |
| `/run/ppsa-wireguard-ip` | Currently assigned WG IP |
| `/opt/ppsa/.env` | Runtime config (server name, max players, etc.) |
| `/opt/ppsa/.installed` | First-boot completion flag |
| `/var/log/ppsa-install.log` | First-boot install log |
| `/mnt/backups` | Backup volume mount |
| `/var/lib/docker/volumes/compose_webui_data/_data/` | WebUI persistent data (auth.json, etc.) |

### Key file paths on the build host

| Path | Purpose |
|------|---------|
| `.env.example` | Template for `/opt/ppsa/.env` |
| `wireguard.local.json.example` | Template for wg-easy creds (local builds) |
| `compose/docker-compose.yml` | Main stack (5 services) |
| `scripts/install.sh` | First-boot setup |
| `scripts/ppsa-wireguard-register.sh` | WG auto-registration |
| `scripts/ppsa-firewall-apply.sh` | WG_FRIENDS chain builder |
| `scripts/build-live-usb.sh` | Image builder (debootstrap + GRUB) |
| `scripts/Start-PpsaBuilder.ps1` | PowerShell orchestrator |

---

## Related docs

- [wireguard-auto-registration.md](wireguard-auto-registration.md) — full
  details on the WG auto-registration flow and 120s polling behavior.
- [wifi-onboarding.md](wifi-onboarding.md) — `PPSA-Setup` hotspot fallback
  for hardware with no network connection.
- [configuration.md](configuration.md) — every variable in `.env`.
- [HANDOFF.md](HANDOFF.md) — infrastructure inventory, current state, and
  the homeserver/wg-easy deployment used as the reference for this guide.
- [smoke-test.md](smoke-test.md) — automated Pester smoke tests.
