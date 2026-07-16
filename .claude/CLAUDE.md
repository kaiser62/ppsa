<!-- GSD:project-start source:PROJECT.md -->

## Project

**PPSA — Portable Palworld Server Appliance**

PPSA is a bootable Debian 13 (Trixie) disk image that runs a Palworld dedicated
server plus a management stack (WebUI, backup, dashboards) via Docker Compose.
It ships as three artifacts from one shared build core (`scripts/build-live-usb.sh`):
a raw USB/SSD image, a VirtualBox VDI, and a live-boot installer ISO that writes
PPSA onto a spare drive without touching the host OS. Friends reach the server
over a private NetBird overlay network — it is meant for non-technical users who
just want to boot a stick and host Palworld for friends.

**Core Value:** A user can boot the appliance, and their friends can reach a working Palworld
server over the private overlay network — every build must preserve that
end-to-end path.

### Constraints

- **Build policy**: Images produced via GitHub Actions only, never locally — single source of truth is `scripts/build-live-usb.sh`
- **Testing**: Local verification in VirtualBox only (boot CI-produced artifacts); installer ISO is the real product to test, img/vdi are byproducts
- **Networking**: Appliance WebUI/game ports must stay NetBird-only; do not open LAN access
- **Security**: `kaiser62/ppsa` repo is public — never commit secrets (NetBird keys, WG creds)
- **Disk**: D: drive is repo-only; downloads/test artifacts/scratch go on H: drive
- **Identity**: Never boot a test VM with baked WG config while the real box is live (shared `10.8.0.2` identity theft)

<!-- GSD:project-end -->

<!-- GSD:stack-start source:codebase/STACK.md -->

## Technology Stack

## Languages

- **Bash** - Build scripts, system configuration, service management
- **Python** 3.12 - Web UI backend (FastAPI)
- **JavaScript** - Static frontend (plain JS, no framework)
- **YAML** - Docker Compose, GitHub Actions workflows

## Runtime

- **Debian 13 (Trixie)** - Target operating system for the appliance
- **Docker** - Container runtime for application stack
- **Linux kernel** - UEFI/Secure Boot compatible
- **pip** - Python dependency management (in Web UI container)
- **apt** - Debian package management (image build)
- **Docker Compose** - Multi-container orchestration

## Frameworks

- **FastAPI** 0.115.x - REST API framework for Web UI backend
- **Uvicorn** 0.32.x - ASGI server for FastAPI
- **Docker Compose** - Orchestrates multi-service stack
- **PowerShell** test modules (`tests/test-*.ps1`) - Local builder validation
- **debootstrap** - Creates base Debian filesystem
- **live-build** - Installer ISO generation
- **GitHub Actions** - CI/CD pipeline (`.github/workflows/`)

## Key Dependencies

- **thijsvanloef/palworld-server-docker:latest** - Official Palworld dedicated server image (community-maintained)
- **offen/docker-volume-backup:v2** - Automated backup with cron + Discord notifications
- **containrrr/watchtower:latest** - Automatic container image updates
- **NetBird** - Primary VPN/mesh network overlay (`netbird` branch default)
- **WireGuard** (deprecated, optional) - Legacy VPN tunnel (disabled by default unless `PPSA_WG_ENABLED=true`)
- **Prometheus:latest** - Metrics collection and storage (14-day retention)
- **Grafana:latest** - Visualization and dashboards
- **prom/node-exporter:latest** - System metrics export

## Configuration

