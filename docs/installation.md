# Installation

PPSA supports three install paths. Pick the one that matches your hardware.

## 1. USB / SSD (recommended for dedicated hardware)

Write the raw disk image to a USB drive or SSD and boot from it directly —
nothing touches any other disk in the machine.

See the [README quick start](../README.md#quick-start) for the short version,
or [docs/deployment-guide.md](deployment-guide.md) for the full walkthrough
including WireGuard setup and player onboarding.

## 2. VirtualBox

Convert-free: download the `.vdi` asset directly and attach it to a new VM.
See the [README](../README.md#running-in-virtualbox) for the exact VM settings.

## 3. Dual-boot installer (install onto a spare drive/partition)

If you don't want to dedicate a whole drive, or want to install PPSA on a
machine that already runs something else, use the installer ISO — a live
Debian environment that writes PPSA onto a drive or partition you choose,
without touching the rest of the disk.

See [docs/dual-boot-install.md](dual-boot-install.md) for the full guide,
including UEFI/BIOS partition layout, Secure Boot considerations, and how to
recover if the wrong disk gets selected.

## After install, either way

1. Boot the machine — first boot runs unattended (a few minutes, pulling
   Docker images and the Palworld Steam update).
2. If no network is configured, connect to the `PPSA-Setup` Wi-Fi hotspot to
   pick a network from the Web UI — see [docs/wifi-onboarding.md](wifi-onboarding.md).
3. Open the Web UI and change the default `admin` / `admin` password immediately.
4. Set up WireGuard so you (and friends) can reach the server remotely — see
   [docs/wireguard-setup.md](wireguard-setup.md).

If something doesn't come up as expected, check
[docs/troubleshooting.md](troubleshooting.md) before opening an issue.
