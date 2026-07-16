<!-- refreshed: 2026-07-16 -->
# Architecture

**Analysis Date:** 2026-07-16

## System Overview

PPSA (Portable Palworld Server Appliance) is a three-artifact bootable Debian system combining a Palworld game server, web management UI, and optional networking tunnels (NetBird primary, WireGuard legacy). The architecture spans three layers:

1. **Build Layer**: Scripts and PowerShell modules that produce bootable images
2. **First-Boot Layer**: Systemd services and shell scripts that initialize the appliance
3. **Runtime Layer**: Docker Compose stack delivering game server, WebUI, networking, and auxiliary services

```text
┌─────────────────────────────────────────────────────────────┐
│                    ARTIFACTS (Three Types)                   │
│  ppsa-usb-*.img.zst | ppsa-vbox-*.vdi.zst | ppsa-*.iso.zst   │
│                                                               │
│  Built from single core script: build-live-usb.sh            │
└────────────────┬──────────────────────────────────────────────┘
                 │
     ┌───────────┴────────────┬────────────┐
     ▼                        ▼            ▼
┌──────────────────┐  ┌──────────────┐  ┌──────────────────┐
│  GitHub Actions  │  │  WSL Builder │  │  Installer ISO   │
│  (CI Pipeline)   │  │  (Local Dev)  │  │  (Live-Build)    │
│ .github/workflows│  │ Start-Ps1    │  │  installer/      │
└────────┬─────────┘  └──────┬───────┘  └────────┬─────────┘
         │                   │                    │
         └───────────────────┼────────────────────┘
                             │
                    ┌────────▼────────┐
                    │ build-live-usb  │
                    │      .sh        │
                    │ (Core Builder)  │
                    └────────┬────────┘
                             │
        ┌────────────────────┼────────────────────┐
        ▼                    ▼                     ▼
┌─────────────────┐  ┌──────────────┐  ┌──────────────────┐
│  Debian Rootfs  │  │  EFI / Boot  │  │  Docker Config   │
│  (debootstrap)  │  │  (Signed)    │  │  Compose Files   │
└────────┬────────┘  └──────┬───────┘  └────────┬─────────┘
         │                  │                   │
         └──────────────────┼───────────────────┘
                            │
                    ┌───────▼──────────┐
                    │  ppsa-firstboot  │
                    │   service (1/9)  │
                    └───────┬──────────┘
                            │
        ┌───────────────────┼───────────────────┐
        ▼                   ▼                   ▼
┌──────────────────┐ ┌────────────────┐ ┌─────────────────┐
│  Docker Stack    │ │ Wi-Fi Onboard  │ │  Firewall (UFW) │
│  (5 services)    │ │  Hotspot       │ │  + iptables     │
└────────┬─────────┘ └────────┬───────┘ └─────────┬───────┘
         │                    │                   │
    ┌────┴─────────┬──────────┘                   │
    ▼              ▼                              │
┌─────────┐  ┌──────────┐                  ┌─────▼──────┐
│Game Srv │  │ WebUI    │                  │  WG_FRIENDS│
│(Pal)    │  │(FastAPI) │◄─────────────────┤  Chain     │
└─────────┘  └──────────┘                  │(IPv4+UFW)  │
    ▲            ▲                         └────────────┘
    │            │
 RCON +       REST API
 UDP 8211    HTTP 8080
```

## Component Responsibilities

