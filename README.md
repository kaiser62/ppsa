# PPSA — Portable Palworld Server Appliance

A self-contained, bootable Palworld dedicated server that lives entirely on a
USB drive (or any x86_64 VM/bare-metal). Plug it in, boot from it, and you
have a full Palworld server with a web management UI — no installation on the
host disk, no operating system required on the host.

> **Status: Production-ready (v1.0.0).** Booted and verified on USB, VirtualBox,
> and QEMU/OVMF. All five containers start cleanly on first boot.

---

## What you get

- **Debian 13 (Trixie)** with kernel 6.12 LTS, booted directly from a USB/SSD/VDI
- **Docker Engine + Docker Compose v2** with the full PPSA stack:
  - **Palworld server** (`thijsvanloef/palworld-server-docker`) — Steam auto-update
  - **Web UI** (FastAPI + vanilla JS) — single-page dashboard
  - **WireGuard Dashboard** — full peer management UI
  - **Backup agent** (`offen/docker-volume-backup`) — daily tar.gz of all volumes
  - **Watchtower** — automatic container updates (opt-in via labels)
  - Optional **Prometheus + Grafana** stack for monitoring
- **First-boot automation** — `ppsa-install.service` runs the install on first boot
- **Auto-resize** — root partition grows to fill the disk on first boot (USB only)
- **UFW firewall** with fail2ban — only SSH and WebUI ports open
- **WireGuard tunnel** to your own Oracle Cloud VPS for external access (optional)
- **8 CPU / 8 GB RAM recommended** for the host (4 GB / 4 CPU minimum)
- **Works on BIOS or UEFI** systems (GRUB dual-install)

---

## Quick start

### 1. Download a release

