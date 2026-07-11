# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo builds

PPSA (Portable Palworld Server Appliance) — a bootable Debian 13 (Trixie) disk
image that runs a Palworld dedicated server + management stack via Docker
Compose. Ships three artifact types from the same `build-live-usb.sh` core:
a raw USB/SSD image, a VirtualBox VDI, and a live-boot installer ISO (writes
PPSA onto a spare drive/partition without touching the host OS).

## Branch strategy (two parallel fronts)

- **`master`** — WireGuard mainline, ships `v1.2.x` tags. All shared-code work
  (WebUI, firewall, build script, installer) lands HERE first.
- **`netbird`** — NetBird networking test line, ships `v1.3.0-nb.N` prerelease
  tags (a hyphen in the tag auto-marks the GitHub release as prerelease).
  Sync direction is one-way: `git merge master` into `netbird` — never the
  reverse until the NetBird line is promoted to mainline.
- Tag `v1.3.0-nb.N` only from the `netbird` branch. Installer ISO for the
  branch: `gh workflow run build-installer.yml --ref netbird -f version=v1.3.0-nb.N`.
- NetBird CI secrets are additive (`PPSA_NB_SETUP_KEY`,
  `PPSA_NB_MANAGEMENT_URL`); the WG secrets stay untouched so master builds
  keep working.

## Commands

### Build policy: GitHub Actions only, never local

Never run `scripts/build-live-usb.sh` locally to produce an image for testing
or release — always trigger the GitHub Actions workflow instead (push a tag,
or `gh workflow run`). `Dockerfile.build`/`build-usb.bat` exist in the repo as
a WSL-free local path but are not the sanctioned way to produce a build; don't
reach for them by default.

Local verification of a built image happens only in **VirtualBox**, via the
already-installed VirtualBox MCP — boot the CI-produced VDI there rather than
building or booting anything locally yourself.

### Build the installer ISO
```bash
# live-build based; only wired up as a GitHub Actions workflow_dispatch, not a local one-liner
gh workflow run build-installer.yml -f version=vX.Y.Z
```
Bundles a compact seed image (`build-live-usb.sh` output) into a Debian Live ISO
under `installer/`. The chroot script that does the actual disk-write on target
hardware is `installer/config/includes.chroot/usr/local/bin/ppsa-install`.

### Trigger a release build
```bash
git tag vX.Y.Z && git push origin vX.Y.Z    # build-release.yml: builds usb+vbox, publishes release
```
A plain push to `master` (no tag) still runs the build job for validation but
does **not** publish a release — only a tag push or manual `workflow_dispatch`
does (see the `if: github.ref_type == 'tag' || github.event_name == 'workflow_dispatch'`
gate in `build-release.yml`). The installer ISO workflow is separate and always
manual (`gh workflow run build-installer.yml -f version=...`) — tagging alone
does not build it.

### Local WebUI dev loop
```bash
cd docker/webui/app
pip install -r requirements.txt
uvicorn main:app --reload --port 8080
```
No test suite exists for the WebUI backend; verify changes by hitting the
FastAPI routes directly or through the static frontend.

### PowerShell local-builder tests
```bash
pwsh tests/test-<module>.ps1     # e.g. tests/test-logger.ps1 — each file is self-contained, no shared runner
```
These test the `modules/*.psm1` PowerShell modules (the *local* CI/CD builder
described below), not the appliance itself.

## Architecture

### Two build pipelines, one shared core

1. **GitHub Actions** (`.github/workflows/build-release.yml`,
   `build-installer.yml`) — the canonical CI path. Runs `build-live-usb.sh`
   on `ubuntu-latest` runners.
