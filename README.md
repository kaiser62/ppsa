# PPSA — Portable Palworld Server Appliance

A self-contained, bootable Palworld dedicated server that lives entirely on a
USB drive, SSD, VM disk, or spare partition. Plug it in, boot from it, and you
have a full Palworld server with a web management UI — no host OS install
required.

> **Latest: v1.2.8.** Debian 13 (Trixie), Secure Boot–signed GRUB, Docker
> Compose stack, WireGuard-based remote access, Wi-Fi onboarding hotspot.

---

## What you get

- **Plug-and-boot Wi-Fi setup** — on first boot, if no network is configured,
  PPSA serves a `PPSA-Setup` hotspot so you can pick a Wi-Fi network from the
  Web UI ([details](docs/wifi-onboarding.md))
- **Debian 13 (Trixie)**, booted directly from USB/SSD/VDI, or installed
  alongside an existing OS via the installer ISO ([details](docs/dual-boot-install.md))
- **Docker Compose stack**: Palworld game server, a FastAPI Web UI, WGDashboard
  (WireGuard peer management), an automated backup agent, and Watchtower
- **UEFI Secure Boot support** — signed shim + Debian-signed GRUB chain, no MOK
  enrollment needed (see [Architecture](docs/architecture.md))
- **First-boot automation** — installs and starts the whole stack unattended,
  auto-resizes the root partition to fill the disk