Grab the latest **production** release from
[github.com/kaiser62/ppsa/releases](https://github.com/kaiser62/ppsa/releases):

| Asset | Use for |
|-------|---------|
| `ppsa-usb-vX.X.X.img.zst` | **Physical USB / SSD** (recommended) |
| `ppsa-vbox-vX.X.X.vdi.zst` | **VirtualBox** VM |
| `ppsa-vbox-vX.X.X.vdi.zst.sha256` | SHA256 check |
| `ppsa-usb-vX.X.X.img.zst.sha256` | SHA256 check |

### 2. Write to USB (physical hardware)

**Windows (Rufus):**
1. Download `ppsa-usb-vX.X.X.img.zst`
2. Decompress with [7-Zip](https://www.7-zip.org/): right-click → *7-Zip → Extract Here*
3. Open **Rufus** → select your USB drive → click **SELECT** → choose `ppsa-usb-vX.X.X.img`
4. Click **START** → choose **DD image mode** (not ISO mode!) → OK → OK
5. Wait for write to complete (3-10 min on USB 3.0)
6. Eject the USB safely

**Linux / macOS:**
```bash
zstd -d ppsa-usb-vX.X.X.img.zst
sudo dd if=ppsa-usb-vX.X.X.img of=/dev/sdX bs=4M status=progress conv=fsync
sync
```

### 3. Boot from the USB

1. Plug the USB into your target machine
2. Power on and press the boot menu key (F12 / F2 / DEL — depends on BIOS)
3. Select the USB device
4. GRUB menu appears → auto-boots into PPSA Linux
5. Log in at the console with `ppsa` / `ppsa` (or `artho` / `arthoroy` on the backup SSH port)
6. The first-boot `ppsa-install.service` runs in the background

### 4. Open the Web UI

After ~3-10 minutes (the first boot pulls Docker images and the Palworld Steam
update ~3.8 GB), open a browser on any machine on the same network:

```
http://<ppsa-ip>:8080
```

Default login: **`admin` / `admin`** — change this on the Settings tab immediately.

Find the PPSA IP from the console login banner, or:
```bash
# from any SSH client
ssh ppsa@<ppsa-ip> ip -4 addr show | grep inet
```

---

## Running in VirtualBox (alternative)

```bash
# Decompress
zstd -d ppsa-vbox-vX.X.X.vdi.zst
```

In VirtualBox:
1. **Machine → New** → Name: `ppsa`
2. Type: **Linux**, Version: **Debian (64-bit)**
3. Memory: **8192 MB** minimum, **CPU: 4** cores
4. **Use an existing virtual hard disk file** → select `ppsa-vbox-vX.X.X.vdi`
5. **Settings → Network → Adapter 1**: Attach to **Bridged Adapter** (so the VM gets a real LAN IP)
6. **Settings → System → Enable EFI** (recommended; legacy BIOS also works)
7. **Start** the VM

First boot is identical: ~3-10 min for the install, then `http://<bridged-ip>:8080`.

---

## Architecture

```
┌────────────────────────────────────────────────────────────────┐
│  USB / SSD / VDI  (8 GB, grows to fill device)                │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │  Debian 13 (Trixie) + kernel 6.12                       │  │
│  │  ┌──────────────────────────────────────────────────┐    │  │
│  │  │  Docker Engine                                   │    │  │
│  │  │  ┌─────────────┐ ┌──────────┐ ┌──────────────┐  │    │  │
│  │  │  │ ppsa-palworld│ │ ppsa-webui│ │ ppsa-wgdashbd│  │    │  │
│  │  │  │  (8211/udp)  │ │ (8080/tcp)│ │ (10086/tcp)  │  │    │  │
│  │  │  └─────────────┘ └──────────┘ └──────────────┘  │    │  │
│  │  │  ┌─────────────┐ ┌──────────┐                    │    │  │
│  │  │  │ ppsa-backup  │ │ppsa-watch│                    │    │  │
│  │  │  │  (cron 3am)  │ │  tower   │                    │    │  │
│  │  │  └─────────────┘ └──────────┘                    │    │  │
│  │  └──────────────────────────────────────────────────┘    │  │
│  │  ┌──────────────────────────────────────────────────┐    │  │
│  │  │ WireGuard tunnel (optional) → Oracle Cloud VPS  │    │  │
│  │  └──────────────────────────────────────────────────┘    │  │
│  └──────────────────────────────────────────────────────────┘  │
└────────────────────────────────────────────────────────────────┘
```

---

## Services & Ports

| Service | Port | URL | Default creds |
|---------|------|-----|---------------|
| Palworld game server | `8211/udp` | n/a (game client) | `ppsa:ppsa` if set in `.env` |
| Palworld REST API | `8212/tcp` | n/a (internal) | `admin` if set in `.env` |
| Web UI | `8080/tcp` | `http://<ip>:8080` | `admin:admin` ⚠️ change! |
| WireGuard Dashboard | `10086/tcp` | `http://<ip>:10086` | (set in WebUI tunnel setup) |
| SSH (ppsa) | `22/tcp` | `ssh ppsa@<ip>` | `ppsa` |
| SSH (artho) | `10022/tcp` | `ssh artho@<ip> -p 10022` | `artho` / `arthoroy` |

> **All ports are bound to `0.0.0.0` by default.** UFW firewall is active with
> a default-deny inbound policy. Only ports explicitly listed above are open.

---

## Default credentials — **change immediately!**

| User | Password | Where to change |
|------|----------|-----------------|
| `ppsa` (SSH) | `ppsa` | `passwd ppsa` (sudo) |
| `artho` (SSH) | `arthoroy` | `passwd artho` (sudo) |
| `admin` (WebUI) | `admin` | WebUI → Settings tab |
| Palworld admin (in-game) | `changeme` | WebUI → Config tab |

---

## Building from source

The PPSA image is built on Linux (or WSL on Windows) by `scripts/build-live-usb.sh`.
GitHub Actions builds and releases automatically when you push a tag.

```bash
# Local build
sudo bash scripts/build-live-usb.sh --output ppsa-usb.img

# Trigger CI build
git tag v1.0.0 && git push origin v1.0.0
```

The build script:
1. debootstrap Debian Trixie (or uses cached rootfs via `PPSA_CACHE_FILE`)
2. Installs Docker, kernel, GRUB, all PPSA files
3. Creates a GPT disk image with ESP (FAT32) + root (ext4) partitions
4. Installs GRUB for both UEFI (x86_64-efi) and legacy BIOS (i386-pc)
5. Writes a generated `grub.cfg` referencing the root partition by UUID

Build time: ~5-7 minutes from a clean cache, ~3 minutes with cached rootfs.

---

## Repository layout

```
.
├── scripts/
│   ├── build-live-usb.sh      # Image builder (debootstrap + chroot + GRUB)
│   ├── install.sh             # First-boot: docker pull + up, UFW, fail2ban
│   ├── first-boot.sh          # Boot banner with status + IP
│   └── oracle/                # Oracle VPS setup scripts
├── compose/
│   ├── docker-compose.yml           # Main stack (5 services)
│   └── docker-compose.monitoring.yml # Optional Prometheus + Grafana
├── docker/
│   └── webui/                       # FastAPI WebUI container
│       ├── Dockerfile
│       └── app/
│           ├── main.py              # API endpoints
│           ├── requirements.txt
│           └── static/index.html    # Single-page dashboard
├── modules/                         # PowerShell modules for the local CI/CD builder
├── docs/                            # Detailed documentation
├── MASTER_PLAN.md                   # Local builder design doc
├── builder.json                     # Local builder config
└── .github/workflows/
    └── build-release.yml            # CI: build USB + VDI, upload to release
```

---

## Documentation

- [docs/installation.md](docs/installation.md) — Detailed install steps
- [docs/oracle-setup.md](docs/oracle-setup.md) — Oracle Cloud VPS setup for WireGuard
- [docs/wireguard-setup.md](docs/wireguard-setup.md) — Tunnel configuration
- [docs/architecture.md](docs/architecture.md) — System design
- [docs/troubleshooting.md](docs/troubleshooting.md) — Common issues
- [docs/configuration.md](docs/configuration.md) — All config options
- [docs/builder.md](docs/builder.md) — Local CI/CD builder reference

---

## Versioning & releases

- **v1.0.0** (current) — Production-ready. GRUB bootloader, fixed WebUI, all
  bugs from v0.4.x resolved. Tagged `production`.
- **v0.4.x** — WebUI fixed, GRUB boot, image verification
- **v0.3.x** — Initial end-to-end stack

Each release is built by GitHub Actions and includes both the raw USB image
(`.img.zst`) and the VirtualBox disk (`.vdi.zst`). See the
[Releases](https://github.com/kaiser62/ppsa/releases) page.

---

## Security

- **Change all default passwords** before exposing to the network
- UFW firewall is on by default (deny inbound except listed ports)
- fail2ban watches SSH and the WebUI login
- WebUI uses JWT tokens (24h expiry) over HTTP Basic auth
- The SSH host key is generated on first boot
- All Docker containers run as non-root where possible
- `.env` file with secrets is git-ignored

Report security issues via GitHub Issues (mark as `security`).

---

## License

MIT — see [LICENSE](LICENSE).

---

## Credits

- **Palworld server**: [`thijsvanloef/palworld-server-docker`](https://github.com/thijsvanloef/palworld-server-docker)
- **WGDashboard**: [`wgdashboard/wgdashboard`](https://github.com/donaldzou/wgdashboard)
- **Backup agent**: [`offen/docker-volume-backup`](https://github.com/offen/docker-volume-backup)
- **Watchtower**: [`containrrr/watchtower`](https://github.com/containrrr/watchtower)
- **GRUB bootloader**: [GNU GRUB](https://www.gnu.org/software/grub/)
- **Base OS**: [Debian 13 (Trixie)](https://www.debian.org/releases/trixie/)
