# PPSA Project Handoff Report

**Date:** 2026-06-30
**Repo:** https://github.com/kaiser62/ppsa
**Branch:** master
**HEAD:** `de98ff3` (v1.1.11 in progress — `wait_for_api` fix under test)

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

| Version | Tag | Key feature | Status |
|---------|-----|-------------|--------|
| v1.1.5 | v1.1.5 | WireGuard auto-registration | ✅ Tested working |
| v1.1.6 | v1.1.6 | /etc/ppsa rw mount for firewall | ❌ Persistence fails |
| v1.1.7 | v1.1.7 | Firewall restore service | ❌ Condition path mismatch |
| v1.1.8 | v1.1.8 | Single-CPU + WG preferred IP + OR condition | ✅ Builds clean (v1.1.11 supersedes) |
| v1.1.9 | v1.1.9 | 4 firewall/webui bug fixes | ✅ Tagged, tested |
| v1.1.10 | (not tagged) | Deploy `ppsa-wireguard-register.service` so re-registration works on subsequent boots | ✅ Merged `e1a7c37` |
| v1.1.11 | (not tagged) | `wait_for_api` polling + firstboot 3-state + `wireguard.local.json` + CI tag fix + deployment guide | 🔄 HEAD `de98ff3`, `wait_for_api` fix under test |

### Latest artifacts (local, on Windows host)
- `H:\dev\wsl-temp\images\ppsa-vbox-v1.1.11.vdi.zst` (download after v1.1.11 tag is pushed)
- Earlier VDI still in place: `ppsa-vbox-v1.1.9.vdi.zst` (replace in place)
- After `zstd -d`, the VDI is at `H:\dev\wsl-temp\images\ppsa-vbox-v1.1.11.vdi` (~2.2 GB dynamic)

### Code state (master branch, all pushed)
- 9 modules, 1 orchestrator, 1 smoke test, 1 VM image build
- 1 builder JSON, 1 .env.example, 1 `wireguard.local.json.example`
- 1 install.sh, 1 first-boot.sh, 8 PPSA scripts, 3 PPSA systemd units
- 1 Dockerfile, 1 webui FastAPI app, 1 webui SPA (index.html)
- ~10 test reports + 6 docs (incl. new `deployment-guide.md`)

---

## 4. Critical Features Implemented

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
- v1.1.10 (`e1a7c37`): accompanied by `scripts/ppsa-wireguard-register.service` (41 lines) which `install.sh` and `build-live-usb.sh` install — fixes the silent re-registration failure on the second boot
- v1.1.11: see §4.7 (polling helper) and §4.8 (firstboot 3-state)

### 4.2 WebUI Firewall Management
- 5 API endpoints in `docker/webui/app/main.py`:
  - `GET /api/firewall/config`
  - `PUT /api/firewall/config`
  - `GET /api/firewall/status` (uses `:WG_FRIENDS` substring check, NOT just `WG_FRIENDS`)
  - `POST /api/firewall/apply`
  - `POST /api/firewall/reset`