- **Variables driven by Docker Compose `.env` file:** `SERVER_NAME`, `ADMIN_PASSWORD`, `MAX_PLAYERS`, `BACKUP_SCHEDULE`, `BACKUP_RETENTION_DAYS`, `DISCORD_WEBHOOK_URL`, `PALWORLD_API_URL`, `PALWORLD_ADMIN_PASSWORD`, `TZ`, `PPSA_CPUS`, `PPSA_MEMORY`
- **Web UI dynamic config:** `/opt/ppsa/.env` (read/write via `/api/env` endpoints)
- **First-boot configuration:** `scripts/install.sh` runs on first boot via `ppsa-firstboot.service`
- **Dockerfile** - Web UI container image definition (`docker/webui/Dockerfile`)
- **docker-compose.yml** - Main stack (`compose/docker-compose.yml`)
- **docker-compose.monitoring.yml** - Optional monitoring overlay
- **Dockerfile.build** - WSL local builder image (non-canonical, for reference only)
- `PPSA_WG_ENABLED` - Controls WireGuard enablement (default `false`)
- `PPSA_NB_SETUP_KEY`, `PPSA_NB_MANAGEMENT_URL` - NetBird unattended enrollment
- `PPSA_WG_API_URL`, `PPSA_WG_API_USER`, `PPSA_WG_API_PASS` - WireGuard registration (deprecated)
- `PPSA_EXPOSE_SSH_LAN` - Opt-in SSH exposure over LAN (default false = WireGuard-only)

## Platform Requirements

- **Linux** (Ubuntu 20.04+) or **Windows 11 with WSL2** for image building
- **Docker** and **Docker Compose** v2+ on builder machine
- **Git** for version control
- **zstd** compression utility (for GitHub release artifacts)
- **x86-64 CPU** with UEFI firmware (Secure Boot optional but supported)
- **USB SSD or physical disk** (8GB+ bare minimum; 12GB recommended)
- **Network connectivity** for first-boot setup and NetBird enrollment
- **8GB+ disk space** after Debian + Docker overhead, before Palworld server data
- **GitHub Actions** (ubuntu-latest runners) - canonical build path
- **Local WSL builder** (Windows + PowerShell modules) - optional fast iteration

## Build & Distribution

- **ppsa-usb-vX.Y.Z.img.zst** - zstd-compressed 8GB disk image (USB/SSD boot)
- **ppsa-vbox-vX.Y.Z.vdi.zst** - 4GB VirtualBox VDI image (test/dev)
- **ppsa-installer-vX.Y.Z.iso** - Debian Live ISO with embedded installer script
- **zstd -10** for release artifacts (~10x faster than xz, similar ratio)
- **zstd -3** for CI caching (build-live-usb.sh rootfs cache)
- **v1.3.0-nb.N** pattern (netbird branch, prerelease)
- **v1.2.x** pattern (master branch, frozen/archived)
- Hyphen in tag auto-marks GitHub release as prerelease

<!-- GSD:stack-end -->

<!-- GSD:conventions-start source:CONVENTIONS.md -->

## Conventions

## Naming Patterns

- Bash scripts: lowercase with hyphens: `ppsa-firewall-apply.sh`, `ppsa-wifi-onboard.sh`
- PowerShell modules: PascalCase: `Logger.psm1`, `Builder.psm1`, `Configuration.psm1`
- PowerShell scripts: PascalCase with hyphen for main orchestrator: `Start-PpsaBuilder.ps1`
- Python: lowercase with underscores: `main.py`
- Test files: `test-<name>.ps1` pattern for PowerShell tests
- **Python:** lowercase with underscores for private helpers (`_hash_pw`, `_verify_pw`, `_read_file`); lowercase for public routes (`health`, `dashboard`, `login`)
- **PowerShell:** Verb-Noun PascalCase following PowerShell standards: `Initialize-Logger`, `Write-LogInfo`, `Invoke-CommandCapture`, `Test-WslAvailable`, `Get-FileHashVerified`
- **Bash:** lowercase with underscores: `mark_step`, `ensure_loop_partition_node`; no verb-noun convention
- **Python:** lowercase with underscores: `DATA_DIR`, `JWT_SECRET`, `PALWORLD_API_URL` (constants, uppercase)
- **PowerShell:** PascalCase for parameters and script-scoped vars: `$WslUser`, `$LogDirectory`, `$RepoRoot`; `$script:` prefix for module-scope globals
- **Bash:** UPPERCASE for constants and configuration: `PPSA_DIR`, `BUILD_DIR`, `CHAIN`, `WG_NET`
- **Python:** Pydantic `BaseModel` for request/response objects: `ConnectRequest`, `FirewallConfig`
- **PowerShell:** `[PSCustomObject]` for structured returns, explicit type hints on parameters: `[string]$LogDirectory`, `[hashtable]$ExtraEnv`