| Component | Responsibility | File |
|-----------|----------------|------|
| Image Builder | Creates Debian disk images from bootstrap, partitions, installs GRUB/shim, copies configs | `scripts/build-live-usb.sh` |
| First-Boot Service | Runs unattended on first boot, orchestrates install steps via systemd | `scripts/install.sh`, `ppsa-firstboot.service` |
| WSL/PowerShell Build System | Local dev-iteration builder, watches GitHub issues, enqueues/logs/smoke-tests builds | `scripts/Start-PpsaBuilder.ps1` + `modules/*.psm1` |
| Docker Compose Stack | Brings up game server, WebUI, WireGuard dashboard, backup cron, auto-updates | `compose/docker-compose.yml` |
| WebUI (FastAPI) | REST API + static SPA for management, proxies Palworld API, controls firewall/Wi-Fi/networking | `docker/webui/app/main.py` |
| Firewall Apply Script | Reads `firewall.json`, applies iptables `WG_FRIENDS` chain, allows edited port list | `scripts/ppsa-firewall-apply.sh` |
| Wi-Fi Onboarding | Hostapd/dnsmasq hotspot for initial network config | `scripts/ppsa-wifi-onboard.sh` |
| NetBird Enrollment | Auto-registers peer on first boot if config present | `scripts/ppsa-netbird-up.sh` |
| WireGuard Register | Registers peer with wg-easy API, applies fallback config if offline | `scripts/ppsa-wireguard-register.sh` |

## Pattern Overview

**Overall:** Modular, multi-stage single-source-of-truth artifact builder with integrated local dev tool. The core builder is a single Bash script (`build-live-usb.sh`) called identically by GitHub Actions (CI), PowerShell orchestrator (local), and Debian Live build system (installer ISO). All three produce artifacts from the same codebase snapshot.

**Key Characteristics:**
- **Single-source Principle**: `build-live-usb.sh` is the only script that formats, partitions, and installs the Debian image. CI/installer glue never duplicates this logic.
- **Unattended First-Boot**: All post-install setup (Docker, networking, firewall) runs via `ppsa-install.service` → `install.sh` on first boot, with live progress display on tty1.
- **Fail-Safe Defaults**: WireGuard disabled by default (`enabled: false` in `wireguard.json`); NetBird primary; firewalls default-deny except SSH + tunnel. Build-time flags override.
- **Layered Networking**: UFW (global rules) + iptables `WG_FRIENDS` chain (tunnel subnet), editable at runtime from WebUI.
- **Containerized Services**: Docker Compose brings up isolated, health-checked services; no systemd service interdependencies needed.

## Layers

**Build Layer:**
- Purpose: Create bootable disk images from source code
- Location: `scripts/build-live-usb.sh`, `modules/*.psm1`, `.github/workflows/`
- Contains: Debootstrap bootstrap, partition/mount logic, GRUB/shim installation, Docker Compose and config file copying into rootfs
- Depends on: Debian toolchain, GPG keys for signed GRUB/shim (if available)
- Used by: GitHub Actions CI, local PowerShell builder, installer ISO builder

**First-Boot Layer:**
- Purpose: Initialize the appliance after power-on (one-shot)
- Location: `scripts/install.sh`, `scripts/ppsa-firstboot.sh`, `systemd/*.service` files in chroot
- Contains: Docker startup, environment config, Docker Compose pull/up, Wi-Fi/WireGuard/NetBird setup, firewall rules, partition resize
- Depends on: Docker daemon, root privilege, mounted rootfs (already present from build)
- Used by: `ppsa-install.service` (systemd) on first boot only

**Runtime Layer:**
- Purpose: Deliver game server, management UI, networking, backups
- Location: `compose/docker-compose.yml`, `docker/webui/app/`, `scripts/ppsa-*.sh` (daemons)
- Contains: Palworld container, FastAPI WebUI app, WireGuard Dashboard, backup cron, auto-updater
- Depends on: Docker daemon, network access (to pull images)
- Used by: Systemd (starts compose stack), WebUI (calls `docker exec` for control)

## Data Flow

### Primary Request Path (User → WebUI → Game Server)

1. User opens browser to `http://<ip>:8080` (IP discovered via onboarding hotspot or given via SSH)
2. `docker/webui/app/main.py` receives request, checks JWT token in Bearer auth header (`require_auth()` dependency)
3. If authenticated, FastAPI routes dispatch to handler (e.g., `/api/dashboard`)
4. Handler calls `palworld_get("/info")`, which proxies HTTPX request to `http://palworld:8212/v1/api/info` (Docker Compose DNS resolves `palworld` service)
5. Palworld container (community image) responds with JSON (server uptime, player count, version)
6. WebUI aggregates responses, returns JSON to browser SPA
7. Browser renders player list, server status, control buttons

