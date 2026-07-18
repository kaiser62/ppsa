# PPSA — Portable Palworld Server Appliance

## Current Milestone: v1.4.0 WebUI Professional Overhaul

**Goal:** Redesign the plain-JS WebUI to look professional and fix the dashboard
bugs, keeping the FastAPI + no-build architecture and NetBird-only ports.

**Target features:**
- Professional frontend redesign — plain JS/CSS/HTML, no framework, no build step
- Fix game version rendering blank (parse container log, not just REST API)
- Fix empty dashboard states on fresh boot (server-starting affordance)
- Harden weak error handling across dashboard endpoints

## What This Is

PPSA is a bootable Debian 13 (Trixie) disk image that runs a Palworld dedicated
server plus a management stack (WebUI, backup, dashboards) via Docker Compose.
It ships as three artifacts from one shared build core (`scripts/build-live-usb.sh`):
a raw USB/SSD image, a VirtualBox VDI, and a live-boot installer ISO that writes
PPSA onto a spare drive without touching the host OS. Friends reach the server
over a private NetBird overlay network — it is meant for non-technical users who
just want to boot a stick and host Palworld for friends.

## Core Value

A user can boot the appliance, and their friends can reach a working Palworld
server over the private overlay network — every build must preserve that
end-to-end path.

## Requirements

### Validated

<!-- Shipped and confirmed valuable — current baseline as of GSD onboarding. -->

- ✓ Single-core image build producing raw USB image, VBox VDI, and installer ISO — existing
- ✓ Secure Boot chain (signed shim + signed GRUB, `/EFI/debian` prefix, removable-media layout) — existing
- ✓ Live-boot installer ISO that writes the seed image to a target disk and grows the partition — existing
- ✓ First-boot bring-up of the Docker stack (palworld, webui, wgdashboard, backup, watchtower) — existing
- ✓ NetBird overlay as the primary networking path (self-hosted control plane, `100.64.0.0/10`) — existing
- ✓ WireGuard retained but deprecated/dormant, re-enabled via `PPSA_WG_ENABLED=true` — existing
- ✓ WebUI (FastAPI): server actions, firewall tab, backup tab, Wi-Fi onboarding — existing
- ✓ Firewall model: game/WebUI ports gated through `WG_FRIENDS` chain (NetBird + legacy WG subnets) — existing
- ✓ Consistent backups: offen stops palworld for a clean snapshot; non-blocking WebUI trigger — existing (v1.3.0-nb.12)
- ✓ Wi-Fi onboarding hotspot (`PPSA-Setup`) so a first-time user can reach the WebUI — existing
- ✓ CI build pipeline on GitHub Actions (`build-release.yml`, `build-installer.yml`) — existing
- ✓ Token-efficient installer verification over NetBird SSH (text-first) — v1.3.0 Phase 01
- ✓ Repeatable one-shot smoke test returning pass/fail summary (`scripts/ppsa-smoke-test.py`) — v1.3.0 Phase 02
- ✓ WebUI save-file backup/restore/restore-upload endpoints + UI — v1.3.0 Phase 03

### Active

<!-- Building toward these — milestone v1.4.0. -->

- [ ] WebUI looks professional and intentional (not templated-default) across all tabs
- [ ] Game server version displays correctly on the dashboard
- [ ] Fresh-boot dashboard shows meaningful server-starting/empty states, not blanks
- [ ] Dashboard endpoints degrade gracefully on upstream/transient failures

### Out of Scope

- Building images locally for release/testing — GitHub Actions only (build policy); local VBox is verification-only
- Removing/deleting the WireGuard stack — deprecated but retained for the re-enable path
- Reworking the appliance's NetBird-only exposure into LAN-open access — WebUI/game ports stay overlay-only by design
- New Palworld gameplay features — PPSA packages the community server image, it does not modify the game

## Context

- Mature project with substantial shipped history (v1.2.x WireGuard line frozen on
  `master`; v1.3.0-nb.N NetBird line active on the default `netbird` branch).
- Testing is the current pain point: installer smoke tests run in VirtualBox and
  today lean on blind scancode keystrokes, screenshot polling, and probe scripts —
  all token-heavy. The appliance already enrolls in NetBird at first boot, so the
  test VM gets an overlay IP reachable from a NetBird dev peer, and SSH `:22` is
  already gated through `WG_FRIENDS` from `100.64.0.0/10` — an SSH-first test path
  needs no console-inject/ufw hack.
- Known VBox-on-this-host hazard: WSL2/Hyper-V contention causes guest soft
  lockups; mitigated with `wsl --shutdown` + VM reset.
- Self-hosted NetBird control plane at `nb.pleaseee.eu.org`; `config.yaml
  exposedAddress` must carry explicit `:443` or Signal is advertised portless.

## Constraints

- **Build policy**: Images produced via GitHub Actions only, never locally — single source of truth is `scripts/build-live-usb.sh`
- **Testing**: Local verification in VirtualBox only (boot CI-produced artifacts); installer ISO is the real product to test, img/vdi are byproducts
- **Networking**: Appliance WebUI/game ports must stay NetBird-only; do not open LAN access
- **Security**: `kaiser62/ppsa` repo is public — never commit secrets (NetBird keys, WG creds)
- **Disk**: D: drive is repo-only; downloads/test artifacts/scratch go on H: drive
- **Identity**: Never boot a test VM with baked WG config while the real box is live (shared `10.8.0.2` identity theft)

## Key Decisions

| Decision | Rationale | Outcome |
|----------|-----------|---------|
| NetBird is primary networking; `netbird` is default branch | Solves the NAT/identity problems WireGuard kept hitting (P2P via STUN + relay fallback) | ✓ Good |
| WireGuard deprecated but retained, gated by `PPSA_WG_ENABLED` | Reversible deprecation — keep baked creds for a fast re-enable without re-registering | ✓ Good |
| offen `stop-during-backup` label on the palworld service, not volumes | offen reads the label only from containers; hot-tar of the live save races and aborts | ✓ Good (v1.3.0-nb.12) |
| Test fresh installs over NetBird SSH instead of VBox scancodes/screenshots | Appliance already on the overlay; text-first SSH is far cheaper in tokens | — Pending |
| Reserve a persistent NetBird IP for the test peer | Every build's test VM reachable at a stable address; avoids per-boot IP churn | — Pending |

## Evolution

This document evolves at phase transitions and milestone boundaries.

**After each phase transition** (via `/gsd-transition`):
1. Requirements invalidated? → Move to Out of Scope with reason
2. Requirements validated? → Move to Validated with phase reference
3. New requirements emerged? → Add to Active
4. Decisions to log? → Add to Key Decisions
5. "What This Is" still accurate? → Update if drifted

**After each milestone** (via `/gsd-complete-milestone`):
1. Full review of all sections
2. Core Value check — still the right priority?
3. Audit Out of Scope — reasons still valid?
4. Update Context with current state

---
*Last updated: 2026-07-19 — milestone v1.4.0 (WebUI Professional Overhaul) started*