2. **Local WSL builder** (`modules/*.psm1` + `scripts/Start-PpsaBuilder.ps1`,
   config in `builder.json`, design doc `MASTER_PLAN.md`) — a PowerShell
   system that polls a GitHub issue for tester reports, triggers the same
   `build-live-usb.sh` inside WSL, converts the result to VDI, and drives a
   VirtualBox smoke test. Exists for fast local iteration without waiting on
   CI. Output lands in `H:\dev\palimage` (path is a `builder.json` setting,
   not portable — this is a specific dev machine's convention).

Both pipelines call the exact same `scripts/build-live-usb.sh` — that script
is the single source of truth for what ends up on disk. Changes to boot
behavior, partitioning, or the Docker stack belong there, not in the
CI/installer glue.

### Boot chain (Secure Boot matters here)

`build-live-usb.sh` installs Debian's signed shim + signed GRUB
(`shim-signed`, `grub-efi-amd64-signed`) onto the ESP using the
removable-media convention (`EFI/BOOT/BOOTX64.EFI` = shim, `EFI/BOOT/grubx64.efi`
= signed GRUB core). `fbx64.efi` is deliberately omitted — its presence makes
shim write NVRAM boot entries from BOOT.CSV, which is wrong for portable/
removable media and can reboot-loop.

The signed GRUB core's baked-in prefix is `/EFI/debian` (immutable — baking a
different prefix in would invalidate Debian's signature). Because of that,
`EFI/debian/grub.cfg` is where the *real* boot menu (kernel/initrd load
commands) must live directly — do not reintroduce a `search`+`set prefix`+
`configfile` redirect out to a separate `/boot/grub/grub.cfg` as the Secure
Boot entry point; that indirection broke GRUB's `shim_lock` kernel
verification (`bad shim signature`) even with a fully valid signature chain.
`/boot/grub/grub.cfg` is still written separately for on-device `grub-install`
maintenance and BIOS boot, but it is not what Secure Boot actually loads.
If a signed shim/grub isn't found in the chroot, the script falls back to an
unsigned `grub-mkstandalone` image (Secure Boot must be off to boot that).

There is no MOK enrollment step and none is needed: shim is signed by
Microsoft's 3rd-party UEFI CA (trusted by stock firmware), and Debian's
kernel/GRUB packages chain to the `Debian Secure Boot CA` embedded in shim's
`vendor_cert` section.

### Runtime stack (what first-boot actually starts)

`scripts/install.sh` runs on first boot (via `ppsa-firstboot.service`) and
brings up `compose/docker-compose.yml`: `palworld` (game server, community
image `thijsvanloef/palworld-server-docker`), `webui` (FastAPI, this repo's
own code), `wgdashboard`, `backup` (`offen/docker-volume-backup`, cron'd),
`watchtower`. It also configures UFW.

**Only `docker/webui/app/` is live code for the WebUI** — `webui/frontend/`
is an orphaned early copy (last touched at the initial commit, not referenced
by any Dockerfile/compose file); don't edit it, don't confuse it with
`docker/webui/app/static/index.html`. The WebUI is a single FastAPI app
(`docker/webui/app/main.py`) serving both the `/api/*` JSON routes and the
static frontend — no separate frontend build step, no framework, plain JS.

**Port exposure is intentionally asymmetric.** SSH (`22`, `10022`) and the two
WireGuard tunnel ports (`51820` admin, `51830` PPSA-gaming) are opened
globally via `ufw` in `install.sh`. Game/WebUI/WGDashboard ports
(`8211/udp`, `27015/udp`, `8212/tcp`, `8080/tcp`, `10086/tcp`) are **not**
opened globally — they're reachable only through the `WG_FRIENDS` iptables
chain (`scripts/ppsa-firewall-apply.sh`), which is inserted at the top of
`INPUT` and only matches the `10.8.0.0/24` WireGuard-friends subnet. A narrow
exception exists for the onboarding hotspot subnet (`192.168.50.0/24`) on
port 8080, so a first-time user can reach the WebUI to configure WireGuard
before any tunnel exists. The `WG_FRIENDS` chain's allowed-port list is
itself editable at runtime from the WebUI's Firewall tab (writes
`firewall.json`, re-applied by `ppsa-firewall-apply.sh`).

Wi-Fi onboarding (`scripts/ppsa-wifi-onboard.sh` + `.service`) starts a
`PPSA-Setup` hostapd/dnsmasq hotspot when no Wi-Fi is configured, so a user
can reach the WebUI over Wi-Fi to pick a real network. The WebUI's Wi-Fi
endpoints in `main.py` don't talk to hostapd/nmcli directly from inside the
container — they shell out to the host via `_host_exec()` (`nsenter`/`chroot`
into `/host`, which is bind-mounted read-only into the webui container).

An optional `compose/docker-compose.monitoring.yml` overlay adds a
Prometheus + Grafana stack; not started by default `install.sh`.

## Repo layout

- `scripts/` — `build-live-usb.sh` (image builder), `install.sh` (first-boot),
  `ppsa-firewall-apply.sh`, `ppsa-wifi-onboard.sh`, `ppsa-wireguard-register.sh`
- `compose/` — `docker-compose.yml` (main stack), monitoring overlay
- `docker/webui/app/` — the only live WebUI code (see above)
- `modules/` + `scripts/Start-PpsaBuilder.ps1` + `builder.json` — local WSL builder
- `installer/` — live-build config for the installer ISO
- `docs/` — `installation.md`, `wifi-onboarding.md`, `wireguard-setup.md`,
  `architecture.md`, `troubleshooting.md`, `deployment-guide.md`,
  `dual-boot-install.md`, `local-builder.md`
