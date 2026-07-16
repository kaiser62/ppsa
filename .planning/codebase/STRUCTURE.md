# Codebase Structure

**Analysis Date:** 2026-07-16

## Directory Layout

```
palworld-self-containing-server/
├── .github/
│   └── workflows/           # GitHub Actions CI/CD pipelines
│       ├── build-release.yml    # Tag push: build USB + VDI, publish release
│       └── build-installer.yml  # Manual: build Debian Live installer ISO
│
├── scripts/                 # Shell scripts (build, init, runtime daemons)
│   ├── build-live-usb.sh        # Core builder: formats partitions, installs Debian, GRUB/shim, copies config
│   ├── install.sh               # First-boot (9 steps): Docker, env, stack, Wi-Fi, firewall
│   ├── ppsa-firstboot.sh        # First-boot tty1 progress display
│   ├── ppsa-firewall-apply.sh   # Reads firewall.json, applies iptables WG_FRIENDS chain
│   ├── ppsa-firewall-request.*  # Path/service: watches firewall.json, triggers apply
│   ├── ppsa-wifi-onboard.sh     # Hostapd/dnsmasq hotspot for initial network config
│   ├── ppsa-wifi-onboard.service
│   ├── ppsa-wireguard-register.sh  # Registers peer with wg-easy, applies fallback config
│   ├── ppsa-wireguard-register.service
│   ├── ppsa-netbird-up.sh       # Enrolls in NetBird control plane
│   ├── ppsa-netbird-up.service
│   ├── ppsa-wg-status-snapshot.sh   # Captures WireGuard peer status JSON
│   ├── ppsa-wg-status-snapshot.*    # Service + timer
│   ├── ppsa-docker-compose.service  # Brings up compose stack (if needed separately)
│   ├── ppsa-firstboot.service       # Orchestrator for install.sh on first boot
│   ├── ppsa-wg-manual-apply.sh      # Legacy: manual WireGuard config apply
│   ├── ppsa-wg-manual-apply.*       # Path/service
│   ├── first-boot.sh                # Deprecated early version
│   ├── setup-wireguard.sh           # Deprecated WireGuard setup
│   └── Start-PpsaBuilder.ps1        # PowerShell: local builder orchestrator (WSL + VBox)
│
├── modules/                 # PowerShell modules (local builder internals)
│   ├── Logger.psm1          # Structured logging: timestamp, level, module, message, context
│   ├── Configuration.psm1   # Loads builder.json config
│   ├── Utils.psm1           # Helpers: timers, file ops, string manipulation
│   ├── GitHub.psm1          # Polls GitHub issue comments for build triggers
│   ├── Queue.psm1           # In-memory build job queue (prevents concurrent builds)
│   ├── Builder.psm1         # Executes build-live-usb.sh in WSL, captures logs
│   ├── Artifacts.psm1       # Verifies checksums, manages IMG/VDI symlinks
│   ├── VirtualBox.psm1      # Boots VDI in VBox, waits for login
│   ├── Status.psm1          # Writes status.json, history.json build records
│   └── SmokeTest.psm1       # Runs WebUI /health checks, verifies boot
│
├── docker/                  # Docker images and configs
│   └── webui/
│       ├── app/
│       │   ├── main.py              # FastAPI: REST API + SPA server, Palworld proxy, firewall control
│       │   ├── requirements.txt     # FastAPI, bcrypt, docker SDK, httpx
│       │   ├── static/
│       │   │   └── index.html       # Single-page app (plain JS, no build step)
│       │   └── __pycache__/
│       └── Dockerfile              # Python 3.12-slim + FastAPI entrypoint
│
├── compose/                 # Docker Compose stack definitions
│   ├── docker-compose.yml           # Main stack: palworld, webui, wgdashboard, backup, watchtower
│   └── docker-compose.monitoring.yml # Optional: Prometheus + Grafana overlay
│
├── installer/              # Debian Live ISO builder config (live-build project)
│   ├── auto/
│   │   ├── build            # Live-build build script entry point
│   │   └── config           # Live-build config
│   ├── config/
│   │   ├── hooks/normal/    # Live-build hooks (enable ppsa-installer.service in ISO)
│   │   ├── includes.chroot/ # Files to bake into ISO rootfs
│   │   │   ├── etc/systemd/system/ppsa-installer.service
│   │   │   └── usr/local/bin/ppsa-install  # Main installer script (writes PPSA to target disk)
│   │   ├── package-lists/   # Debian packages to include in ISO
│   │   └── ...              # Other live-build config
│   └── .gitignore           # Binary build artifacts
│
├── builder.json             # Local builder config: output dir, WSL user, GitHub repo, VBox VM name, logging
│
├── .env.example             # Template for Docker Compose environment (SERVER_NAME, ADMIN_PASSWORD, etc.)
│
├── wireguard.json           # WireGuard peer config (disabled by default, re-enable with PPSA_WG_ENABLED)
│
├── wireguard.local.json     # Gitignored: wg-easy API creds for local builds
│
├── firewall.json            # Editable firewall rules (allowed ports, toggled by WebUI)
│
├── PalWorldSettings.env.example  # Legacy Palworld server settings template
│
├── MASTER_PLAN.md           # Development plan for PowerShell local builder (15 milestones)
│
├── CLAUDE.md                # Project-level instructions for Claude Code
│
├── docs/                    # Documentation
│   ├── architecture.md      # System design, boot chain, networking, Docker stack
│   ├── local-builder.md     # How to run Start-PpsaBuilder.ps1
│   ├── installation.md      # Quick start (deprecated, see docs/architecture.md)
│   ├── deployment-guide.md  # Hardened deployment on real hardware
│   ├── dual-boot-install.md # Installing PPSA alongside existing OS
│   ├── wifi-onboarding.md   # Wi-Fi hotspot initial setup
│   ├── wireguard-setup.md   # WireGuard tunnel configuration
│   ├── netbird-setup.md     # NetBird setup and troubleshooting
│   ├── troubleshooting.md   # Common issues and fixes
│   └── test-reports/        # Manual test results (populated by local builder)
│
├── netbird-server/          # Self-hosted NetBird control plane (optional)
│   ├── config.yaml          # Must have exposedAddress with explicit :443 for P2P
│   ├── dashboard.env        # Dashboard service env vars
│   └── docker-compose.yml   # NetBird + Dex + Dashboard
│
├── configs/                 # Config templates
│   └── PalWorldSettings.env.example
│
├── tests/                   # PowerShell module unit tests (not comprehensive)
│   ├── test-logger.ps1
│   └── test-*.ps1
│
├── assets/                  # Documentation assets (images, diagrams)
│
├── backups/                 # Local backup storage (created by docker-volume-backup)
│
├── monitoring/              # Monitoring overlay configs
│   ├── grafana-dashboards/
│   └── grafana-datasources/
│
├── wireguard/               # Deprecated: legacy wg-easy configs (superceded by wireguard.json)
│
├── webui/                   # Deprecated early WebUI (orphaned)
│   ├── backend/
│   └── frontend/
│
├── graphify-out/            # Knowledge graph cache (generated by graphify skill)
│   └── cache/
│
├── oracle/                  # Undocumented utility code
│
├── .planning/               # Planning documents
│   └── codebase/            # Generated by gsd-map-codebase skill
│       ├── ARCHITECTURE.md  # THIS FILE
│       ├── STRUCTURE.md     # DIR LAYOUT + LOCATIONS
│       ├── CONVENTIONS.md   # Code style + patterns
│       ├── TESTING.md       # Test framework + patterns
│       ├── STACK.md         # Languages, frameworks, deps
│       ├── INTEGRATIONS.md  # External APIs, services
│       └── CONCERNS.md      # Tech debt, issues
│
├── .claude/                 # Claude Code project config
│   └── skills/              # Project-specific skills
│
└── .git/                    # Git repository
```

