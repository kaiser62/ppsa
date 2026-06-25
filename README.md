# Portable Palworld Server Appliance (PPSA)

A portable Palworld server that **lives entirely on a USB SSD**. Boot any x86-64 PC
from the USB and run a full Palworld server with web management — no installation
to internal disk required.

## Quick Start

1. **Build the image** — Run `build-usb.bat` on Windows (requires WSL)
2. **Write to USB** — Use Rufus in DD mode
3. **Boot from USB** — Enter BIOS boot menu, select the USB SSD
4. **Configure** — Complete first-boot setup via the web UI at `http://<ip>:8080`

## How It Works

```
build-usb.bat (Windows)
  │  └─ WSL runs scripts/build-live-usb.sh
  │     └─ Creates a bootable Debian disk image (.img)
  │        with Docker + PPSA stack pre-installed
  ▼
ppsa-usb.img ──> Write to USB SSD (Rufus DD mode)
  ▼
Boot from USB ──> Debian boots directly from the USB
  │
  └─ First boot ──> Docker stack deploys automatically
      │
      └─ Web UI ready ──> First-boot wizard ──> Start managing!
```

## Architecture

```
USB SSD
  └─ Debian 13 (Trixie) — bootable, persistent
       └─ Docker Engine
            └─ Docker Compose
                 ├── Palworld Server (thijsvanloef/palworld-server-docker)
                 ├── Web UI (FastAPI + vanilla JS)
                 ├── WGDashboard (WireGuard management)
                 ├── Backup Agent (offen/docker-volume-backup)
                 ├── Watchtower (auto-updates)
                 └── [Optional] Prometheus + Grafana
       └─ WireGuard tunnel ──> Oracle Cloud VPS ──> Internet
```

## Requirements

| Resource | Minimum | Recommended |
|----------|---------|-------------|
| USB SSD | 64GB | 128GB+ |
| PC | Any x86-64 | 4+ cores, 16GB RAM |
| Build machine | Windows 10/11 with WSL | Any Linux |
| Internet | Required for build + first boot | Always-on for updates |

## Repository Layout

```
├── build-usb.bat              # Windows: builds the USB image (WSL)
├── scripts/
│   ├── build-live-usb.sh       # Linux: creates bootable Debian .img
│   ├── install.sh              # First-boot: deploys Docker stack
│   └── first-boot.sh           # Configuration wizard
├── compose/
│   ├── docker-compose.yml           # Main stack
│   └── docker-compose.monitoring.yml # Optional monitoring
├── docker/webui/                    # Web UI container (FastAPI)
├── webui/frontend/                  # Single-page JS dashboard
├── oracle/
│   ├── cloud-init.yml               # Oracle VPS cloud-init
│   └── vps-setup.sh                 # One-command VPS setup
├── configs/                         # Environment templates
├── backups/                         # Backup agent config
├── monitoring/                      # Prometheus + Grafana configs
├── wireguard/                       # WGDashboard notes
└── docs/                            # Full documentation
```

## Components

| Service | Port | Description |
|---------|------|-------------|
| Palworld Server | 8211/udp | Game server |
| Web UI | 8080/tcp | Management dashboard |
| WGDashboard | 10086/tcp | WireGuard peer management |
| Palworld REST API | 8212/tcp | Server management API |
| SSH | 22/tcp | Remote access |

## Documentation

See [docs/](docs/) for:
- [Build & Installation](docs/installation.md)
- [Architecture Overview](docs/architecture.md)
- [Oracle VPS Setup](docs/oracle-setup.md)
- [WireGuard Setup](docs/wireguard-setup.md)
- [Backup & Restore](docs/backup-restore.md)
- [Troubleshooting](docs/troubleshooting.md)

## License

MIT
