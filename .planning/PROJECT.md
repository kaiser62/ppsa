# PPSA — Portable Palworld Server Appliance

## Current State

**Shipped:** v1.5.0 Installer-ISO E2E Tester (2026-07-20) — `scripts/ppsa-installer-e2e.py`
now drives a freshly-built installer ISO from boot through full install to a
target disk, verifies the boot chain (signed shim/GRUB or documented unsigned
fallback), distinguishes a genuine install hang from a slow-but-working one
via heartbeat polling, chains the existing SSH smoke test against the result,
and reports one pass/fail summary with raw noise routed to a log file. CI
wiring remains a deferred stretch item (needs a self-hosted VirtualBox-capable
runner).

**Previously shipped:**
- v1.4.0 WebUI Professional Overhaul (2026-07-20) — see `.planning/milestones/v1.4.0-ROADMAP.md`
- v1.3.0 Build Verification & WebUI Backup (2026-07-17) — see `.planning/milestones/v1.3.0-ROADMAP.md` (if archived)

See `.planning/milestones/v1.5.0-ROADMAP.md` and `.planning/MILESTONES.md` for full milestone history.

## Next Milestone Goals

Not yet defined — run `/gsd-new-milestone` to scope the next milestone.

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
- ✓ Dashboard shows durable, correct game version (REST → container-log parse → last-known-good cache) — v1.4.0 Phase 04
- ✓ Honest fresh-boot dashboard states (server_state: running/starting/stopped) and explicit empty states — v1.4.0 Phase 04
- ✓ Graceful `/api/system` degradation (200 + degraded flag, never bare 500) and actionable frontend error messaging — v1.4.0 Phase 04
- ✓ WebUI looks professional and intentional — shared design-system tokens (spacing/typography/color), 1px card elevation, inline SVG icon sprite, across all 5 tabs — v1.4.0 Phase 05
- ✓ Native `confirm()`/`alert()` calls migrated to styled `.modal` component; responsive at 375px/1440px with 44px touch targets — v1.4.0 Phase 05
- ✓ Scripted installer-ISO run boots a fresh VirtualBox VM and drives install to completion unattended (VBoxManage + blind scancode) — v1.5.0 Phase 06
- ✓ Boot-chain verification (signed shim/GRUB success, documented unsigned fallback) after install — v1.5.0 Phase 07
- ✓ Heartbeat-based hang detection distinguishes slow-but-progressing installs from genuine hangs — v1.5.0 Phase 07
- ✓ Existing SSH smoke test chained as subprocess against freshly-installed box, single pass/fail summary, raw output to log file — v1.5.0 Phase 08

### Active

<!-- Building toward these — next milestone not yet scoped. -->

None yet — run `/gsd-new-milestone` to define next milestone's Active requirements.

### Out of Scope

- Building images locally for release/testing — GitHub Actions only (build policy); local VBox is verification-only
- Removing/deleting the WireGuard stack — deprecated but retained for the re-enable path
- Reworking the appliance's NetBird-only exposure into LAN-open access — WebUI/game ports stay overlay-only by design
- New Palworld gameplay features — PPSA packages the community server image, it does not modify the game

## Context

- Mature project with substantial shipped history (v1.2.x WireGuard line frozen on
  `master`; v1.3.0-nb.N NetBird line active on the default `netbird` branch).
- Testing pain point (installer verification, manual VBox scancode/screenshot
  polling) is now resolved: `scripts/ppsa-installer-e2e.py` drives the full
  boot-install-verify-smoketest loop unattended, one pass/fail summary, raw
  noise routed to a log file instead of context. Manual `ppsa-installer-test`
  skill flow still exists for one-off ad-hoc runs but the scripted path is
  now the default verification route for release builds.
- Known VBox-on-this-host hazard: WSL2/Hyper-V contention causes guest soft
  lockups; mitigated with `wsl --shutdown` + VM reset. Confirmed still present
  during v1.5.0 Phase 6-8 test runs — no fix, workaround only.
- Self-hosted NetBird control plane at `nb.pleaseee.eu.org`; `config.yaml
  exposedAddress` must carry explicit `:443` or Signal is advertised portless.
- WebUI frontend (`docker/webui/app/static/index.html`) carries a real design
  system (spacing/typography CSS custom properties, 1px card/section elevation,
  inline SVG icon sprite, `.modal` component for all destructive confirmations) —
  still a single static file, no framework, no build step. Any future frontend
  work should extend these tokens/classes rather than reintroducing inline styles
  or native `confirm()`/`alert()`.
- CI wiring for the E2E tester (running it in GitHub Actions rather than only
  by hand) is deferred — needs a self-hosted VirtualBox-capable runner, not
  yet provisioned. Tracked as a v2 candidate (CI-01) if a future milestone
  wants it.

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
| Test fresh installs over NetBird SSH instead of VBox scancodes/screenshots | Appliance already on the overlay; text-first SSH is far cheaper in tokens | ✓ Good (v1.5.0 Phase 6-8) |
| Reserve a persistent NetBird IP for the test peer | Every build's test VM reachable at a stable address; avoids per-boot IP churn | ✓ Good (v1.5.0 Phase 6) |
| Boot-chain verified post-boot over SSH (dmesg/`/proc/cmdline` classification) instead of pre-boot ESP file inspection | Avoids a Windows-side sbverify/EFI-partition-mount dependency; SSH access already required for the rest of the pipeline | ✓ Good (v1.5.0 Phase 7) |
| Heartbeat file (`/run/ppsa-install.activity`) written at install.sh call sites, polled by the tester for hang detection | Distinguishes "still pulling Docker layers" from "actually stuck" without guessing a fixed timeout | ✓ Good (v1.5.0 Phase 7) |
| Smoke test invoked as a subprocess, not imported as a module | Keeps `ppsa-smoke-test.py` decoupled and independently runnable; avoids coupling its internals/globals to the e2e orchestrator | ✓ Good (v1.5.0 Phase 8) |
| Worktree base-mismatch auto-degrades to sequential execution (issue #683) | Repo's `netbird` branch diverged from `origin/HEAD`; GSD tooling detects and falls back automatically, no manual intervention needed | ✓ Good (validated 3x: Phase 6, 7, 8) |
| Phase 5 executed sequentially on the main tree instead of git-worktree isolation | Claude Code's `isolation="worktree"` forked from the repo's default branch (`master`) instead of the checked-out `netbird` branch, causing a base-mismatch halt; since all 4 plans touch one shared file anyway (no real parallelism to lose), sequential execution sidesteps the bug entirely | ✓ Good |
| Design-system foundation built as its own first plan (05-01) before any tab restyling | Every later plan (05-02/03/04) needed the same tokens/classes/icon-sprite; building them once up front avoided each tab re-deriving spacing/typography ad hoc | ✓ Good |
| Human-verified the 375px/1440px responsive checkpoint live via browser preview tooling instead of trusting executor self-report | Executor agents cannot render a browser; a `checkpoint:human-verify` gate exists precisely so a real viewport/no-scroll/touch-target check happens before the plan is marked done | ✓ Good |

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
*Last updated: 2026-07-20 after v1.5.0 milestone (Installer-ISO E2E Tester)*