## Code Style

- **Python:** 
- **PowerShell:**
- **Bash:**
- No `.eslintrc`, `.prettierrc`, or `biome.json` found
- No explicit Python linter config (no `pyproject.toml` or `.flake8`)
- PowerShell: no explicit linter config; style follows PowerShell best practices by convention
- "ponytail: " prefix on comments indicates non-obvious design decisions or workarounds (seen in `docker/webui/app/main.py:30`, `scripts/install.sh:28`, `modules/Builder.psm1:35`)
- Explicit disable of `set -o pipefail` with justification in `scripts/install.sh:12-15`
- Comments explain **why**, not what (see `docker/webui/app/main.py:288-293` on Palworld empty-response handling)

## Import Organization

- Modules imported via `Import-Module` with path resolution
- Order: Utils → Logger → domain modules (Configuration, GitHub, Queue, Builder, Artifacts, VirtualBox, Status, SmokeTest)
- Example from `Start-PpsaBuilder.ps1:24`: "hardcoded module order matches build dependency chain"
- Direct script sourcing (no import mechanism); helper functions defined inline
- Environment variables set at top of script

## Error Handling

- HTTPException for API errors: `raise HTTPException(status_code=401, detail="...")`
- Try/except for external calls (Palworld API, Docker exec, host exec)
- Graceful degradation in `palworld_get`: optional `default=` parameter returns default instead of raising on transient errors
- Example: `docker/webui/app/main.py:247-275` shows pattern for upstream failures
- `$ErrorActionPreference = "Stop"` at top of script (strict error handling)
- Try/catch blocks for external process calls
- Return structured objects with `Valid`, `Hash`, `Error` fields: `[PSCustomObject]@{ Valid = $false; Hash = $null; Error = "..." }`
- Example: `modules/Utils.psm1:48-68` (Get-FileHashVerified)
- `set -euo pipefail` (or `set -eu` with explicit `set +o pipefail` comment)
- Exit codes checked explicitly: `if [ $RC -eq 0 ]`
- Subshells for scoped error disabling: `(set +e; command; RC=$?)`
- Example: `scripts/install.sh:74-99` subshell with bounded timeouts and explicit RC checks

## Logging

- **Python:** No framework; uses direct `print()` and file writes for logs (simple approach for single-app container)
- **PowerShell:** Custom `Logger.psm1` module with structured output
- **Bash:** Direct `echo` to stdout/file (captured by systemd journal or explicit redirect)
- Convenience wrappers: `Write-LogInfo`, `Write-LogError`, `Write-LogSuccess`
- Output: console (colored) + file (`build.log`), plus level-specific logs (`trace.log`, `error.log`)
- Timestamps in `yyyy-MM-dd HH:mm:ss.fff` format
- No structured logging; comments document key decision points
- Exception messages included in HTTPException detail field
- Host-exec commands return tuples: `(exit_code, stdout, stderr)` for caller inspection
- Direct echo to stdout; systemd captures as journal
- Progress file updates: `echo "$n" > "$PROGRESS_FILE"` for external progress tracking
- Log file redirect: `exec > "$LOG_FILE" 2>&1`

## Comments

