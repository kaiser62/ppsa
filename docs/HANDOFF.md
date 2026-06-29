# PPSA Project Handoff Report

**Date:** 2026-06-29
**Repo:** https://github.com/kaiser62/ppsa
**Branch:** master

---

## 1. Project Goal

PPSA = **P**alworld **P**ortable **S**erver **A**ppliance.

A bootable USB image (Debian-based) that runs:
- Palworld dedicated server (game port 8211/udp)
- Web management UI (port 8080)
- WireGuard auto-connection to a separate "gaming" subnet
- Watchtower for auto-updates
- Backups (offen/docker-volume-backup)
- Palworld + WG dashboard

The PPSA host can be plugged into any network, gets an IP via DHCP, and presents a web UI for management. Friends can join via WireGuard.

---

## 2. Infrastructure Inventory

### 2.1 Homeserver (artho@192.168.1.140)
- Public IP: **118.179.74.23** (AmberIT/Dhaka, no CGNAT, router port-forwardable)
- Public hostname: **`pleaseee.eu.org`** (and `wg.`, `ppsa.`, `palworld.pleaseee.eu.org`)
- LAN IP: 192.168.1.140
- Default gateway: 192.168.1.1 (router)
- SSH: artho / id_ed25519 (Windows path: `C:\Users\Sakat\.ssh\id_ed25519`)
- Runs many services: Jellyfin, AdGuard, qBittorrent, etc.

### 2.2 Router (192.168.1.1)
- **Port forwarding configured (this session):**
  - UDP 51830 → 192.168.1.140:51830 (WireGuard tunnel)
  - TCP 51831 → 192.168.1.140:51831 (wg-easy web UI)
- **DO NOT forward port 22** (SSH stays on cloudflared tunnel)
- DHCP: 192.168.1.0/24

### 2.3 Cloudflare
- Account: kaiser62/ppsa
- Zones: only `pleaseee.eu.org`
- DNS records managed (all direct, no proxy):
  - `pleaseee.eu.org` → 118.179.74.23
  - `wg.pleaseee.eu.org` → 118.179.74.23
  - `ppsa.pleaseee.eu.org` → 118.179.74.23
  - `palworld.pleaseee.eu.org` → 118.179.74.23
- API token: cert.pem at `C:\Users\Sakat\.cloudflared\cert.pem` (also stored in repo secrets)
- Existing cloudflared tunnel `myssh` exposes `ssh.basic.int.eu.org` → homeserver SSH (do not disable)

