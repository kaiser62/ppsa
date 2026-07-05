# Architecture

## Overview

PPSA ships three artifact types built from the same core script,
`scripts/build-live-usb.sh`:

| Artifact | What it is | Built by |
|----------|-----------|----------|
| `ppsa-usb-*.img.zst` | Raw disk image for USB/SSD (`dd`-able) | `.github/workflows/build-release.yml` |
| `ppsa-vbox-*.vdi.zst` | The same image converted to VirtualBox VDI | `.github/workflows/build-release.yml` |
| `ppsa-installer-*.iso.zst` | A Debian Live ISO that bundles a compact seed image and writes PPSA onto a spare drive/partition without touching the host OS | `.github/workflows/build-installer.yml` |

Both workflows call `build-live-usb.sh` — it is the single source of truth for
what ends up on disk. Boot behavior, partitioning, and the Docker stack are
all defined there and in `scripts/install.sh` (first boot), not in the CI glue.

## Boot chain (Secure Boot)

`build-live-usb.sh` installs Debian's signed shim + signed GRUB
(`shim-signed`, `grub-efi-amd64-signed`) onto the EFI System Partition using
the removable-media convention: `EFI/BOOT/BOOTX64.EFI` is the signed shim,
`EFI/BOOT/grubx64.efi` is the signed GRUB core.

The signed GRUB core's baked-in config prefix is `/EFI/debian` — that's
immutable (baking a different prefix in would invalidate Debian's signature).
Because of that, `EFI/debian/grub.cfg` holds the real boot menu (kernel/initrd
load commands) directly. It does **not** redirect to a separate
`/boot/grub/grub.cfg` via `search` + `set prefix` + `configfile` — that
indirection breaks GRUB's `shim_lock` kernel verification even with a fully
valid signature chain. `/boot/grub/grub.cfg` is still written separately for
on-device `grub-install` maintenance and BIOS boot, but Secure Boot doesn't
load it.

No MOK enrollment is needed: shim is signed by Microsoft's 3rd-party UEFI CA
(trusted by stock firmware), and Debian's kernel/GRUB packages chain to the
Debian Secure Boot CA embedded in shim's `vendor_cert`. If a signed shim/GRUB
isn't available in the build chroot, the script falls back to an unsigned
`grub-mkstandalone` image — Secure Boot must be disabled to boot that.

## First boot

`ppsa-firstboot.service` runs `scripts/install.sh` once, unattended, showing
live progress on the console (tty1):

1. Resize root partition to fill the disk
2. Start Docker
3. Configure environment (`.env`)
4. Deploy the Docker Compose stack
5. Start Wi-Fi onboarding (if no network is configured)
6. Auto-register as a WireGuard peer (if `/etc/ppsa/wireguard.json` is configured)
7. Configure the firewall (see below)
8. Mark installation complete

## Docker stack

`compose/docker-compose.yml` brings up five services:

| Service | Image | Purpose |
|---------|-------|---------|
| `palworld` | `thijsvanloef/palworld-server-docker` | The game server itself |
| `webui` | built from `docker/webui/` (this repo) | FastAPI app serving both `/api/*` and the static single-page dashboard |
| `wgdashboard` | `ghcr.io/wgdashboard/wgdashboard` | Peer management UI for the WireGuard tunnel |
| `backup` | `offen/docker-volume-backup` | Daily (cron'd) tarball of all named volumes |
| `watchtower` | `containrrr/watchtower` | Automatic image updates, opt-in per container via labels |

An optional `compose/docker-compose.monitoring.yml` overlay adds Prometheus +
Grafana; it is not started by default.

`docker/webui/app/` is the **only** live WebUI code. `webui/frontend/` (if
present in an older checkout) is an orphaned early copy not referenced by any
Dockerfile or compose file — don't confuse it with `docker/webui/app/static/index.html`.

## Networking & firewall

PPSA's default posture: **nothing except SSH and the WireGuard tunnel itself
is reachable from the LAN or the internet.** Everything else — the game
server, the Web UI, WGDashboard — is reachable only from clients connected to
PPSA's own WireGuard network.

This is implemented with two layers:

**1. UFW** (`scripts/install.sh`), default-deny inbound, explicitly allows:
- `51820/udp` — WireGuard tunnel (admin)
- `51830/udp` — WireGuard tunnel (PPSA gaming network)
- `192.168.50.0/24 → 8080/tcp` — a narrow exception for the Wi-Fi onboarding
  hotspot subnet, so a first-time user can reach the Web UI to configure
  Wi-Fi/WireGuard before any tunnel exists
- SSH (`22/tcp`, `10022/tcp`) — **opt-in only**, see below

**2. The `WG_FRIENDS` iptables chain** (`scripts/ppsa-firewall-apply.sh`),
inserted at the top of `INPUT`, matching only the `10.8.0.0/24` WireGuard
subnet. It allows the game port, the Web UI, WGDashboard, and (by default)
SSH for anyone on the WireGuard network. Its allowed-port list is editable at
runtime from the Web UI's Firewall tab, which writes `firewall.json` and
re-applies the chain.

### SSH exposure: WireGuard-only by default, LAN opt-in via build flag

SSH is reachable through the `WG_FRIENDS` chain by default (port `22` is in
`firewall.json`'s default allow-list), matching the "nothing on the open LAN"
posture. Whether SSH is **also** opened globally via UFW is controlled by a
build-time flag baked into `/etc/ppsa/network-policy.json`:

```json
{ "expose_ssh_lan": false }
```

Set `PPSA_EXPOSE_SSH_LAN=true` when building (or the `expose_ssh_lan` input on
the `build-release.yml` / `build-installer.yml` workflows) to also open
`22/tcp` and `10022/tcp` globally via UFW — useful for LAN-based recovery or
debugging on hardware you don't want to depend on a WireGuard tunnel to reach.
`scripts/install.sh`'s firewall step reads this file and conditionally adds
those two UFW rules; the flag has no effect on WireGuard reachability either
way.

## Build pipeline

Images are built by GitHub Actions, never locally — this keeps the build
environment reproducible and avoids "works on my machine" drift. Local
iteration without waiting on CI is available through a separate PowerShell
tool (see [docs/local-builder.md](local-builder.md)), which still calls the
exact same `build-live-usb.sh` inside WSL.

Release policy: only a `vX.Y.Z` tag push publishes a public GitHub Release.
`workflow_dispatch` runs (manual test/dev builds) upload their output as a
workflow artifact instead, so release history stays clean.