**Files involved:**
- `docker/webui/app/main.py` lines 345-362 (dashboard handler)
- `docker/webui/app/main.py` lines 247-275 (palworld_get proxy)
- `compose/docker-compose.yml` lines 30-86 (palworld service definition, port 8212)

### Firewall Control Path (WebUI → iptables)

1. User clicks "Edit Firewall" in WebUI, adds port 10086 to allowed list
2. POST `/api/firewall` → `firewall_update()` handler writes `firewall.json`
3. Handler calls `_host_exec()` → `sudo /scripts/ppsa-firewall-apply.sh`
4. Script reads `firewall.json`, generates iptables rules for `WG_FRIENDS` chain matching ports
5. Rules allow traffic from `100.64.0.0/10` (NetBird) + `10.8.0.0/24` (WireGuard) to those ports
6. Script restores via `iptables-restore`, saves to `/etc/ppsa/iptables.rules` for persistence

**Files involved:**
- `docker/webui/app/main.py` (firewall_update handler, _host_exec)
- `scripts/ppsa-firewall-apply.sh` (reads firewall.json, applies iptables)
- Mounted volumes: `/etc/ppsa:rw` (persistent firewall config)

### First-Boot Initialization Path

1. System boots, systemd targets are reached
2. `ppsa-install.service` (Type=simple, Before=multi-user.target) starts `ppsa-firstboot.sh` on tty1 + `install.sh` in background
3. `ppsa-firstboot.sh` reads `/run/ppsa-install.progress` in a loop, displays progress bar
4. `install.sh` (exec'd by systemd) runs steps 1-9 with numbered markers:
   - Resize root partition with growpart/resize2fs
   - `systemctl start docker`
   - Copy/merge `.env` config
   - `docker compose pull` + `docker compose up -d`
   - Start `ppsa-wifi-onboard.service` (hostapd/dnsmasq hotspot)
   - If `wireguard.json` enabled, run `ppsa-wireguard-register.sh` (calls wg-easy API)
   - If `/etc/ppsa/netbird.json` exists, start `ppsa-netbird-up.service` (netbird-cli enroll)
   - Apply firewall rules via `ppsa-firewall-apply.sh`
   - Write `.installed` flag file
5. `ppsa-firstboot.sh` detects flag, displays welcome banner, waits for Enter key
6. User presses Enter, shell hands off tty1 to getty (autologin)

**Files involved:**
- `scripts/install.sh` (main orchestrator, 9 steps)
- `scripts/ppsa-firstboot.sh` (tty1 progress display)
- `scripts/ppsa-wifi-onboard.sh` (hostapd script, started via service)
- `scripts/ppsa-wireguard-register.sh` (if WG enabled)
- `scripts/ppsa-netbird-up.sh` (if NetBird config exists)
- Systemd unit files in chroot: `ppsa-install.service`, `ppsa-wifi-onboard.service`, etc.

**State Management:**
- Progress tracked in `/run/ppsa-install.progress` (integer, highest step entered)
- Completion flag: `/opt/ppsa/.installed` (file existence)
- Logs: `/var/log/ppsa-install.log` (captured stdout/stderr from install.sh)
- Environment: `.env` file in `/opt/ppsa/.env` (sourced by Docker Compose)

## Key Abstractions

**Artifact Type:**
- Purpose: Distinguishes USB image, VirtualBox VDI, and installer ISO without code duplication
- Examples: `ppsa-usb-v1.3.0-nb.1.img.zst`, `ppsa-vbox-v1.3.0-nb.1.vdi.zst`, `ppsa-installer-v1.3.0-nb.1.iso.zst`
- Pattern: Single `build-live-usb.sh` produces raw `.img`, then post-processing converts to VDI (in CI) or bundles into live-build ISO (separate workflow)

**Build Job (PowerShell Local Builder):**
- Purpose: Represents a single build request with tag, logs, artifacts
- Pattern: Jobs queued in `Queue.psm1`, dequeued and executed by `Builder.psm1`, results stored in `status.json` and `history.json`
- Files: `modules/Queue.psm1`, `modules/Builder.psm1`, `modules/Status.psm1`

**Config Overlays (JSON):**
- Purpose: Runtime-editable configuration without rebuilding
- Examples: `firewall.json` (allowed ports), `wireguard.json` (tunnel settings), `.env` (Docker Compose variables)
- Pattern: Written by WebUI, read/applied by shell scripts, persisted to `/etc/ppsa/` or `.env` in the appliance

**Host-Exec Pattern (WebUI → Host):**
- Purpose: Bridge containerized WebUI to host OS (nsenter + chroot)
- Pattern: `_host_exec()` in `main.py` calls `sudo /script` via subprocess, WebUI container has `cap_add: NET_ADMIN` + bind mount `/:/host:ro`
- Examples: Wi-Fi scan, firewall update, NetBird status check
- File: `docker/webui/app/main.py` lines ~500 (_host_exec function)

## Entry Points

**GitHub Actions CI:**
- Location: `.github/workflows/build-release.yml` and `.github/workflows/build-installer.yml`
- Triggers: Tag push (build-release), manual workflow_dispatch (both)
- Responsibilities: Call `build-live-usb.sh` in Ubuntu runner, convert IMG to VDI, generate checksums, upload artifacts or publish release
- Files: `.github/workflows/build-*.yml`

**Local Builder (PowerShell):**
- Location: `scripts/Start-PpsaBuilder.ps1`
- Triggers: Manual `pwsh Start-PpsaBuilder.ps1 -Watch` or single-shot
- Responsibilities: Poll GitHub issue for comments, queue builds, call `build-live-usb.sh` in WSL, boot VDI in VirtualBox, smoke test, capture logs
- Files: `scripts/Start-PpsaBuilder.ps1`, `modules/*.psm1`

**First Boot (Systemd):**
- Location: `ppsa-install.service` (in chroot, runs `install.sh`)
- Triggers: Automatic on first power-on
- Responsibilities: Run 9 initialization steps, log progress, bring up Docker stack, configure networking
- Files: `scripts/install.sh`, `scripts/ppsa-firstboot.sh`

**Runtime Daemons:**
- Location: Various systemd units in `/etc/systemd/system/` (baked into image by build-live-usb.sh)
- Triggers: Systemd targets (multi-user.target, etc.)
- Responsibilities: Keep Wi-Fi hotspot running, monitor WireGuard handshakes, apply firewall rules on config change
- Files: `scripts/ppsa-wifi-onboard.service`, `scripts/ppsa-wg-status-snapshot.service`, `scripts/ppsa-firewall-request.service`, `scripts/ppsa-netbird-up.service`

## Architectural Constraints

- **Booting Model:** Images are booted either on real hardware (USB/SSD), in VirtualBox (via VDI), or in a VM spawned by the installer ISO. No in-place upgrades; entire image is replaced (immutable infrastructure pattern).
- **Network Namespace:** WebUI runs in a Docker container (own netns) but needs host network access for Wi-Fi control. Solved via `_host_exec()` + nsenter, not `--net=host`.
- **Signed Boot Chain:** If shim-signed and grub-efi-amd64-signed are available in the build chroot, `build-live-usb.sh` bakes their signatures and writes directly to `EFI/BOOT/` and `EFI/debian/` (immutable prefix). If not, falls back to unsigned `grub-mkstandalone` (Secure Boot must be off). No MOK enrollment needed.
- **Global State (iptables):** The `WG_FRIENDS` chain is host-level iptables state, not containerized. Must be applied from WebUI via host-exec. Persisted to `/etc/ppsa/iptables.rules` by `ppsa-firewall-apply.sh`.
- **Circular Dependency Avoidance:** WebUI depends on `palworld` container starting (not healthy), not on it being ready. Palworld downloads Steam files on first boot (can take 5+ min), so WebUI is reachable while server is still initializing.
- **WireGuard vs. NetBird:** Both daemons can be baked in, but WireGuard is disabled by default (`wireguard.json` `enabled: false`). NetBird is the primary path. If WireGuard is re-enabled (`PPSA_WG_ENABLED=true` build flag), both tunnels can run in parallel (both IPs allowed by firewall).

## Anti-Patterns

### Mutable Config in Image

**What happens:** Build script uses hardcoded defaults baked into image (e.g., server password, SSH keys, firewall rules). First-boot tries to apply config but can't override without rebuilding.

**Why it's wrong:** Users can't customize without rebuilding the entire image. Config changes require a new release/tag.

**Do this instead:** Store mutable config in `.env`, `firewall.json`, `wireguard.json`, etc. in directories that are **NOT** baked into the image or are mounted writable. `build-live-usb.sh` copies `.env.example` → `.env` only if it doesn't exist (preserves user edits across boots). WebUI reads/writes these files at runtime.
- Example: `scripts/build-live-usb.sh` lines ~1800 (copy `.env.example` to rootfs, but not `.env`)
- Example: `scripts/install.sh` lines 112-117 (copies `.env.example` → `.env` only on first boot)

### Direct Docker Command in WebUI (CLI Binary)

**What happens:** WebUI container tries `subprocess.check_output(["docker", ...])` but the slim Python image has no docker CLI binary. Fails with "No such file or directory: 'docker'".

**Why it's wrong:** Dependencies are implicit; docker-compose pull/up may succeed while later docker commands fail. Adds infrastructure-specific coupling to the app code.

**Do this instead:** Use Python Docker SDK (`docker==7.1.*` package) with `/var/run/docker.sock` mount. SDK doesn't require the CLI binary.
- Example: `docker/webui/app/main.py` lines 20-23 (import docker SDK, mount socket in compose)
- Example: `docker/webui/app/main.py` lines 177-239 (_run_docker using SDK, not subprocess)

### Synchronous Backup Blocking Event Loop

**What happens:** `/api/backup/trigger` calls `docker exec backup <tar-cmd>` synchronously (no `--detach` flag). Tar runs in foreground for several GB; event loop blocks; entire WebUI becomes unresponsive ("everything crashed") until backup finishes.

**Why it's wrong:** Long-running operations in FastAPI handlers without async/background tasks freeze the entire app.

**Do this instead:** Detach the operation (`docker exec --detach`) or run in a background task. Backup now executes in container background; handler returns immediately.
- Example: `docker/webui/app/main.py` lines 228-234 (detach=True for backup, returns immediately)

### Empty JSON Response on 200

**What happens:** Palworld REST API's action endpoints (`/save`, `/shutdown`, `/announce`, etc.) return HTTP 200 with an empty `text/plain` body on success. `resp.json()` on empty body raises `ValueError`. WebUI surfaces this as HTTP 500 "Internal Server Error" to the browser even though the action succeeded (e.g., world genuinely saved).

**Why it's wrong:** Error handling is too strict; assumes JSON on 200, doesn't tolerate empty success responses.

**Do this instead:** Check `resp.text.strip()` before calling `resp.json()`. Empty 200 is valid; return `{"status": "ok"}`.
- Example: `docker/webui/app/main.py` lines 291-299 (palworld_post checks empty text, tolerates non-JSON)

### Hot Tar of Live Palworld Saves

**What happens:** Backup runs `tar` on the live Palworld data directory while the server writes to it. A save file is deleted mid-tar (server rotates old saves). Tar aborts with "lstat: no such file or directory". No backup archive is written.

**Why it's wrong:** No checkpoint/snapshot before backup. Live filesystem churn invalidates the archive.

**Do this instead:** Stop the container during backup (docker-volume-backup's `stop-during-backup` label on service, or manually `docker stop` before `docker exec tar`). Palworld save dir becomes quiescent; tar completes cleanly.
- Example: `compose/docker-compose.yml` lines 78-85 (palworld service has `docker-volume-backup.stop-during-backup=true` label)

## Error Handling

**Strategy:** Layered fail-safe defaults with graceful degradation.

**Patterns:**
- **Build Phase:** Early `set -Eeuo pipefail` in Bash; errors abort immediately with exit code. CI captures logs before reporting failure. PowerShell uses try/catch around modules; build continues to logging phase even on failure (so logs are persisted).
- **First-Boot:** Each step is wrapped in `mark_step()` to log progress. If a step fails (e.g., Docker pull timeout), log a WARNING and continue to the next step (e.g., try `docker compose up` with cached images). Failure is not fatal; the system boots and user can retry from WebUI.
- **Runtime:** WebUI endpoints catch exceptions and return HTTP 500 with error message. Frontend displays "Server unavailable" banner but remains usable. Long-running operations (backup, game shutdown) are detached or wrapped in background tasks to prevent UI freeze.
- **Networking:** `palworld_get()` has optional `default=` parameter; callers can suppress exceptions and render empty state (e.g., on transient server downtime) instead of failing the entire dashboard.

**Examples:**
- `scripts/build-live-usb.sh` line 15 (set -euo pipefail, aborts on any error)
- `scripts/install.sh` lines 122-138 (docker pull with retry loop, continues on failure)
- `docker/webui/app/main.py` lines 345-362 (dashboard catches exception, returns partial response)

## Cross-Cutting Concerns

**Logging:** 

- **Build:** Bash uses `set -x` + PS4 timestamps for execution trace. PowerShell uses `Logger.psm1` (structured logging with timestamp, level, module, message + command/exit code/location/action). All logs written to `H:\dev\palimage\logs\` (configurable in `builder.json`).
- **First-Boot:** Shell script writes to `/var/log/ppsa-install.log` (captured early via `exec` redirection). Progress file (`/run/ppsa-install.progress`) tracks step number for tty1 display.
- **Runtime:** Docker containers use `json-file` driver with log rotation (max 10MB, keep 3 files). WebUI logs to uvicorn stdout (captured by systemd journal).
- **Files:**
  - `modules/Logger.psm1` (PowerShell structured logger, 156 lines)
  - `scripts/build-live-usb.sh` line 15 (set -x for bash trace)
  - `scripts/install.sh` lines 19-30 (log file setup)

**Validation:**

- **Config Parsing:** JSON files (firewall.json, wireguard.json, builder.json) are parsed with error handling (try/except in Python, ConvertFrom-Json in PowerShell). Invalid JSON logs a warning and uses defaults.
- **Artifact Verification:** After build, checksums are generated (SHA256) and compared against file before upload. Manifest (manifest.json) tracks artifact metadata.
- **Container Health Checks:** Each service in compose has a healthcheck (e.g., `curl -f http://localhost:8080/health` for WebUI, `rcon-cli Info` for Palworld). Systemd depends on health, not just container-started.
- **Files:**
  - `modules/Artifacts.psm1` (checksum verification)
  - `compose/docker-compose.yml` lines 58-62, 122-127 (health checks)

**Authentication:**

- **WebUI:** HTTP Basic auth on `/api/login` endpoint returns a JWT token. Subsequent requests require Bearer token in Authorization header. Token expiry: 24 hours. Password hashed with bcrypt (cost factor 4).
- **Palworld API Proxy:** WebUI authenticates to Palworld REST API with hardcoded `admin` user + `PALWORLD_ADMIN_PASSWORD` env var. Credentials never sent to browser (proxy pattern).
- **Host-Exec:** WebUI calls host scripts via `sudo` (passwordless, specific commands whitelisted in sudoers or via capability elevation). No direct shell access from WebUI to host.
- **Files:**
  - `docker/webui/app/main.py` lines 34-42 (bcrypt hash/verify)
  - `docker/webui/app/main.py` lines 139-158 (JWT auth, require_auth dependency)
  - `docker/webui/app/main.py` lines 277-299 (Palworld API proxy with admin creds)

---

*Architecture analysis: 2026-07-16*