### 2.4 Windows host (this machine)
- User: Sakat
- Workspace: `D:\Dev\palworld-self-containing-server`
- Image dir: `H:\dev\wsl-temp\images\` (compressed .zst + .vdi files)
- VMs: `H:\vbox\ppsa-*\` (VBox managed)
- Tools:
  - `C:\Tools\cloudflared.exe` (just installed)
  - `C:\ProgramData\chocolatey\bin\aria2c.exe` (use for downloads, 16 connections)
  - `C:\Program Files\Oracle\VirtualBox\VBoxManage.exe`
  - `D:\Dev\Miniconda3\Library\bin\zstd.exe` (decompress .zst)
  - git, gh CLI

---

## 3. PPSA Versions & What's Built

| Version | Tag | Build time | Key feature | Status |
|---------|-----|-----------|-------------|--------|
| v1.1.5 | v1.1.5 | 4m | WireGuard auto-registration | ✅ Tested working |
| v1.1.6 | v1.1.6 | 4m | /etc/ppsa rw mount for firewall | ❌ Persistence fails |
| v1.1.7 | v1.1.7 | 4m | Firewall restore service | ❌ Condition path mismatch |
| v1.1.8 | v1.1.8 | 3m37s | Single-CPU + WG preferred IP + OR condition | ⚠️ Code merged, never tested |

### Latest artifacts (local, on Windows host)
- `H:\dev\wsl-temp\images\ppsa-vbox-v1.1.8.vdi.zst` (711 MiB, sha256: `1c05109d022aa1b5e4b42ee3eed640e373a991c93a6c50a2ab4ae080c29482be`)
- `H:\dev\wsl-temp\images\ppsa-usb-v1.1.8.img.zst` (713 MiB)
- After `zstd -d`, the VDI is at `H:\dev\wsl-temp\images\ppsa-vbox-v1.1.8.vdi` (~2.2 GB dynamic)

### Code state (master branch, all pushed)
- 9 modules, 1 orchestrator, 1 smoke test, 1 VM image build
- 1 builder JSON, 1 .env.example
- 1 install.sh, 1 first-boot.sh, 8 PPSA scripts
- 1 Dockerfile, 1 webui FastAPI app, 1 webui SPA (index.html)
- ~10 test reports + 5 docs

---

## 4. Critical Features Implemented This Session

### 4.1 WireGuard Auto-Registration (`scripts/ppsa-wireguard-register.sh`)
- Reads `/etc/ppsa/wireguard.json`
- **Session-cookie auth** to wg-easy v15 API (`POST /api/session` with `{username, password, remember:false}`)
- Idempotent: checks if peer with `peer_name` exists via `/api/client`, creates if not
- Downloads config from `/api/client/{id}/configuration`
- Brings up wg-quick@wg0 with `wg syncconf` (idempotent re-runs)
- Enables service for boot persistence
- Saves assigned IP to `/run/ppsa-wireguard-ip`
- v1.1.8: supports `preferred_ip` field (sends `address` in POST, 422-retry strips it)
- v1.1.8: `export PATH="/sbin:/usr/sbin:${PATH}"` for resolvconf

### 4.2 WebUI Firewall Management
- 5 API endpoints in `docker/webui/app/main.py`:
  - `GET /api/firewall/config`
  - `PUT /api/firewall/config`
  - `GET /api/firewall/status` (uses `:WG_FRIENDS` substring check, NOT just `WG_FRIENDS`)
  - `POST /api/firewall/apply`
  - `POST /api/firewall/reset`
- Apply script: `scripts/ppsa-firewall-apply.sh` — reads `/etc/ppsa/firewall.json` OR webui data dir, builds `WG_FRIENDS` iptables chain idempotently
- Restore service: `scripts/ppsa-firewall-restore.service` — `ConditionPathExists=|/etc/iptables/rules.v4` OR `|/etc/ppsa/iptables.rules.v4`
- **CRITICAL BUG NOT YET FIXED:** apply script writes to `/etc/iptables/rules.v4` FIRST, so `/etc/ppsa/iptables.rules.v4` is never created, so restore service is dead
- **WebUI Firewall tab** added in `docker/webui/app/static/index.html`

### 4.3 PPSA First-Boot Progress UI (`scripts/ppsa-firstboot.sh`)
- Runs on tty1, replaces getty
- Shows 8-step progress (was 7 in v1.1.0)
- Step 6/8 is the new WireGuard auto-connection
- Reads `/run/ppsa-install.progress` for current step
- Shows completion screen with WebUI/SSH/WG URLs + WG IP

### 4.4 Single-CPU Support
- `compose/docker-compose.yml` Palworld limits: `cpus: "${PPSA_CPUS:-1.0}"`, `memory: "${PPSA_MEMORY:-2G}"`
- `.env.example` documents `PPSA_CPUS` and `PPSA_MEMORY`
- v1.1.7 had hardcoded `cpus: "4.0" / memory: 6G` which fails on 1-vCPU / 4-GB hosts

### 4.5 Orchestrator (`scripts/Start-PpsaBuilder.ps1`)
- 208 lines, wires all 10 modules
- Phases: load config → init logger → watch GitHub → build → test artifacts → smoke test
- Usage: `pwsh ./scripts/Start-PpsaBuilder.ps1 [-IssueNumber N] [-Watch] [-SkipSmokeTest]`

### 4.6 Smoke Test Module (`modules/SmokeTest.psm1`)
- 7 functions: boot healthy, wait ready, webui reachable, etc.
- `tests/test-smoketest.ps1` — 8 tests, all pass
- `docs/smoke-test.md` — module docs

---

## 5. wg-easy Setup (PPSA Gaming Network)

### 5.1 Container (homeserver)
- Name: `wg-easy-ppsa`
- Image: `ghcr.io/wg-easy/wg-easy:15`
- Compose: `/home/artho/wg-ppsa/docker-compose.yml`
- **Ports:**
  - UDP 51830 (external) → 51820 (container, WG protocol)
  - TCP 51831 (external) → 51821 (container, web UI)
- Network: `compose_wg-ppsa` (10.99.99.0/24, container at 10.99.99.2)
- **Mount fix:** `/etc/ppsa:/etc/ppsa:rw` (line 89 of compose — after `/:host:ro` mount, Docker's most-specific-path rule wins)
- **v15 init env vars** (use these, NOT v14's PASSWORD):
  ```
  INIT_ENABLED=true
  INIT_USERNAME=admin
  INIT_PASSWORD=overengineered
  INIT_HOST=pleaseee.eu.org
  INIT_PORT=51820
  INIT_ALLOWED_IPS=10.99.99.0/24  # the wg-easy subnet, NOT 0.0.0.0/0
  INIT_DNS=1.1.1.1, 9.9.9.9
  INIT_IPV4_CIDR=10.99.99.0/24
  ```
- v15 read by **SQLite DB at first start**. Password change requires:
  1. `docker exec -it wg-easy-ppsa sqlite3 /etc/wireguard/wg-easy.db` and update the argon2id hash
  2. OR destroy the DB volume and let INIT_PASSWORD take effect (loses all peers)

### 5.2 Current WG Peers
| Peer | IP | Endpoint | Notes |
|------|-----|----------|-------|
| ppsa-server | 10.8.0.2 | none | Original, never connected |
| ppsa-v115 | 10.8.0.3 | 118.179.74.23:1027 | v1.1.5, active |
| test | 10.8.0.4 | 118.179.74.23:64125 | **Suspect — 14.9 GB TX!** |
| test-friend | 10.8.0.5 | none | From earlier test |
| test-friend2 | 10.8.0.6 | none | From earlier test |
| ppsa-v116 | 10.8.0.7 | 118.179.74.23:1026 | v1.1.6, active |
| ppsa-v117 | 10.8.0.8 | 118.179.74.23:59003 | v1.1.7, wedged |

### 5.3 Player Onboarding
1. Player opens `http://pleaseee.eu.org:51831` (or `wg.pleaseee.eu.org:51831`)
2. Login: `admin:overengineered`
3. Add Client → name → Generate
4. Player imports .conf into WireGuard app
5. Connects → gets e.g. `10.8.0.4`
6. Plays Palworld on `10.8.0.3:8211` (or whichever PPSA peer)

