# Technology Stack

**Analysis Date:** 2026-07-16

## Languages

**Primary:**
- **Bash** - Build scripts, system configuration, service management
- **Python** 3.12 - Web UI backend (FastAPI)
- **JavaScript** - Static frontend (plain JS, no framework)

**Secondary:**
- **YAML** - Docker Compose, GitHub Actions workflows

## Runtime

**Environment:**
- **Debian 13 (Trixie)** - Target operating system for the appliance
- **Docker** - Container runtime for application stack
- **Linux kernel** - UEFI/Secure Boot compatible

**Package Manager:**
- **pip** - Python dependency management (in Web UI container)
- **apt** - Debian package management (image build)
- **Docker Compose** - Multi-container orchestration

## Frameworks

**Core:**
- **FastAPI** 0.115.x - REST API framework for Web UI backend
- **Uvicorn** 0.32.x - ASGI server for FastAPI
- **Docker Compose** - Orchestrates multi-service stack

**Testing:**
- **PowerShell** test modules (`tests/test-*.ps1`) - Local builder validation

**Build/Dev:**
- **debootstrap** - Creates base Debian filesystem
- **live-build** - Installer ISO generation
- **GitHub Actions** - CI/CD pipeline (`.github/workflows/`)

## Key Dependencies

**Critical:**
- **thijsvanloef/palworld-server-docker:latest** - Official Palworld dedicated server image (community-maintained)
  - Provides RCON/REST API endpoints for server control
- **offen/docker-volume-backup:v2** - Automated backup with cron + Discord notifications
  - Stops palworld container during backup for consistency
  - Excludes Steam transient downloads directory
- **containrrr/watchtower:latest** - Automatic container image updates
  - Scheduled daily at 4 AM UTC
  - Only updates containers with `ppsa.component` label

**Networking:**
- **NetBird** - Primary VPN/mesh network overlay (`netbird` branch default)
  - Client binary baked into image
  - Configuration: `netbird.json` at `/etc/ppsa/netbird.json`
- **WireGuard** (deprecated, optional) - Legacy VPN tunnel (disabled by default unless `PPSA_WG_ENABLED=true`)
  - Dashboard: `ghcr.io/wgdashboard/wgdashboard:latest`
  - Fallback config support for re-enable

**Monitoring (optional overlay):**
- **Prometheus:latest** - Metrics collection and storage (14-day retention)
- **Grafana:latest** - Visualization and dashboards
- **prom/node-exporter:latest** - System metrics export

## Configuration

**Environment:**
- **Variables driven by Docker Compose `.env` file:** `SERVER_NAME`, `ADMIN_PASSWORD`, `MAX_PLAYERS`, `BACKUP_SCHEDULE`, `BACKUP_RETENTION_DAYS`, `DISCORD_WEBHOOK_URL`, `PALWORLD_API_URL`, `PALWORLD_ADMIN_PASSWORD`, `TZ`, `PPSA_CPUS`, `PPSA_MEMORY`
- **Web UI dynamic config:** `/opt/ppsa/.env` (read/write via `/api/env` endpoints)
- **First-boot configuration:** `scripts/install.sh` runs on first boot via `ppsa-firstboot.service`

**Build Configuration:**
- **Dockerfile** - Web UI container image definition (`docker/webui/Dockerfile`)
- **docker-compose.yml** - Main stack (`compose/docker-compose.yml`)
- **docker-compose.monitoring.yml** - Optional monitoring overlay
- **Dockerfile.build** - WSL local builder image (non-canonical, for reference only)

**GitHub Actions secrets/variables:**
- `PPSA_WG_ENABLED` - Controls WireGuard enablement (default `false`)
- `PPSA_NB_SETUP_KEY`, `PPSA_NB_MANAGEMENT_URL` - NetBird unattended enrollment
- `PPSA_WG_API_URL`, `PPSA_WG_API_USER`, `PPSA_WG_API_PASS` - WireGuard registration (deprecated)
- `PPSA_EXPOSE_SSH_LAN` - Opt-in SSH exposure over LAN (default false = WireGuard-only)

## Platform Requirements

**Development:**
- **Linux** (Ubuntu 20.04+) or **Windows 11 with WSL2** for image building
- **Docker** and **Docker Compose** v2+ on builder machine
- **Git** for version control
- **zstd** compression utility (for GitHub release artifacts)

**Production (Appliance):**
- **x86-64 CPU** with UEFI firmware (Secure Boot optional but supported)
- **USB SSD or physical disk** (8GB+ bare minimum; 12GB recommended)
- **Network connectivity** for first-boot setup and NetBird enrollment
- **8GB+ disk space** after Debian + Docker overhead, before Palworld server data

**Build Pipeline:**
- **GitHub Actions** (ubuntu-latest runners) - canonical build path
- **Local WSL builder** (Windows + PowerShell modules) - optional fast iteration

## Build & Distribution

**Output Artifacts:**
- **ppsa-usb-vX.Y.Z.img.zst** - zstd-compressed 8GB disk image (USB/SSD boot)
- **ppsa-vbox-vX.Y.Z.vdi.zst** - 4GB VirtualBox VDI image (test/dev)
- **ppsa-installer-vX.Y.Z.iso** - Debian Live ISO with embedded installer script

**Compression:**
- **zstd -10** for release artifacts (~10x faster than xz, similar ratio)
- **zstd -3** for CI caching (build-live-usb.sh rootfs cache)

**Versioning:**
- **v1.3.0-nb.N** pattern (netbird branch, prerelease)
- **v1.2.x** pattern (master branch, frozen/archived)
- Hyphen in tag auto-marks GitHub release as prerelease

---

*Stack analysis: 2026-07-16*