- **Design decisions:** "ponytail: " prefix for non-obvious choices (e.g., why `set +o pipefail` is used, why direct chroot is a fallback)
- **API quirks:** Documented where third-party APIs have surprising behavior (e.g., Palworld returns empty 200 on save success)
- **Bug workarounds:** Explicit call-outs for known issues (e.g., bcrypt ≥4.0 behavior change in `main.py:30`)
- **Timing/performance notes:** When operations are intentionally slow or have ordering constraints
- Not used (this is not a TypeScript/JavaScript codebase)
- Python docstrings: inline one-liners for FastAPI routes and helper functions
- Example: `docker/webui/app/main.py:62` (lifespan context manager docstring)

## Function Design

- **Python:** Typically 10-50 lines for routes; complex logic (WG tunnel, firewall) spans 30-100 lines with clear subsections
- **PowerShell:** 15-40 lines per function; module-level scripts are longer (orchestrator `Start-PpsaBuilder.ps1` is ~300 lines but well-commented)
- **Bash:** 5-20 lines for helper functions; main script body is linear for clarity (e.g., `scripts/install.sh` is 200+ lines but marked with numbered steps)
- **Python:** Explicit Pydantic models for complex payloads; query/path parameters via FastAPI dependency injection
- **PowerShell:** `[CmdletBinding()]` with explicit parameter types and validation; hashtable for optional key-value sets
- **Bash:** Positional args and environment variables; no function parameters except helpers
- **Python:** JSON dict/list (via FastAPI automatic serialization) or HTTPException on error
- **PowerShell:** Explicit `return` statement with structured object (`[PSCustomObject]`) or error via `throw`
- **Bash:** Exit code (0 success, non-zero error); stdout for string output; files for structured output (e.g., JSON result files)

## Module Design

- **PowerShell:** Explicit `Export-ModuleMember -Function ...` at end of `.psm1` file (e.g., `modules/Logger.psm1:155`)
- **Python:** No module exports; single `main.py` FastAPI app
- **Bash:** No module system; functions defined in script or sourced from other scripts
- Not used (no ES6-style re-exports)
- Python has no internal module structure
- PowerShell modules are atomic (one `.psm1` per module)

## Configuration Management

- Read from `.env` file via `_parse_env()` in `docker/webui/app/main.py:436-446`
- Passed to build scripts via `PPSA_*` prefixed vars
- PowerShell reads from `wireguard.local.json` and `builder.json` (JSON, not env vars)
- Environment variables control feature flags (e.g., `PPSA_WG_ENABLED=true/false`)
- JSON configs for complex nested settings (firewall rules, WireGuard credentials)
- Secrets in `.env` are never logged or quoted in comments

<!-- GSD:conventions-end -->

<!-- GSD:architecture-start source:ARCHITECTURE.md -->

## Architecture

## System Overview

