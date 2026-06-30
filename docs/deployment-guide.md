# PPSA Deployment Guide

**Version:** v1.1.11 (commit `75f990c`, master branch)
**Last updated:** 2026-06-30
**Applies to:** PPSA v1.1.10+

> **Quick path** — Want to deploy fast? Follow [Part 1](#part-1-quick-path) (~30 minutes).
> Skip to: [Download](#4-get-the-image) | [Connect a player](#11-connect-a-player) | [Troubleshooting](#14-troubleshooting)
>
> Need the "I need to do X" reference? See [Part 2](#part-2-reference).

---

# Part 1: Quick path

For the 80% case: you have a USB stick or VM, you have access to a wg-easy v15 instance, and you want a working Palworld server reachable over WireGuard in under 30 minutes.

## 1. What you need

- A USB 3.0+ stick (8 GB+) **or** a VirtualBox host with 1 vCPU / 4 GB RAM free.
- Access to a wg-easy v15 instance (URL, admin user, admin password).
- A router that gives out DHCP.

## 2. Download the image

```bash
gh release download v1.1.11 -R kaiser62/ppsa \
  -p "ppsa-vbox-v1.1.11.vdi.zst" -p "ppsa-*.sha256" \
  -D ./ppsa-release
```

Or browse to <https://github.com/kaiser62/ppsa/releases> and pick `ppsa-usb-v1.1.11.img.zst` (USB) or `ppsa-vbox-v1.1.11.vdi.zst` (VM).

## 3. Write to USB or create a VM

### USB (Windows, Rufus)

```bash
zstd -d ppsa-usb-v1.1.11.img.zst
```

1. Rufus → select USB → SELECT → `ppsa-usb-v1.1.11.img`.
2. START → **DD image mode** (NOT ISO) → OK.
3. Wait 3-10 min, eject safely.

### USB (Linux/macOS)

```bash
zstd -d ppsa-usb-v1.1.11.img.zst
sudo dd if=ppsa-usb-v1.1.11.img of=/dev/sdX bs=4M status=progress conv=fsync
sync
```

### VirtualBox

```bash
zstd -d ppsa-vbox-v1.1.11.vdi.zst
```

1. Machine → New → Name `ppsa`, Type **Linux**, Version **Debian (64-bit)**.
2. Memory 4096 MB, CPU 1 (or 4 for production).
3. Use an existing virtual hard disk → pick `ppsa-vbox-v1.1.11.vdi`.
4. Settings → Network → Adapter 1 → **Bridged Adapter** → pick your NIC.
5. Settings → System → **Enable EFI**.
6. Start the VM.

## 4. Boot and find the IP

Boot the USB or start the VM. On the console (tty1) you'll see an 8-step first-boot UI. After 3-10 minutes:

- The tty1 banner prints `Web UI: http://<ip>:8080` — that's your PPSA IP.
- Or SSH: `ssh ppsa@<ip>` (password: `ppsa`).

## 5. Open the WebUI and change the password

Browse to `http://<ppsa-ip>:8080`. Default login: `admin` / `admin`. **Settings → change the admin password immediately.**

Click through the tabs once to confirm health: Dashboard, Controls, System, WireGuard, Firewall.

## 6. Configure WireGuard

### A. Bake creds in (fastest, auto-register on first boot)

On the build machine, before writing the image:

```bash
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

Rebuild (`sudo bash scripts/build-live-usb.sh`), write the image, boot. On first boot the PPSA host auto-registers as a peer at `10.8.0.2` and the WireGuard tab shows `Connected`.

### B. Configure via the WebUI

WebUI → **WireGuard** tab → fill in API URL (`http://<wg-easy>:51831`), user (`admin`), password → **Save** → **Connect**. The register script polls for up to 120s and brings up the tunnel.

Verify with `sudo wg show` (expect wg0 + peer with handshake) and `cat /run/ppsa-wireguard-ip` (expect `10.8.0.2`). If no handshake, see [Troubleshooting](#14-troubleshooting).

## 7. Configure Palworld

WebUI → **Config** tab:

| Field | Example |
|-------|---------|
| `SERVER_NAME` | `My Palworld Server` |
| `MAX_PLAYERS` | `16` |
| `ADMIN_PASSWORD` | `strong-pass-here` |
| `RESTAPI_ENABLED` | `true` |
| `RCON_ENABLED` | `true` |

Click **Save Changes** → **Controls** → **Restart Palworld Container**. First launch downloads ~3.8 GB from Steam (10-30 min). When `healthy`, the Dashboard shows version + FPS.

## 8. Add a player

1. Player installs WireGuard: <https://www.wireguard.com/install/>.
2. Player opens wg-easy: `http://<wg-easy>:51831` (LAN: `http://192.168.1.140:51831`).
3. Login as wg-easy admin.
4. **New Client** → name (`PlayerName`) → **Generate** → download `.conf`.
5. Player imports the `.conf` into the WireGuard app → activate tunnel. They get a WG IP like `10.8.0.4`.
6. In Palworld: **Multiplayer → Add Server** → Address: `10.8.0.2` (PPSA WG IP) → Port: `8211` → **Connect**.

If `Disconnected from server`, see [Troubleshooting](#14-troubleshooting).

---

# Part 2: Reference

## 1. Overview

PPSA (Palworld Portable Server Appliance) is a self-contained, bootable image that turns any x86_64 machine into a dedicated Palworld game server. It runs Debian 13 (Trixie) and the entire PPSA stack (Palworld, WebUI, WireGuard dashboard, backup, Watchtower) as Docker containers. Write the image to a USB drive (or run as a VDI/VM), boot, and a web control panel comes up on port 8080.

Two roles: **server admin (you)** owns the host, deploys the image, operates the WebUI; **players (your friends)** install WireGuard, import a `.conf`, and play Palworld.

## 2. Prerequisites

**Server admin:** x86_64 host (USB or VirtualBox), 1 vCPU / 4 GB RAM min (4 vCPU / 8 GB prod target), home network with DHCP, access to a wg-easy v15 instance, router that forwards UDP/TCP (PPSA host itself needs no forwards).

**Players:** Palworld client (Steam), WireGuard app (any platform), `.conf` file from wg-easy admin.

## 3. Choose deployment method

| Method | Best for | Trade-offs |
|--------|----------|------------|
| **USB** (`.img`) | Dedicated hardware, no hypervisor | Needs USB 3.0+ (8 GB+); auto-resizes on first boot |
| **VirtualBox VDI** (`.vdi`) | Testing, lab, dev | Runs in VM; convenient snapshots |
| **Bare metal / SSD** | Best performance | Write `.img` to internal SSD via USB-SATA, or boot USB and `dd` to `/dev/sda` |

## 4. Get the image

**Option A — Download a release** (recommended):

```bash
gh release download v1.1.11 -R kaiser62/ppsa \
  -p "ppsa-*.zst" -p "ppsa-*.sha256" \
  -D ./ppsa-release
```

Assets: `ppsa-usb-v1.1.11.img.zst` (USB/SSD) or `ppsa-vbox-v1.1.11.vdi.zst` (VM).

**Option B — CI build:** `gh workflow run build-release.yml -f version=vX.Y.Z` (requires repo secrets; both formats built in ~5 min as a draft).

**Option C — Build locally:** `git clone https://github.com/kaiser62/ppsa.git && cd ppsa && sudo bash scripts/build-live-usb.sh --output ppsa-usb.img` (or `pwsh ./scripts/Start-PpsaBuilder.ps1 -Version v1.1.11` on Windows).

## 5. Deploy to USB

```bash
zstd -d ppsa-usb-v1.1.11.img.zst
```

**Windows (Rufus):** SELECT → `ppsa-usb-v1.1.11.img` → START → **DD image mode** → OK. Wait 3-10 min, eject safely.

**Linux / macOS:** `sudo dd if=ppsa-usb-v1.1.11.img of=/dev/sdX bs=4M status=progress conv=fsync && sync`. Triple-check the target — `dd` does not warn.

## 6. Deploy to VirtualBox

```bash
zstd -d ppsa-vbox-v1.1.11.vdi.zst
```

1. Machine → New → Name `ppsa`, Type **Linux**, Version **Debian (64-bit)**.
2. Memory **4096 MB** min, **8192 MB** recommended. CPU **1** for testing (vboxguest bug affects 2+ vCPU; see [Troubleshooting](#14-troubleshooting)), **4** for production.
3. Use an existing virtual hard disk → `ppsa-vbox-v1.1.11.vdi`.
4. Settings → Network → Adapter 1 → **Bridged Adapter** → pick the NIC connected to your router.
5. Settings → System → **Enable EFI** (recommended; legacy BIOS also works).
6. Start.

PowerShell: `VBoxManage createvm --name "ppsa" --ostype "Debian_64" --register` + `modifyvm --memory 4096 --cpus 1 --nic1 bridged --bridgeadapter1 "<nic>" --firmware efi64`, attach the VDI via `storagectl`/`storageattach`, then `startvm --type gui`.

## 7. First boot

`ppsa-firstboot.service` shows this 8-step UI on tty1:

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

Step 6 polls the wg-easy API for up to 120s (2/4/8/10/10s backoff). Total **3-10 minutes** (Docker pulls + ~3.8 GB Steam update). `Setup Complete!` means the WebUI is reachable. IP is on the tty1 banner (`Web UI: http://...`) or `ssh ppsa@<ppsa-ip>` (password `ppsa`).

## 8. Open the WebUI

```
http://<ppsa-ip>:8080
```

Default login `admin` / `admin`. **Change the admin password in Settings immediately.** Tabs: **Dashboard** (FPS, version, players), **Players**, **Controls** (start/stop/restart), **Config**, **System**, **Backup**, **Wi-Fi** (with wireless NIC only), **Firewall** (WG_FRIENDS chain), **WireGuard** (tunnel status), **Settings** (admin password). A tab hanging on "Loading..." or returning 500 means the container is still starting — see [Troubleshooting](#14-troubleshooting).

## 9. Configure WireGuard

### 9a. Baked-in creds

Nothing to do. First boot already auto-registered the PPSA host as a peer. Verify: WebUI → **WireGuard** shows `Connected` with an IP in `10.8.0.0/24` (typically `10.8.0.2`); tty1 banner shows the WG IP. Firstboot states: `registered` (handshake done) / `registering` (polling) / `not configured` (`enabled:false`; fill via WebUI).

### 9b. WebUI configuration

WebUI → **WireGuard** → fill in API URL (e.g. `http://192.168.1.140:51831`), user (`admin`), password → **Save** → **Connect**. Register script polls for up to 120s, registers as a peer, brings up `wg0`. Assigned WG IP appears in the WireGuard tab.

### Verify the tunnel

```bash
ssh ppsa@<ppsa-ip>
sudo wg show                          # wg0 with a peer, latest handshake
cat /run/ppsa-wireguard-ip            # 10.8.0.2
ping -c 3 10.8.0.1
```

If no handshake, check UDP 51830 forwarding, DNS for the wg-easy hostname, and `/etc/ppsa/wireguard.json` creds.

## 10. Configure Palworld

WebUI → **Config** tab:

| Field | Example | Notes |
|-------|---------|-------|
| `SERVER_NAME` | `My Palworld Server` | Shown in server browser |
| `MAX_PLAYERS` | `16` | Cap simultaneous players |
| `ADMIN_PASSWORD` | `strong-pass-here` | In-game admin login |
| `SERVER_PASSWORD` | (empty) | Gate the server if you want |
| `RESTAPI_ENABLED` | `true` | Required for Players tab |
| `RCON_ENABLED` | `true` | Required for Controls tab |

Click **Save Changes** → **Controls** → **Restart Palworld Container**. First launch downloads ~3.8 GB from Steam (10-30 min); watch **Controls → Logs**. When the container is `healthy` and Dashboard shows `Server FPS` + `Version`, the server is ready.

For production, raise container limits in `/opt/ppsa/.env` (`PPSA_CPUS=4.0`, `PPSA_MEMORY=6G`) and restart the stack with `cd /opt/ppsa && sudo docker compose -f compose/docker-compose.yml up -d`.

## 11. Connect a player

1. Player installs WireGuard: <https://www.wireguard.com/install/>.
2. Player opens wg-easy: `http://<wg-easy-host>:51831` (LAN `http://192.168.1.140:51831`, external `http://pleaseee.eu.org:51831`).
3. Login as wg-easy admin → **New Client** → name (e.g. `PlayerName`) → **Generate** → download `.conf`.
4. Player imports `.conf` into the WireGuard app → activate tunnel (gets a WG IP like `10.8.0.4`).
5. In Palworld: **Multiplayer → Add Server** → Address: `<PPSA's WG IP>` (e.g. `10.8.0.2`) → Port: `8211` → **Connect**.

If `Disconnected from server`: wait for the Palworld container to finish the Steam download (Controls tab; must be `healthy`); confirm `AllowedIPs` includes `10.8.0.0/24` (default does); from the player's machine, `ping 10.8.0.2` should succeed.

## 12. Port forwarding (external player access)

The PPSA host needs **no port forwards**. Players reach it via the WireGuard tunnel. The wg-easy host's router needs:

| Protocol | External port | Forward to | Purpose |
|----------|---------------|------------|---------|
| UDP | 51830 | wg-easy host:51830 | WireGuard tunnel |
| TCP | 51831 | wg-easy host:51831 | wg-easy web UI |

**Do not** forward port 22 (SSH) on the wg-easy host — SSH stays on the cloudflared tunnel.

## 13. Firewall configuration

The PPSA host runs a `WG_FRIENDS` iptables chain controlling what WireGuard peers (from `10.8.0.0/24`) can reach.

### Defaults (`10.8.0.0/24 → PPSA`)

| Protocol | Allowed ports | Notes |
|----------|---------------|-------|
| TCP | 22, 80, 443, 8080, 10086, 25575 | SSH, Web, WebUI, WG Dashboard, RCON |
| UDP | 8211, 27015 | Palworld game, Steam query |
| ICMP | enabled | Ping |
| Everything else | DROP | — |

Baked into `scripts/ppsa-firewall-apply.sh` and the WebUI data volume.

### Change

Via WebUI: **Firewall** tab → edit TCP/UDP port lists and ICMP toggle → **Save & Apply**.

Via host file: edit `/etc/ppsa/firewall.json`, then `sudo /opt/ppsa/scripts/ppsa-firewall-apply.sh`. Rebuilds `WG_FRIENDS` idempotently and persists to `/etc/iptables/rules.v4`; `ppsa-firewall-restore.service` reloads on every boot.

```json
{
  "wg_friends_allowed_tcp": [22, 80, 443, 8080, 10086, 25575],
  "wg_friends_allowed_udp": [8211, 27015],
  "wg_friends_allow_icmp": true
}
```

## 14. Troubleshooting

### The PPSA VM gets no IP

| Cause | Fix |
|-------|-----|
| Bridged adapter pointed at the wrong NIC | VirtualBox → Settings → Network → Adapter 1 → Bridged Adapter → pick the NIC connected to your router |
| DHCP not available | Some guest networks block DHCP. Try a different network or assign a static IP via the WebUI later |
| VM subnet differs from yours | Expected. The IP still works, just adjust the URL |

### WebUI shows 500 / "Connecting..."

Docker is still pulling images, or Palworld is downloading its 3.8 GB Steam update. Wait 5-10 min, refresh. From SSH: `sudo docker ps -a` and `sudo docker logs ppsa-palworld --tail 50`.

### Players tab stuck on "Loading..."

Fixed in v1.1.10+. Earlier versions returned 500 + plain text from `/api/players` when the Palworld REST API was slow. Upgrade.

### WireGuard tab shows "Not Configured"

`/etc/ppsa/wireguard.json` has `enabled: false` or doesn't exist. Fill creds via WebUI → WireGuard (see [section 9b](#9b-webui-configuration)).

### WireGuard "registering" forever / no handshake / SSH fails over WireGuard

The wg-easy API or tunnel is unreachable. Check in order from the PPSA host (`ssh ppsa@<ppsa-ip>`):

```bash
curl -sS -m 5 -o /dev/null -w "%{http_code}\n" http://<wg-easy>:51831/api/client
# 000 = network unreachable, 401 = reachable, creds wrong
getent hosts wg.pleaseee.eu.org   # expect an IP
# From homeserver: ssh artho@192.168.1.140 → docker ps | grep wg-easy
```

If reachable from a browser but not from the PPSA host, UDP 51830 is not forwarded on the homeserver's router (see [section 12](#12-port-forwarding-external-player-access)).

### Palworld container "unhealthy"

Normal on first launch — Steam update is downloading (`sudo docker logs -f ppsa-palworld`). If `unhealthy` for more than 30 minutes, check DNS and Steam reachability inside the container (`nslookup steamcdn-a.akamaihd.net`, `wget -q -O - https://api.steamcmd.net`). If DNS is failing, check `/etc/resolv.conf` on the PPSA host and inside the container.

### Player connects but immediately gets "Disconnected from server"

1. **Palworld container not yet ready** — wait until `healthy` and Dashboard shows server version.
2. **Wrong AllowedIPs in `.conf`** — wg-easy v15 default is `10.8.0.0/24` (PPSA subnet only, **not** a full tunnel — see the source fix in commit `943cc5c`). With this default the player reaches the PPSA over WG and their normal LAN/internet is unaffected. If a config has `AllowedIPs = 0.0.0.0/0` (full tunnel) and the PPSA host has no IP forwarding + NAT, the player's LAN will be cut off. Fix: edit the .conf to `AllowedIPs = 10.8.0.0/24` and re-import, or update the wg-easy `default_allowed_ips` DB row + re-download the config.

### Console tty1 stuck mid-step

```bash
ssh ppsa@<ppsa-ip>
sudo tail -100 /var/log/ppsa-install.log
# Force a re-run: sudo rm /opt/ppsa/.installed && sudo systemctl restart ppsa-install.service
```

### Rebuilt vboxguest fix (1-vCPU workaround)

Shipped `vboxguest.ko` may not match the host VirtualBox version. Symptoms: kernel RCU stalls during `docker compose up`, especially on 2+ vCPUs. Reinstall the dkms module (`sudo apt install --reinstall virtualbox-guest-dkms && sudo reboot`) or disable vboxguest (`sudo systemctl disable --now vboxservice`). 1-vCPU configuration is not affected.

## 15. Maintenance

- **Update image:** download a new release, write to a fresh USB / replace VDI, boot. First-boot installer detects existing data and skips destructive steps. Force clean: `sudo rm /opt/ppsa/.installed && sudo docker volume rm compose_palworld_data compose_webui_data compose_wgdashboard_data && sudo reboot`.
- **Backup:** `ppsa-backup` runs `offen/docker-volume-backup` per `BACKUP_SCHEDULE` (default `0 3 * * *`) with `BACKUP_RETENTION_DAYS=7`. Backups land at `/mnt/backups`.
- **Restore:** stop the stack, restore the tarball, restart:
  ```bash
  sudo docker run --rm -v compose_palworld_data:/volume -v /mnt/backups:/backup:ro \
    alpine sh -c "rm -rf /volume/* && tar xzf /backup/<file>.tar.gz -C /volume"
  sudo docker compose -f compose/docker-compose.yml up -d
  ```
- **Rotate wg-easy admin password:** on the wg-easy host, `docker exec -it wg-easy-ppsa sqlite3 /etc/wireguard/wg-easy.db` then `UPDATE users SET password = '<new argon2id hash>' WHERE id = 1;`. Or reset (loses peers): `docker compose down && sudo rm -rf ./config/wg-easy.db`, set `INIT_PASSWORD=newpass` in `.env`, `docker compose up -d`.
- **Reset WebUI admin password:** WebUI → **Settings**, or edit `/var/lib/docker/volumes/compose_webui_data/_data/auth.json` (FastAPI passlib bcrypt) and restart the webui container.
- **Housekeeping:** `sudo docker image prune -a`; rotate WireGuard keys in wg-easy.

---

## Quick reference

**Default credentials:** `admin`/`admin` (WebUI → Settings), `ppsa`/`ppsa` (SSH), `artho`/`arthoroy` (SSH port 10022), `changeme` (in-game admin → Config), wg-easy admin (set on first start).

**Ports:** WebUI 8080/TCP, WG Dashboard 10086/TCP, Palworld 8211/UDP (game), 8212/TCP (REST), 25575/TCP (RCON), 27015/UDP (Steam query), SSH 22/TCP (`ppsa`), 10022/TCP (`artho`), wg-easy 51830/UDP (tunnel) + 51831/TCP (web UI).

**WireGuard subnet (`10.8.0.0/24`):** `10.8.0.1` = wg-easy server, `10.8.0.2` = PPSA host (default), `10.8.0.3+` = players.

**Key paths:** `/etc/ppsa/wireguard.json` (chmod 600), `/etc/ppsa/firewall.json`, `/etc/wireguard/wg0.conf`, `/run/ppsa-wireguard-ip`, `/opt/ppsa/.env`, `/opt/ppsa/.installed`, `/var/log/ppsa-install.log`, `/mnt/backups`, `wireguard.local.json` (build-time, git-ignored).

## Related docs

- [wireguard-auto-registration.md](wireguard-auto-registration.md) — WG auto-registration flow and 120s polling.
- [wifi-onboarding.md](wifi-onboarding.md) — `PPSA-Setup` hotspot fallback.
- [configuration.md](configuration.md) — every variable in `.env`.
- [HANDOFF.md](HANDOFF.md) — infrastructure inventory and homeserver/wg-easy deployment.
- [smoke-test.md](smoke-test.md) — automated Pester smoke tests.