## Directory Purposes

**scripts/**
- Purpose: All shell and PowerShell scripts (build, first-boot, runtime daemons)
- Contains: Bash (build-live-usb.sh, install.sh, daemon scripts) + PowerShell (Start-PpsaBuilder.ps1, local iteration)
- Key files: `build-live-usb.sh` (core builder, 50KB+), `install.sh` (first-boot, 22KB), `Start-PpsaBuilder.ps1` (orchestrator, 11KB)

**modules/**
- Purpose: PowerShell modules for local builder (logging, GitHub polling, build queue, VBox control)
- Contains: 10 PSM1 files implementing the MASTER_PLAN milestones
- Key files: `Logger.psm1` (structured logging framework), `Builder.psm1` (WSL build execution), `SmokeTest.psm1` (VBox boot + health check)

**docker/webui/app/**
- Purpose: The **only** live WebUI code (FastAPI backend + static SPA)
- Contains: `main.py` (1000+ lines), `requirements.txt`, `static/index.html`
- Key files: `main.py` (REST API, Palworld proxy, firewall control, Wi-Fi scan)

**compose/**
- Purpose: Docker Compose stack definition (5 services: Palworld, WebUI, WireGuard Dashboard, backup, watchtower)
- Contains: Main compose file + optional monitoring overlay
- Key files: `docker-compose.yml` (620 lines), defines all services, volumes, networking, healthchecks

**installer/**
- Purpose: Debian Live ISO builder (bundles seed image + ppsa-install installer script)
- Contains: live-build project config (auto/config, config/hooks, config/includes.chroot)
- Key files: `config/includes.chroot/usr/local/bin/ppsa-install` (the actual disk-write script)

**docs/**
- Purpose: User and operator documentation
- Contains: Architecture overview, deployment guides, networking setup, troubleshooting
- Key files: `architecture.md` (best overview), `deployment-guide.md` (hardening), `netbird-setup.md` (current primary networking)

**netbird-server/**
- Purpose: Optional self-hosted NetBird control plane (for users who want to own their overlay DNS/auth)
- Contains: config.yaml, docker-compose.yml, dashboard.env
- Key files: `config.yaml` (must have `exposedAddress: <ip>:443` for P2P to work)

## Key File Locations

**Entry Points:**
- `scripts/build-live-usb.sh`: Image build (called by CI and PowerShell builder)
- `scripts/Start-PpsaBuilder.ps1`: Local builder orchestrator (manual `pwsh Start-PpsaBuilder.ps1 -Watch`)
- `.github/workflows/build-release.yml`: CI pipeline (tag push or manual dispatch)
- `scripts/install.sh`: First-boot orchestrator (runs unattended on first power-on)

**Configuration:**
- `builder.json`: Local builder settings (output dir, GitHub repo, WSL user, VBox VM name)
- `.env.example`: Docker Compose env template (copy to `.env` and customize)
- `wireguard.json`: WireGuard tunnel settings (disabled by default)
- `firewall.json`: Editable firewall rules (runtime, persisted in /etc/ppsa)

**Core Logic:**
- `docker/webui/app/main.py`: FastAPI server, REST API routes, Palworld proxy, firewall control
- `scripts/ppsa-firewall-apply.sh`: Reads firewall.json, applies iptables rules
- `scripts/ppsa-wifi-onboard.sh`: Hostapd/dnsmasq Wi-Fi hotspot
- `scripts/ppsa-wireguard-register.sh`: Registers with wg-easy API
- `scripts/ppsa-netbird-up.sh`: Enrolls in NetBird control plane

**Testing:**
- `tests/test-*.ps1`: Unit tests for PowerShell modules (minimal coverage)
- No pytest/unittest suite for WebUI (verify manually via FastAPI /docs)

**Documentation:**
- `CLAUDE.md`: Project-level instructions (branch strategy, build policy, architecture notes)
- `MASTER_PLAN.md`: Dev plan for PowerShell builder (15 milestones, ~600 lines)
- `docs/architecture.md`: System design, boot chain, Docker stack
- `docs/deployment-guide.md`: Hardening checklist, production deployment

## Naming Conventions

**Files:**
- Shell scripts: `ppsa-<function>.sh` (e.g., `ppsa-firewall-apply.sh`, `ppsa-wifi-onboard.sh`)
- Systemd units: `ppsa-<function>.service`, `ppsa-<function>.path`, `ppsa-<function>.timer` (e.g., `ppsa-firewall-request.service`)
- PowerShell modules: `<Category>.psm1` (e.g., `Logger.psm1`, `Builder.psm1`)
- Docker images: internal only; compose file names convention (`docker-compose.yml`, optional overlay `docker-compose.monitoring.yml`)
- Config files: JSON with clear names (`firewall.json`, `wireguard.json`, `builder.json`)

**Directories:**
- Short English names, lowercase, hyphens for clarity (`docker/webui`, `docker/webui/app`, `compose`, `installer`, `modules`, `scripts`)
- No deep nesting; most code is 1-2 levels from root

## Where to Add New Code

**New Feature (e.g., new WebUI page or API endpoint):**
- Primary code: `docker/webui/app/main.py` (add new async def handler with @app.get or @app.post decorator)
- Tests: Not automated; verify manually via `curl` or FastAPI /docs
- Static assets: `docker/webui/app/static/index.html` (add HTML/JS for new page)
- Example: Adding `/api/settings` endpoint → Add handler in main.py + form in index.html

**New Runtime Daemon (e.g., monitor container logs every 5 min):**
- Script: `scripts/ppsa-<function>.sh` (e.g., `ppsa-log-monitor.sh`)
- Service file: `scripts/ppsa-<function>.service` (Type=simple or Type=oneshot)
- Timer: `scripts/ppsa-<function>.timer` (if periodic)
- Integration: Bake into image by adding copy line to `build-live-usb.sh` (~line 1400)
- Example: Log monitoring → ppsa-log-monitor.sh + ppsa-log-monitor.service, copy to /etc/systemd/system in chroot

**New Build Capability (e.g., add support for Debian bookworm):**
- Core logic: `scripts/build-live-usb.sh` (e.g., change DEBIAN_VERSION variable)
- Testing: Trigger locally with `pwsh Start-PpsaBuilder.ps1` or CI with `gh workflow run build-release.yml -f debian_version=bookworm`
- Example: Version bump → Update DEBIAN_VERSION in build-live-usb.sh, tag, push

**New Utility/Helper:**
- PowerShell: Add function to relevant `modules/*.psm1` (e.g., new logging format → Logger.psm1), export via Export-ModuleMember
- Shell: Add function to `scripts/build-live-usb.sh` or new script in `scripts/`, source it from others
- Python: Add to `docker/webui/app/main.py` or split into new module if complex
- Example: New disk utility → Add function to Utils.psm1, import in Start-PpsaBuilder.ps1

**New Systemd Integration (e.g., auto-start certain services):**
- Service file: `scripts/ppsa-<function>.service` or `/etc/systemd/system/` entries baked into rootfs
- Enablement: Add to `build-live-usb.sh` chroot configuration (~line 1600) to call `systemctl enable ppsa-<service>`
- Ordering: Use `Before=`, `After=`, `ConditionPathExists=` in service file to control boot sequence
- Example: New monitoring service → ppsa-monitor.service, systemctl enable in build script, runs on every boot

## Special Directories

**build-live-usb.sh internals (not checked in):**
- `$TMPDIR/ppsa-build/` (or `/tmp/ppsa-build`): Temporary build directory during image creation
- Contains: `rootfs/` (Debian chroot), `boot/` (staging), `.img` (raw image), `.vdi` (converted)
- Generated: Yes (cleaned up after successful build)
- Committed: No (git-ignored)

**/etc/ppsa/ (on appliance):**
- Purpose: Persistent configuration
- Contains: `firewall.json` (editable), `wireguard.json` (peer config), `iptables.rules` (saved rules), `network-policy.json` (SSH exposure flag)
- Generated: Yes (at first boot)
- Committed: No (instance-specific state)

**H:\dev\palimage/ (local builder output, Windows machine):**
- Purpose: Artifact storage (configured in builder.json)
- Contains: `.img.zst`, `.vdi.zst`, `latest` symlinks, `logs/`, `history.json`, `status.json`
- Generated: Yes (by PowerShell builder)
- Committed: No (CI artifacts)

**backups/ (appliance):**
- Purpose: Tarball backups of named volumes (Palworld data, configs)
- Contains: `.tar.gz` files created by docker-volume-backup cron
- Generated: Yes (daily at 3 AM, or manual "Backup Now" from WebUI)
- Committed: No (instance data)

---

*Structure analysis: 2026-07-16*