- Apply script: `scripts/ppsa-firewall-apply.sh` — reads `/etc/ppsa/firewall.json` OR webui data dir, builds `WG_FRIENDS` iptables chain idempotently
- Restore service: `scripts/ppsa-firewall-restore.service` — `ConditionPathExists=|/etc/iptables/rules.v4` OR `|/etc/ppsa/iptables.rules.v4`
- **v1.1.9 fix (`b41ae67`):** `/etc/ppsa/iptables.rules.v4` write was inside an `if/elif` and skipped when `netfilter-persistent` was installed. Moved the write outside the conditional so it always runs.
- **v1.1.9 fix (`4e6462d`):** `/api/firewall/config` now reads the canonical `/etc/ppsa/firewall.json` first, falling back to the webui volume. `/api/firewall/status` parses the persisted `/etc/ppsa/iptables.rules.v4` for the live `WG_FRIENDS` chain (running `iptables` inside the container's namespace never worked — the chain lives in the host netns).
- **WebUI Firewall tab** added in `docker/webui/app/static/index.html`

### 4.3 PPSA First-Boot Progress UI (`scripts/ppsa-firstboot.sh`)
- Runs on tty1, replaces getty
- Shows 8-step progress
- Step 6/8 is the WireGuard auto-connection
- Reads `/run/ppsa-install.progress` for current step
- Shows completion screen with WebUI/SSH/WG URLs + WG IP
- v1.1.11 (`588b3ce`): extended post-install WG IP wait from 5s → 15s; added a third render state — see §4.8

### 4.4 Single-CPU Support
- `compose/docker-compose.yml` Palworld limits: `cpus: "${PPSA_CPUS:-1.0}"`, `memory: "${PPSA_MEMORY:-2G}"`
- `.env.example` documents `PPSA_CPUS` and `PPSA_MEMORY` (v1.1.7 had hardcoded `4.0`/6G which fails on 1-vCPU / 4-GB hosts)

### 4.5 Orchestrator (`scripts/Start-PpsaBuilder.ps1`)
- 208 lines, wires all 10 modules. Phases: load config → init logger → watch GitHub → build → test artifacts → smoke test
- Usage: `pwsh ./scripts/Start-PpsaBuilder.ps1 [-IssueNumber N] [-Watch] [-SkipSmokeTest]`
- v1.1.11 (`588b3ce`): now also stages `wireguard.local.json` into the image when present — see §4.9

### 4.6 Smoke Test Module (`modules/SmokeTest.psm1`)
- 7 functions: boot healthy, wait ready, webui reachable, etc.
- `tests/test-smoketest.ps1` — 8 tests, all pass; `docs/smoke-test.md` — module docs

### 4.7 WG Polling — `wait_for_api()` helper
- Lives at the top of `scripts/ppsa-wireguard-register.sh` (added in `588b3ce`, fixed in `75f990c`)
- Polls the configured wg-easy host with `curl -m 5 -o /dev/null -w "%{http_code}"` and exponential backoff: 2, 4, 8, 10, 10, 10, … seconds up to `PPSA_WG_WAIT_TIMEOUT` (default **120s**)
- Treats **any** HTTP response (incl. 401/403/404/5xx) as proof the TCP/HTTP path is alive — the API itself returns 401 before login, so even 401 means the daemon is up
- Called once after config parsing, before the first login attempt
- **Bug fixed in `75f990c`:** the original `|| echo "000"` fallback produced `"000000"` when curl already failed (curl writes "000" via `-w`, then echo appends another). The `!= "000"` check then returned success after the first curl, skipping the backoff entirely — a no-op for the case it was written to solve. Dropped the `|| echo "000"`, normalized empty to "000" after capture, added a progress log on each retry. **Found by end-to-end VM test of v1.1.11.**
- `install.sh` step 5 (`588b3ce`): removed the 60s outer timeout cap; register script's internal polling is now the source of truth. Outer cap bumped to 300s as an absolute upper bound. Non-zero rc now messages "will retry on next boot" instead of failing the install.

### 4.8 Firstboot 3-state rendering
- `scripts/ppsa-firstboot.sh` welcome screen, `588b3ce`
- State 1 — `wireguard.json` `enabled: false` (or no creds) → "WireGuard: not configured"
- State 2 — IP file `/run/ppsa-wireguard-ip` exists → "WireGuard: connected at 10.8.0.X"
- **State 3 (new)** — `enabled: true` but IP file missing → "WireGuard: registering with wg-easy (will retry on next boot if needed)". Replaces the old "not connected" message that was misleading during the (now expected) 15-30s first-boot wait
- 15s wait at the end of the script (up from 5s) so polling has time to write the IP file before the welcome screen renders

### 4.9 `wireguard.local.json` for build-time creds
- New `wireguard.local.json.example` at repo root (9 lines) — template for local builders
- Gitignored (`588b3ce`): local builders running `Start-PpsaBuilder.ps1` on their own machine can drop a real `wireguard.local.json` next to it; the orchestrator stages it into the image as `/etc/ppsa/wireguard.json` so polling has something to wait for on first boot
- **CI builds keep using `PPSA_WG_*` repo secrets** — this file is for local builds only
- Plumbing: `Start-PpsaBuilder.ps1` (+52 lines), `modules/Builder.psm1` (+26), `scripts/build-live-usb.sh` (+50)

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
| ppsa-v119 | 10.8.0.9 | (live) | v1.1.8/v1.1.9, needs cleanup |

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

### Default friend AllowedIPs
- Friends get `AllowedIPs = 10.8.0.0/24` by default (the PPSA subnet, NOT full tunnel — hijacks no default route on the player side)
- Source: `INIT_ALLOWED_IPS` in the wg-easy v15 container env seeds `user_configs_table.default_allowed_ips` in the SQLite DB (`/etc/wireguard/wg-easy.db`) on first init; v15 has NO `WG_ALLOWED_IPS` env var — the DB row is authoritative. Per-peer overrides via `POST /api/client/{id}` (allowedIps is `z.array(AddressSchema).min(1)`).
- The PPSA host runs `iptables WG_FRIENDS` which restricts what friends can reach on the host (allowed TCP/UDP/ICMP per `firewall.json`).
- This is the security model the user wanted: WG tunnel carries only the PPSA subnet, the player keeps its normal LAN/internet default route.

---

## 7. Current PPSA VMs (VirtualBox)

| VM | VDI | vCPUs | RAM | IP | Status |
|---|---|---|---|---|---|
| ppsa-v115 | v1.1.5 | 1 | 4G | 192.168.1.143 | running, no report, RECOMMENDED FOR DELETE |
| ppsa-v116 | v1.1.6 | 1 | 4G | 192.168.1.164 | running, has v1.1.6 report |
| ppsa-v117 | v1.1.7 | 1 | 4G | 192.168.1.229 | wedged (vboxguest) |
| ppsa-v118-2cpu | v1.1.7 (rebuild) | 1 | 4G | 192.168.1.230 | running, partial diag done |
| ppsa-v119 | v1.1.8 | 1 | 4G | 192.168.1.230 | running on v1.1.8 (use for v1.1.11 retag) |

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

When these are set, the v1.1.5+ builds bake them into `/etc/ppsa/wireguard.json` as `enabled: true` and the install.sh WireGuard step auto-registers. For local builds, `wireguard.local.json` (gitignored) is the alternative.

---

## 9. Files of Interest on the Windows Host

```
D:\Dev\palworld-self-containing-server\                  ← project root
├── MASTER_PLAN.md                                       ← dev plan (M1-M15)
├── builder.json                                         ← builder config
├── .env.example, wireguard.local.json.example           ← env templates
├── compose\docker-compose.yml                           ← PPSA stack
├── scripts\
│   ├── build-live-usb.sh                                ← image build (v1.1.10+: stages wg-register.service + wireguard.local.json)
│   ├── install.sh                                       ← first-boot setup (step 5 polls wg-easy, see §4.7)
│   ├── ppsa-firewall-{apply.sh,restore.service}         ← WG_FRIENDS builder + boot restore
│   ├── ppsa-wireguard-register.{sh,service}             ← WG auto-register (+ systemd unit, v1.1.10)
│   ├── ppsa-firstboot.sh                                ← tty1 progress UI (3-state WG render, see §4.8)
│   ├── ppsa-wifi-onboard.sh + .service                  ← Wi-Fi hotspot fallback
│   └── Start-PpsaBuilder.ps1                            ← orchestrator
├── docker\webui\{app\main.py,app\static\index.html}     ← FastAPI + SPA
├── docs\
│   ├── HANDOFF.md, deployment-guide.md                  ← this file + new in v1.1.11 (`de98ff3`, 825 lines)
│   ├── wireguard-auto-registration.md, wifi-onboarding.md, smoke-test.md
│   ├── test-reports\                                    ← all v1.1.x test reports
│   └── architecture.md, modules.md, workflow.md (TODO)
├── modules\                                              ← PowerShell builder (M1-M10, incl. SmokeTest.psm1)
├── tests\                                                 ← Pester tests
└── .github\workflows\build-release.yml                  ← CI (v1.1.11: tag-name fix from `450c2f8`)

H:\dev\wsl-temp\images\ppsa-vbox-v{1.1.5..1.1.11}.vdi.zst ← 1.1.11 is latest after tag push
C:\Users\Sakat\.ssh\{id_ed25519,id_ed25519.pub,known_hosts}
C:\Windows\Temp\wg-ppsa-credentials.txt                  ← wg-easy admin (current pwd: 'overengineered')
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
- v1.1.9 / v1.1.11 reports pending the `wait_for_api` end-to-end test

---

## 11. Open Issues / Pending Work

### Resolved since v1.1.8 (✅)
1. ~~Firewall restore path mismatch~~ — `b41ae67` (v1.1.9): `/etc/ppsa/iptables.rules.v4` write moved outside the `if/elif`.
2. ~~`/api/players` HTTP 500 / "Loading..." forever~~ — `4e6462d` (v1.1.9): returns `{"players":[],"error":…}` on failure.
3. ~~`/api/firewall/config` reading the wrong path~~ — `4e6462d` (v1.1.9): canonical `/etc/ppsa/firewall.json` first.
4. ~~`/api/firewall/status` running iptables in the container's netns~~ — `4e6462d` (v1.1.9): parses the persisted rules file instead.
5. ~~Re-registration silently failing on second boot~~ — `e1a7c37` (v1.1.10): `ppsa-wireguard-register.service` unit installed by `install.sh` + `build-live-usb.sh`.
6. ~~First-boot showing "not connected" during the wg-easy warmup race~~ — `588b3ce` (v1.1.11): 3-state render + 15s wait.
7. ~~`wait_for_api` bailing after first curl when port closed~~ — `75f990c` (v1.1.11): real exponential backoff, visible in install log.
8. ~~CI `workflow_dispatch` publishing release under tag `master`~~ — `450c2f8` (v1.1.11): prefer `inputs.version` over `github.ref_name`.

### High
1. **End-to-end test the v1.1.11 polling fix** on a clean VM (the test in progress when this handoff was written — assumed passing, confirm).
2. **Palworld Steam connectivity** — `ppsa-palworld` can't reach Steam. Investigate with tcpdump inside the container.
3. **Cleanup VMs** — delete v115, v117. Reconcile v118/v119 into one clean v1.1.11 VM.

### Medium
4. **Bump vCPUs to 4** for the production PPSA VM (Palworld is CPU-bound).
5. **Rotate default passwords** (WebUI `admin:admin`, `.env` `ADMIN_PASSWORD=changeme`).
6. **M11-M15 of master plan:** cleanup, docs (architecture.md, modules.md, workflow.md), optimization, refactoring, final validation.

### Low
7. **Migrate SSH to key auth** (add `~ppsa/.ssh/authorized_keys` for ed25519).
8. **Test wg-easy API to see if it actually respects the `address` field in POST** — v1.1.8 sends it but fallback is silent.
9. **Build concurrency** — add `concurrency: build-usb-image` to workflow to prevent v1.1.6 race.
10. **Dual firewall stack** (UFW + iptables) is still in the image. Low-priority cleanup: pick one, remove the other.

---

## 12. Known-Bad Tests / Things to Avoid

- **Don't reboot the VM in the middle of Palworld first boot** — Steam download is 3.8 GB, container will be wedged
- **Don't use 2+ vCPUs** until vboxguest is fixed
- **Don't use `chroot /host` in webui for writing** — it's a read-only mount, the `nsenter -t 1 -m` part works for reading only
- **Don't use v14 env vars for wg-easy v15** — PASSWORD, WG_HOST, etc. were replaced by INIT_*
- **Don't use 1 vCPU for the actual PPSA** — Palworld needs 4+ to handle traffic
- **Don't trust a green `bash -n` on shell scripts that use curl polling** — the `wait_for_api` bug was invisible to `bash -n` and only surfaced in an end-to-end VM test

---

## 13. Standard Commands

### Trigger a build
```powershell
cd D:\Dev\palworld-self-containing-server
git tag -a vX.Y.Z -m "message"
git push origin vX.Y.Z
# CI builds USB + VBox images in ~4 min
# For v1.1.10/v1.1.11, use workflow_dispatch with version input (v1.1.11+ tag-name fix in place)
```

### Download a release
```powershell
& "C:\ProgramData\chocolatey\bin\aria2c.exe" -x 16 -s 16 -k 1M --file-allocation=none -d "H:\dev\wsl-temp\images" -o "ppsa-vbox-v1.1.11.vdi.zst" "https://github.com/kaiser62/ppsa/releases/download/v1.1.11/ppsa-vbox-v1.1.11.vdi.zst"
& "D:\Dev\Miniconda3\Library\bin\zstd.exe" -d "H:\dev\wsl-temp\images\ppsa-vbox-v1.1.11.vdi.zst" -o "H:\dev\wsl-temp\images\ppsa-vbox-v1.1.11.vdi" --force
```

### Create a VM
```powershell
VBoxManage createvm --name "ppsa-v1111" --ostype "Debian_64" --register
VBoxManage modifyvm "ppsa-v1111" --memory 4096 --cpus 1 --vram 32 --nic1 bridged --bridgeadapter1 "Realtek Gaming 2.5GbE Family Controller" --boot1 disk --boot2 none --boot3 none --boot4 none --firmware efi64 --macaddress1 auto
VBoxManage storagectl "ppsa-v1111" --name "SATA" --add sata --controller IntelAhci
VBoxManage storageattach "ppsa-v1111" --storagectl "SATA" --port 0 --device 0 --type hdd --medium "H:\dev\wsl-temp\images\ppsa-vbox-v1.1.11.vdi"
VBoxManage startvm "ppsa-v1111" --type gui
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
for ep in ['/api/system', '/api/dashboard', '/api/players', '/api/firewall/config', '/api/firewall/status', '/api/wireguard/status']:
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
| M12 | Documentation | ⏳ (architecture.md, modules.md, workflow.md still missing — `deployment-guide.md` shipped in v1.1.11) |
| M13 | Optimization | ⏳ |
| M14 | Refactoring | ⏳ |
| M15 | Final validation | ⏳ |

---

## 15. Suggested Next Session

1. Confirm the v1.1.11 `wait_for_api` end-to-end test passed; if yes, tag `v1.1.11` and push
2. Download the v1.1.11 VDI, build a clean VM, run the WebUI smoke test from §13
3. Investigate Steam CDN connectivity from `ppsa-palworld` (tcpdump)
4. Cut v1.1.12 with whatever else surfaces
5. Continue masterplan M11 (cleanup) and M12 (finish architecture.md, modules.md, workflow.md)

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
- **wireguard.local.json** — gitignored file at repo root for local builders (v1.1.11+); CI uses repo secrets
- **vboxguest** — VirtualBox guest additions module
- **AF_VSOCK** — Virtual socket, used by VBox guest services
- **RCU stall** — kernel Read-Copy-Update stall (the vboxguest issue)
- **iptables WG_FRIENDS** — the chain that controls what friends can reach on the PPSA host
- **wait_for_api** — bash helper in `ppsa-wireguard-register.sh` that polls wg-easy with backoff before login