---

## 6. PPSA Firewall (WG_FRIENDS Chain)

### Default allowed ports (from 10.8.0.0/24 → PPSA host)
- **TCP:** 22 (SSH), 80, 443, 8080 (WebUI), 10086 (wg-dashboard), 25575 (Palworld RCON)
- **UDP:** 8211 (Palworld), 27015 (Steam query)
- **ICMP:** enabled
- Everything else: DROP

### Config file (`/etc/ppsa/firewall.json`)
```json
{
  "wg_friends_allowed_tcp": [22, 80, 443, 8080, 10086, 25575],
  "wg_friends_allowed_udp": [8211, 27015],
  "wg_friends_allow_icmp": true
}
```

### Known issue
- Friends get `AllowedIPs = 0.0.0.0/0` in their config (v15 default — can't be changed in API)
- They CAN route through the PPSA host, but PPSA's iptables drops everything except allowed ports
- This is the security model the user wanted

---

## 7. Current PPSA VMs (VirtualBox)

| VM | VDI | vCPUs | RAM | IP | Status |
|---|---|---|---|---|---|
| ppsa-v115 | v1.1.5 | 1 | 4G | 192.168.1.143 | running, no report, RECOMMENDED FOR DELETE |
| ppsa-v116 | v1.1.6 | 1 | 4G | 192.168.1.164 | running, has v1.1.6 report |
| ppsa-v117 | v1.1.7 | 1 | 4G | 192.168.1.229 | wedged (vboxguest) |
| ppsa-v118-2cpu | v1.1.7 (rebuild) | 1 | 4G | 192.168.1.230 | running, partial diag done |
| ppsa-v119 | v1.1.8 | 1 | 4G | 192.168.1.230 | running, partial diag done (overlaps with v118) |

**Cleanup recommended:** delete v115 (no report), v117 (wedged), consolidate v118/v119.

### vboxguest issue
- VirtualBox 7.2.10 host + Debian 13 guest
- Image's vboxguest.ko built against older VBox version
- 2+ vCPUs → kernel RCU stall on docker compose startup
- **1 vCPU works** (workaround)
- **Permanent fix:** rebuild vboxguest inside the image: `apt install --reinstall virtualbox-guest-dkms` OR disable vboxguest entirely

---

## 8. GitHub Repository Secrets (Settings → Secrets)

| Secret | Value |
|--------|-------|
| `PPSA_WG_API_URL` | `http://pleaseee.eu.org:51831` |
| `PPSA_WG_API_USER` | `admin` |
| `PPSA_WG_API_PASS` | `overengineered` |
| `PPSA_WG_PEER_NAME` | `ppsa-server` |
| `PPSA_WG_PREFERRED_IP` | (not set) — set to `10.8.0.2` if you want ppsa-server to have a fixed IP |

When these are set, the v1.1.5+ builds bake them into `/etc/ppsa/wireguard.json` as `enabled: true` and the install.sh WireGuard step auto-registers.

---

## 9. Files of Interest on the Windows Host

```
D:\Dev\palworld-self-containing-server\                  ← project root
├── MASTER_PLAN.md                                       ← development plan (M1-M15)
├── builder.json                                         ← builder config
├── .env.example                                          ← template for PPSA .env
├── compose\docker-compose.yml                           ← PPSA stack (palworld, webui, etc.)
├── scripts\
│   ├── build-live-usb.sh                                ← image build
│   ├── install.sh                                       ← first-boot setup
│   ├── ppsa-firewall-apply.sh                           ← WG_FRIENDS builder
│   ├── ppsa-firewall-restore.service                    ← boot restore unit
│   ├── ppsa-wireguard-register.sh                       ← WG auto-register
│   ├── ppsa-firstboot.sh                                ← tty1 progress UI
│   ├── ppsa-wifi-onboard.sh + .service                 ← Wi-Fi hotspot fallback
│   ├── Start-PpsaBuilder.ps1                            ← orchestrator
│   └── ...
├── docker\webui\
│   ├── app\main.py                                      ← FastAPI app, all endpoints
│   └── app\static\index.html                            ← SPA
├── docs\
│   ├── wireguard-auto-registration.md                   ← WG feature docs
│   ├── wifi-onboarding.md
│   ├── test-reports\                                    ← all v1.1.x test reports
│   ├── architecture.md (TODO)
│   ├── modules.md (TODO)
│   ├── workflow.md (TODO)
│   └── ...
├── modules\                                              ← PowerShell builder modules
│   ├── Configuration.psm1
│   ├── Logger.psm1
│   ├── Utils.psm1
│   ├── GitHub.psm1
│   ├── Queue.psm1
│   ├── Builder.psm1
│   ├── Artifacts.psm1
│   ├── Status.psm1
│   ├── VirtualBox.psm1
│   └── SmokeTest.psm1                                    ← M10
├── tests\                                                 ← Pester tests
└── .github\workflows\build-release.yml                  ← CI build

H:\dev\wsl-temp\images\                                  ← all PPSA images
├── ppsa-vbox-v1.1.5.vdi.zst
├── ppsa-vbox-v1.1.6.vdi.zst
├── ppsa-vbox-v1.1.7.vdi.zst
└── ppsa-vbox-v1.1.8.vdi.zst                            ← latest

C:\Users\Sakat\.ssh\
├── id_ed25519                                           ← private key
├── id_ed25519.pub                                       ← public key (NOT in any PPSA authorized_keys)
├── known_hosts

C:\Windows\Temp\                                          ← temp area, often cleaned
└── wg-ppsa-credentials.txt                              ← wg-easy admin info (PASSWORD OVERRIDDEN, current is 'overengineered')
```

---

## 10. Test Reports

In `docs/test-reports/`:
- `v1.1.0-test-report.md` (no VM ref)
- `v1.1.1-test-report.md`
- `v1.1.2-test-report.md` (tested on ppsa-v112, no longer exists)
- `v1.1.3-test-report.md`
- `v1.1.6-test-report.md` ✅ has v1.1.6 details
- `v1.1.7-test-report.md` ✅ has v1.1.7 + retest 2026-06-29

---

## 11. Open Issues / Pending Work

### Critical (blocks v1.1.8 release)
1. **Firewall restore path mismatch.** Apply script writes to `/etc/iptables/rules.v4` first; restore service requires `/etc/ppsa/iptables.rules.v4` to start. **Fix:** change apply script to write to BOTH paths first, OR change restore service condition to `|/etc/iptables/rules.v4` only.

### High
2. **Palworld Steam connectivity** — `ppsa-palworld` can't reach Steam. Investigate with tcpdump inside the container.
3. **VM running wrong image** — labelled ppsa-v119 but reports v1.1.7. Build/deploy correct v1.1.8.
4. **Cleanup VMs** — delete v115, v117. Reconcile v118/v119 into one clean v1.1.8 VM.

### Medium
5. **Bump vCPUs to 4** for the production PPSA VM (Palworld is CPU-bound).
6. **Rotate default passwords** (WebUI `admin:admin`, `.env` `ADMIN_PASSWORD=changeme`).
7. **M11-M15 of master plan:** cleanup, docs (architecture.md, modules.md, workflow.md), optimization, refactoring, final validation.

### Low
8. **Migrate SSH to key auth** (add `~ppsa/.ssh/authorized_keys` for ed25519).
9. **Test wg-easy API to see if it actually respects the `address` field in POST** — v1.1.8 sends it but fallback is silent.
10. **Build concurrency** — add `concurrency: build-usb-image` to workflow to prevent v1.1.6 race.

---

## 12. Known-Bad Tests / Things to Avoid

- **Don't reboot the VM in the middle of Palworld first boot** — Steam download is 3.8 GB, container will be wedged
- **Don't use 2+ vCPUs** until vboxguest is fixed
- **Don't use `chroot /host` in webui for writing** — it's a read-only mount, the `nsenter -t 1 -m` part works for reading only
- **Don't use v14 env vars for wg-easy v15** — PASSWORD, WG_HOST, etc. were replaced by INIT_*
- **Don't use 1 vCPU for the actual PPSA** — Palworld needs 4+ to handle traffic

---

## 13. Standard Commands

### Trigger a build
```powershell
cd D:\Dev\palworld-self-containing-server
git tag -a vX.Y.Z -m "message"
git push origin vX.Y.Z
# CI builds USB + VBox images in ~4 min
```

### Download a release
```powershell
& "C:\ProgramData\chocolatey\bin\aria2c.exe" -x 16 -s 16 -k 1M --file-allocation=none -d "H:\dev\wsl-temp\images" -o "ppsa-vbox-v1.1.8.vdi.zst" "https://github.com/kaiser62/ppsa/releases/download/v1.1.8/ppsa-vbox-v1.1.8.vdi.zst"
& "D:\Dev\Miniconda3\Library\bin\zstd.exe" -d "H:\dev\wsl-temp\images\ppsa-vbox-v1.1.8.vdi.zst" -o "H:\dev\wsl-temp\images\ppsa-vbox-v1.1.8.vdi" --force
```

### Create a VM
```powershell
VBoxManage createvm --name "ppsa-vXXX" --ostype "Debian_64" --register
VBoxManage modifyvm "ppsa-vXXX" --memory 4096 --cpus 1 --vram 32 --nic1 bridged --bridgeadapter1 "Realtek Gaming 2.5GbE Family Controller" --boot1 disk --boot2 none --boot3 none --boot4 none --firmware efi64 --macaddress1 auto
VBoxManage storagectl "ppsa-vXXX" --name "SATA" --add sata --controller IntelAhci
VBoxManage storageattach "ppsa-vXXX" --storagectl "SATA" --port 0 --device 0 --type hdd --medium "H:\dev\wsl-temp\images\ppsa-vbox-v1.1.8.vdi"
VBoxManage startvm "ppsa-vXXX" --type gui
```

### SSH into PPSA
```powershell
# Use password (ppsa:ppsa) — key auth not configured on PPSA
ssh ppsa@192.168.1.XXX
# Or with longer banner timeout:
ssh -o BannerTimeout=30 ppsa@192.168.1.XXX
```

### Test the wg-easy API
```python
import urllib.request, base64, json
auth = base64.b64encode(b'admin:overengineered').decode()
# List peers
req = urllib.request.Request('http://192.168.1.140:51831/api/client', headers={'Authorization': f'Basic {auth}'})
print(json.loads(urllib.request.urlopen(req).read()))
# Get config for peer
req = urllib.request.Request('http://192.168.1.140:51831/api/client/8/configuration', headers={'Authorization': f'Basic {auth}'})
print(urllib.request.urlopen(req).read().decode())
```

### Test the PPSA WebUI API
```python
import urllib.request, base64, json
# Login (Basic auth on /api/login returns JWT)
auth = base64.b64encode(b'admin:admin').decode()
data = json.dumps({'username': 'admin', 'password': 'admin'}).encode()
req = urllib.request.Request('http://192.168.1.XXX:8080/api/login',
    headers={'Authorization': f'Basic {auth}', 'Content-Type': 'application/json'},
    data=data, method='POST')
token = json.loads(urllib.request.urlopen(req).read())['token']
# Use token
for ep in ['/api/system', '/api/dashboard', '/api/firewall/config', '/api/firewall/status', '/api/wireguard/status']:
    req = urllib.request.Request(f'http://192.168.1.XXX:8080{ep}', headers={'Authorization': f'Bearer {token}'})
    print(ep, '->', urllib.request.urlopen(req).read()[:200])
```

---

## 14. Master Plan Progress

| M | Milestone | Status |
|---|-----------|--------|
| M1 | Configuration | ✅ |
| M2 | Logger | ✅ |
| M3 | Utilities | ✅ |
| M4 | GitHub watcher | ✅ |
| M5 | Build queue | ✅ |
| M6 | WSL builder | ✅ |
| M7 | Artifact manager | ✅ |
| M8 | Status engine | ✅ |
| M9 | VirtualBox manager | ✅ |
| M10 | Smoke testing | ✅ (SmokeTest.psm1 + tests + docs) |
| M11 | Cleanup | ⏳ |
| M12 | Documentation | ⏳ (architecture.md, modules.md, workflow.md missing) |
| M13 | Optimization | ⏳ |
| M14 | Refactoring | ⏳ |
| M15 | Final validation | ⏳ |

---

## 15. Suggested Next Session

1. Fix the firewall restore path issue (one-line change)
2. Re-test the WG registration flow on the running v1.1.8 (or v1.1.7) VM
3. Investigate Steam CDN connectivity from ppsa-palworld (tcpdump)
4. Build a clean v1.1.9 with all fixes
5. Test v1.1.9 end-to-end including reboot persistence
6. If green, cut v1.1.9 release
7. Continue masterplan M11 (cleanup) and M12 (docs)

---

## 16. Quick Reference: Key URLs

| Service | URL | Auth |
|---------|-----|------|
| wg-easy web UI (LAN) | http://192.168.1.140:51831 | admin:overengineered |
| wg-easy web UI (public) | http://pleaseee.eu.org:51831 | admin:overengineered |
| PPSA web UI | http://192.168.1.XXX:8080 | admin:admin |
| Cloudflare DNS | (managed via `cloudflared tunnel login` or API) | API token in cert.pem |
| GitHub repo | https://github.com/kaiser62/ppsa | standard git |
| GitHub Actions | https://github.com/kaiser62/ppsa/actions | standard gh auth |

---

## 17. Glossary

- **PPSA** — Palworld Portable Server Appliance (the project)
- **WG** — WireGuard (the VPN)
- **wg-easy** — Web UI for managing WireGuard, runs on the homeserver
- **homeserver** — The always-on Linux box at 192.168.1.140 (artho@…)
- **VM** — VirtualBox guest running PPSA
- **PPSA host** — the PPSA VM itself (where Palworld runs)
- **friend** — a WireGuard peer that's not a PPSA host (your gamer friends)
- **.env** — `/opt/ppsa/.env` on the PPSA host, runtime config for the stack
- **.env.example** — template at `D:\Dev\palworld-self-containing-server\.env.example`
- **builder.json** — config for the PPSA BUILDER (the PowerShell pipeline)
- **vboxguest** — VirtualBox guest additions module
- **AF_VSOCK** — Virtual socket, used by VBox guest services
- **RCU stall** — kernel Read-Copy-Update stall (the vboxguest issue)
- **iptables WG_FRIENDS** — the chain that controls what friends can reach on the PPSA host