```text

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

- **Single-source Principle**: `build-live-usb.sh` is the only script that formats, partitions, and installs the Debian image. CI/installer glue never duplicates this logic.
- **Unattended First-Boot**: All post-install setup (Docker, networking, firewall) runs via `ppsa-install.service` → `install.sh` on first boot, with live progress display on tty1.
- **Fail-Safe Defaults**: WireGuard disabled by default (`enabled: false` in `wireguard.json`); NetBird primary; firewalls default-deny except SSH + tunnel. Build-time flags override.
- **Layered Networking**: UFW (global rules) + iptables `WG_FRIENDS` chain (tunnel subnet), editable at runtime from WebUI.
- **Containerized Services**: Docker Compose brings up isolated, health-checked services; no systemd service interdependencies needed.

## Layers

- Purpose: Create bootable disk images from source code
- Location: `scripts/build-live-usb.sh`, `modules/*.psm1`, `.github/workflows/`
- Contains: Debootstrap bootstrap, partition/mount logic, GRUB/shim installation, Docker Compose and config file copying into rootfs
- Depends on: Debian toolchain, GPG keys for signed GRUB/shim (if available)
- Used by: GitHub Actions CI, local PowerShell builder, installer ISO builder
- Purpose: Initialize the appliance after power-on (one-shot)
- Location: `scripts/install.sh`, `scripts/ppsa-firstboot.sh`, `systemd/*.service` files in chroot
- Contains: Docker startup, environment config, Docker Compose pull/up, Wi-Fi/WireGuard/NetBird setup, firewall rules, partition resize
- Depends on: Docker daemon, root privilege, mounted rootfs (already present from build)
- Used by: `ppsa-install.service` (systemd) on first boot only
- Purpose: Deliver game server, management UI, networking, backups
- Location: `compose/docker-compose.yml`, `docker/webui/app/`, `scripts/ppsa-*.sh` (daemons)
- Contains: Palworld container, FastAPI WebUI app, WireGuard Dashboard, backup cron, auto-updater
- Depends on: Docker daemon, network access (to pull images)
- Used by: Systemd (starts compose stack), WebUI (calls `docker exec` for control)

## Data Flow

### Primary Request Path (User → WebUI → Game Server)

- `docker/webui/app/main.py` lines 345-362 (dashboard handler)
- `docker/webui/app/main.py` lines 247-275 (palworld_get proxy)
- `compose/docker-compose.yml` lines 30-86 (palworld service definition, port 8212)

### Firewall Control Path (WebUI → iptables)

- `docker/webui/app/main.py` (firewall_update handler, _host_exec)
- `scripts/ppsa-firewall-apply.sh` (reads firewall.json, applies iptables)
- Mounted volumes: `/etc/ppsa:rw` (persistent firewall config)

### First-Boot Initialization Path

- `scripts/install.sh` (main orchestrator, 9 steps)
- `scripts/ppsa-firstboot.sh` (tty1 progress display)
- `scripts/ppsa-wifi-onboard.sh` (hostapd script, started via service)
- `scripts/ppsa-wireguard-register.sh` (if WG enabled)
- `scripts/ppsa-netbird-up.sh` (if NetBird config exists)
- Systemd unit files in chroot: `ppsa-install.service`, `ppsa-wifi-onboard.service`, etc.
- Progress tracked in `/run/ppsa-install.progress` (integer, highest step entered)
- Completion flag: `/opt/ppsa/.installed` (file existence)
- Logs: `/var/log/ppsa-install.log` (captured stdout/stderr from install.sh)
- Environment: `.env` file in `/opt/ppsa/.env` (sourced by Docker Compose)

## Key Abstractions

- Purpose: Distinguishes USB image, VirtualBox VDI, and installer ISO without code duplication
- Examples: `ppsa-usb-v1.3.0-nb.1.img.zst`, `ppsa-vbox-v1.3.0-nb.1.vdi.zst`, `ppsa-installer-v1.3.0-nb.1.iso.zst`
- Pattern: Single `build-live-usb.sh` produces raw `.img`, then post-processing converts to VDI (in CI) or bundles into live-build ISO (separate workflow)
- Purpose: Represents a single build request with tag, logs, artifacts
- Pattern: Jobs queued in `Queue.psm1`, dequeued and executed by `Builder.psm1`, results stored in `status.json` and `history.json`
- Files: `modules/Queue.psm1`, `modules/Builder.psm1`, `modules/Status.psm1`
- Purpose: Runtime-editable configuration without rebuilding
- Examples: `firewall.json` (allowed ports), `wireguard.json` (tunnel settings), `.env` (Docker Compose variables)
- Pattern: Written by WebUI, read/applied by shell scripts, persisted to `/etc/ppsa/` or `.env` in the appliance
- Purpose: Bridge containerized WebUI to host OS (nsenter + chroot)
- Pattern: `_host_exec()` in `main.py` calls `sudo /script` via subprocess, WebUI container has `cap_add: NET_ADMIN` + bind mount `/:/host:ro`
- Examples: Wi-Fi scan, firewall update, NetBird status check
- File: `docker/webui/app/main.py` lines ~500 (_host_exec function)

## Entry Points

- Location: `.github/workflows/build-release.yml` and `.github/workflows/build-installer.yml`
- Triggers: Tag push (build-release), manual workflow_dispatch (both)
- Responsibilities: Call `build-live-usb.sh` in Ubuntu runner, convert IMG to VDI, generate checksums, upload artifacts or publish release
- Files: `.github/workflows/build-*.yml`
- Location: `scripts/Start-PpsaBuilder.ps1`
- Triggers: Manual `pwsh Start-PpsaBuilder.ps1 -Watch` or single-shot
- Responsibilities: Poll GitHub issue for comments, queue builds, call `build-live-usb.sh` in WSL, boot VDI in VirtualBox, smoke test, capture logs
- Files: `scripts/Start-PpsaBuilder.ps1`, `modules/*.psm1`
- Location: `ppsa-install.service` (in chroot, runs `install.sh`)
- Triggers: Automatic on first power-on
- Responsibilities: Run 9 initialization steps, log progress, bring up Docker stack, configure networking
- Files: `scripts/install.sh`, `scripts/ppsa-firstboot.sh`
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

- Example: `scripts/build-live-usb.sh` lines ~1800 (copy `.env.example` to rootfs, but not `.env`)
- Example: `scripts/install.sh` lines 112-117 (copies `.env.example` → `.env` only on first boot)

### Direct Docker Command in WebUI (CLI Binary)

- Example: `docker/webui/app/main.py` lines 20-23 (import docker SDK, mount socket in compose)
- Example: `docker/webui/app/main.py` lines 177-239 (_run_docker using SDK, not subprocess)

### Synchronous Backup Blocking Event Loop

- Example: `docker/webui/app/main.py` lines 228-234 (detach=True for backup, returns immediately)

### Empty JSON Response on 200

- Example: `docker/webui/app/main.py` lines 291-299 (palworld_post checks empty text, tolerates non-JSON)

### Hot Tar of Live Palworld Saves

- Example: `compose/docker-compose.yml` lines 78-85 (palworld service has `docker-volume-backup.stop-during-backup=true` label)

## Error Handling

- **Build Phase:** Early `set -Eeuo pipefail` in Bash; errors abort immediately with exit code. CI captures logs before reporting failure. PowerShell uses try/catch around modules; build continues to logging phase even on failure (so logs are persisted).
- **First-Boot:** Each step is wrapped in `mark_step()` to log progress. If a step fails (e.g., Docker pull timeout), log a WARNING and continue to the next step (e.g., try `docker compose up` with cached images). Failure is not fatal; the system boots and user can retry from WebUI.
- **Runtime:** WebUI endpoints catch exceptions and return HTTP 500 with error message. Frontend displays "Server unavailable" banner but remains usable. Long-running operations (backup, game shutdown) are detached or wrapped in background tasks to prevent UI freeze.
- **Networking:** `palworld_get()` has optional `default=` parameter; callers can suppress exceptions and render empty state (e.g., on transient server downtime) instead of failing the entire dashboard.
- `scripts/build-live-usb.sh` line 15 (set -euo pipefail, aborts on any error)
- `scripts/install.sh` lines 122-138 (docker pull with retry loop, continues on failure)
- `docker/webui/app/main.py` lines 345-362 (dashboard catches exception, returns partial response)

## Cross-Cutting Concerns

- **Build:** Bash uses `set -x` + PS4 timestamps for execution trace. PowerShell uses `Logger.psm1` (structured logging with timestamp, level, module, message + command/exit code/location/action). All logs written to `H:\dev\palimage\logs\` (configurable in `builder.json`).
- **First-Boot:** Shell script writes to `/var/log/ppsa-install.log` (captured early via `exec` redirection). Progress file (`/run/ppsa-install.progress`) tracks step number for tty1 display.
- **Runtime:** Docker containers use `json-file` driver with log rotation (max 10MB, keep 3 files). WebUI logs to uvicorn stdout (captured by systemd journal).
- **Files:**
- **Config Parsing:** JSON files (firewall.json, wireguard.json, builder.json) are parsed with error handling (try/except in Python, ConvertFrom-Json in PowerShell). Invalid JSON logs a warning and uses defaults.
- **Artifact Verification:** After build, checksums are generated (SHA256) and compared against file before upload. Manifest (manifest.json) tracks artifact metadata.
- **Container Health Checks:** Each service in compose has a healthcheck (e.g., `curl -f http://localhost:8080/health` for WebUI, `rcon-cli Info` for Palworld). Systemd depends on health, not just container-started.
- **Files:**
- **WebUI:** HTTP Basic auth on `/api/login` endpoint returns a JWT token. Subsequent requests require Bearer token in Authorization header. Token expiry: 24 hours. Password hashed with bcrypt (cost factor 4).
- **Palworld API Proxy:** WebUI authenticates to Palworld REST API with hardcoded `admin` user + `PALWORLD_ADMIN_PASSWORD` env var. Credentials never sent to browser (proxy pattern).
- **Host-Exec:** WebUI calls host scripts via `sudo` (passwordless, specific commands whitelisted in sudoers or via capability elevation). No direct shell access from WebUI to host.
- **Files:**

<!-- GSD:architecture-end -->

<!-- GSD:skills-start source:skills/ -->

## Project Skills

| Skill | Description | Path |
|-------|-------------|------|
| ppsa-guest-ops | Interact with a running PPSA appliance VM or box - console injection, LAN SSH access, deploying uncommitted patches (WebUI container code, host scripts, systemd units), WebUI API testing, and VirtualBox-on-this-host gotchas (soft lockups, no guest additions). Use for any hands-on work inside a booted PPSA system. | `.claude/skills/ppsa-guest-ops/SKILL.md` |
| ppsa-installer-test | Install PPSA from an installer ISO into a fresh VirtualBox VM and run the full smoke/functional test. Use when asked to test an installer ISO, verify a release build, or reproduce the appliance install flow. Covers VM creation, blind TUI keystrokes (scancodes), first-boot phases, SSH access recipe, and the verification checklist. | `.claude/skills/ppsa-installer-test/SKILL.md` |
| ppsa-release-build | Trigger, monitor, and download PPSA CI builds (release image + installer ISO) from GitHub Actions. Use when asked to build, tag, release, pre-release, or fetch a PPSA build artifact. Never build locally. | `.claude/skills/ppsa-release-build/SKILL.md` |
| ppsa-wg-hub-ops | Operate and diagnose the PPSA WireGuard network via the wg-easy hub API - list/delete peers, check handshakes, diagnose a dead/unreachable PPSA server or Windows client, distinguish site outages from appliance bugs. Use when WG connectivity fails, a peer is unreachable, or hub cleanup is needed. | `.claude/skills/ppsa-wg-hub-ops/SKILL.md` |
<!-- GSD:skills-end -->

<!-- GSD:workflow-start source:GSD defaults -->

## GSD Workflow Enforcement

Before using Edit, Write, or other file-changing tools, start work through a GSD command so planning artifacts and execution context stay in sync.

Use these entry points:

- `/gsd-quick` for small fixes, doc updates, and ad-hoc tasks
- `/gsd-debug` for investigation and bug fixing
- `/gsd-execute-phase` for planned phase work

Do not make direct repo edits outside a GSD workflow unless the user explicitly asks to bypass it.
<!-- GSD:workflow-end -->

<!-- GSD:profile-start -->

## Developer Profile

> Profile not yet configured. Run `/gsd-profile-user` to generate your developer profile.
> This section is managed by `generate-claude-profile` -- do not edit manually.
<!-- GSD:profile-end -->