- **WireGuard-gated remote access** — game/Web UI/WGDashboard ports are reachable
  only over a WireGuard tunnel by default, not the open LAN/WAN (see
  [Networking & firewall](docs/architecture.md#networking--firewall))
- **Automatic backups** (daily, cron'd) and automatic container updates (opt-in)

---

## Quick start

### 1. Download a release

Grab the latest release from
[github.com/kaiser62/ppsa/releases](https://github.com/kaiser62/ppsa/releases):

| Asset | Use for |
|-------|---------|
| `ppsa-usb-vX.X.X.img.zst` | Physical USB / SSD (recommended) |
| `ppsa-vbox-vX.X.X.vdi.zst` | VirtualBox VM |
| `ppsa-installer-vX.X.X.iso.zst` | Installer ISO — installs PPSA onto a spare drive/partition without touching your existing OS ([guide](docs/dual-boot-install.md)) |
| `*.sha256` | Checksum for the matching asset |

### 2. Write to USB (physical hardware)

**Windows (Rufus):**
1. Decompress `ppsa-usb-vX.X.X.img.zst` with [7-Zip](https://www.7-zip.org/)
2. Open **Rufus** → select your USB drive → **SELECT** → choose the `.img` file
3. **START** → **DD image mode** (not ISO mode) → OK → OK
4. Wait for the write to finish, then eject safely

**Linux / macOS:**
```bash
zstd -d ppsa-usb-vX.X.X.img.zst
sudo dd if=ppsa-usb-vX.X.X.img of=/dev/sdX bs=4M status=progress conv=fsync
sync
```

### 3. Boot from the USB

1. Plug the USB into the target machine, power on, and enter the boot menu
   (F12 / F2 / DEL, depends on the BIOS)
2. Select the USB device — GRUB auto-boots into PPSA
3. Log in at the console with `ppsa` / `ppsa` (see
   [default credentials](#default-credentials--change-immediately))
4. First boot runs unattended in the background — the console shows live progress

### 4. Open the Web UI

First boot takes a few minutes (pulling Docker images and the Palworld Steam
update, ~4 GB). Once it's done, the console prints the Web UI URL. Open it
from a machine that can reach the PPSA host — by default that means the same
WireGuard network, **not** plain LAN (see
[Networking & firewall](docs/architecture.md#networking--firewall) for why,
and how to connect over WireGuard).

Default login: **`admin` / `admin`** — change this on the Settings tab immediately.

---

## Running in VirtualBox

```bash
zstd -d ppsa-vbox-vX.X.X.vdi.zst
```

1. **Machine → New** → Type **Linux**, Version **Debian (64-bit)**
2. Memory: 4 GB minimum (8 GB recommended), 2+ CPUs
3. **Use an existing virtual hard disk file** → select the extracted `.vdi`
4. **System → Enable EFI** (recommended — matches the Secure Boot chain used on
   real hardware; legacy BIOS also works)
5. Start the VM

First boot behaves identically to physical hardware.

---

## Networking model, in one paragraph

By default, nothing except SSH and the WireGuard tunnel itself is reachable
from your LAN or the internet. The game server, Web UI, and WGDashboard are
only reachable from clients connected to the PPSA's WireGuard network. This
means you can hand a WireGuard config to a friend and they can reach your
server from anywhere, without opening a single port on your router. Full
details, including the opt-in build flag to also expose SSH on the LAN, are in
[docs/architecture.md](docs/architecture.md#networking--firewall).

---

## Documentation

- [docs/architecture.md](docs/architecture.md) — boot chain, Docker stack, networking/firewall model
- [docs/installation.md](docs/installation.md) — all install paths (USB, VirtualBox, dual-boot installer, bare metal)
- [docs/deployment-guide.md](docs/deployment-guide.md) — end-to-end deployment walkthrough with reference detail
- [docs/dual-boot-install.md](docs/dual-boot-install.md) — installer ISO: install PPSA on a spare drive/partition
- [docs/wifi-onboarding.md](docs/wifi-onboarding.md) — the `PPSA-Setup` Wi-Fi hotspot
- [docs/wireguard-setup.md](docs/wireguard-setup.md) — WireGuard auto-registration, hosting your own hub, player onboarding
- [docs/troubleshooting.md](docs/troubleshooting.md) — common issues and fixes
- [docs/local-builder.md](docs/local-builder.md) — the PowerShell local CI/CD builder (fast local iteration without waiting on GitHub Actions)
- [CLAUDE.md](CLAUDE.md) — contributor/agent-facing build & architecture notes

---

## Default credentials — change immediately!

| User | Password | Where to change |
|------|----------|-----------------|
| `ppsa` (SSH) | `ppsa` | `passwd ppsa` (sudo) |
| `artho` (SSH, port `10022`) | `arthoroy` | `passwd artho` (sudo) |
| `admin` (Web UI) | `admin` | Web UI → Settings tab |
| Palworld admin (in-game) | `changeme` | Web UI → Config tab |

---

## Building from source

Images are built by GitHub Actions, not locally — see
[docs/architecture.md](docs/architecture.md#build-pipeline) for why and how the
pipeline is structured.

```bash
# Real release: push a version tag. build-release.yml and build-installer.yml
# both fire automatically and publish a GitHub Release with all three assets.
git tag v1.3.0 && git push origin v1.3.0

# Manual test build (does NOT publish a release, uploads a workflow artifact):
gh workflow run build-release.yml -f version=v1.3.0-test
gh workflow run build-installer.yml -f version=v1.3.0-test
```

---

## Repository layout

```
.
├── scripts/
│   ├── build-live-usb.sh          # Image builder (debootstrap + chroot + GRUB)
│   ├── install.sh                 # First-boot: docker pull + up, firewall, WireGuard
│   ├── ppsa-firewall-apply.sh     # Rebuilds the WG_FRIENDS iptables chain
│   ├── ppsa-wireguard-register.sh # Auto-registers as a wg-easy peer
│   └── ppsa-wifi-onboard.sh       # PPSA-Setup hotspot for first-time Wi-Fi setup
├── compose/
│   ├── docker-compose.yml             # Main stack (palworld, webui, wgdashboard, backup, watchtower)
│   └── docker-compose.monitoring.yml  # Optional Prometheus + Grafana overlay
├── docker/webui/                  # The only live WebUI code (FastAPI + vanilla JS)
├── installer/                     # live-build config for the dual-boot installer ISO
├── modules/                       # PowerShell modules for the local CI/CD builder
├── docs/                          # Documentation (see above)
└── .github/workflows/
    ├── build-release.yml          # CI: build USB img + VBox VDI, release on tag push
    └── build-installer.yml        # CI: build installer ISO, attaches to the same release
```

---

## Versioning & releases

Semantic version tags (`vX.Y.Z`) are the only thing that publishes a public
release. Each release includes the raw USB image, the VirtualBox disk, and the
installer ISO. See the [Releases page](https://github.com/kaiser62/ppsa/releases)
for the full history and changelogs.

---

## Security

- **Change all default passwords** before exposing PPSA to any network
- By default, only SSH and the WireGuard tunnel ports are open on the LAN/WAN —
  the game server, Web UI, and WGDashboard are WireGuard-only (see
  [Networking & firewall](docs/architecture.md#networking--firewall))
- Web UI uses JWT tokens (24h expiry)
- `.env` (secrets) is git-ignored and never baked into the image

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
- **wg-easy**: [`wg-easy/wg-easy`](https://github.com/wg-easy/wg-easy)
- **Base OS**: [Debian 13 (Trixie)](https://www.debian.org/releases/trixie/)
