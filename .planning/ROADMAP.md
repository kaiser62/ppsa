# Roadmap: PPSA — Token-Efficient Build Verification

## Overview

PPSA's shipped appliance capabilities are already Validated — this milestone
does not touch the appliance itself. It replaces the *verification* method for
future builds: today, confirming a fresh install works means blind VBox
scancode typing, screenshot polling, and dumping raw container logs into the
working context. The appliance already enrolls in NetBird at first boot, and
SSH is already gated open to `100.64.0.0/10` through the `WG_FRIENDS` chain —
so a test VM is reachable over ordinary SSH the moment it finishes installing.

Two phases get there. Phase 1 makes a fresh test VM reachable over SSH at a
stable, reserved NetBird overlay IP, documented so a future session doesn't
have to rediscover the enrollment dance. Phase 2 builds the one-shot smoke
test script that rides that SSH connection: it runs the full install
checklist, asserts the three nb.12 regression fixes explicitly, keeps raw
output off to the side, and reports a single pass/fail summary.

## Phases

**Phase Numbering:**

- Integer phases (1, 2, 3): Planned milestone work
- Decimal phases (2.1, 2.2): Urgent insertions (marked with INSERTED)

Decimal phases appear between their surrounding integers in numeric order.

- [ ] **Phase 1: Overlay Access** - A fresh test VM is reachable over SSH at a persistent, reserved NetBird overlay IP, with the enrollment procedure documented for repeat use
- [ ] **Phase 2: Scripted Smoke Test** - One host-side script drives the full install checklist over that SSH connection, asserts the nb.12 regression fixes, and reports a single pass/fail summary with raw output kept out of the main context
- [ ] **Phase 3: WebUI Save-File Backup & Restore** - The WebUI gains a lightweight save-file backup action and a safe restore flow (from an on-box archive or an uploaded file) that correctly replaces the live Palworld save

## Phase Details

### Phase 1: Overlay Access

**Goal**: A freshly installed test VM is reachable over SSH at a stable NetBird overlay address, using only the appliance's existing first-boot enrollment and firewall behavior — no console-injected ufw/LAN exceptions — and the setup is repeatable without rediscovery.
**Depends on**: Nothing (first phase)
**Requirements**: NET-01, NET-02, NET-03
**Success Criteria** (what must be TRUE):

  1. SSH from the designated NetBird dev peer to a freshly installed test VM's overlay IP succeeds with no console-injected ufw/LAN exception and no manual firewall edit
  2. The test VM enrolls at the same reserved/persistent NetBird overlay IP across rebuilds and reboots, so the address doesn't need to be rediscovered per build
  3. A written procedure (in `docs/` or `.planning/`) lets a future session reproduce the test-peer enrollment and reserved-IP setup from scratch, without re-deriving it from first principles

**Plans:** 1 plan

Plans:

- [ ] 01-01-PLAN.md — Isolated NetBird test-peer identity, stable hostname/DNS-label mechanism, live-verified SSH-over-NetBird access, and updated docs/skill

### Phase 2: Scripted Smoke Test

**Goal**: Verifying a build is a single host-side script invocation over SSH that returns pass/fail, replacing the interactive VBox scancode/screenshot/log-dump loop, while still catching the specific regressions that have bitten this appliance before.
**Depends on**: Phase 1
**Requirements**: TEST-01, TEST-02, TEST-03, TEST-04
**Success Criteria** (what must be TRUE):

  1. Running one host-side script against the test VM's overlay IP checks stack-up, container health, firewall chain presence, NetBird connectivity, WireGuard dormancy, WebUI reachability, and backup completion — entirely via SSH text output, no screenshots or scancode input
  2. A single invocation of that script produces one pass/fail summary, not a sequence of separate interactive tool calls the operator has to reason about individually
  3. Raw command/container output from the run is written to a file (or handled by a subagent) rather than appearing in the main working context — only the distilled summary does
  4. The script explicitly asserts the three v1.3.0-nb.12 fixes (server-action endpoints return 200 not 500, backup trigger returns immediately without freezing the WebUI, a backup archive file actually appears in the backup directory after a run) and fails the run if any regress

**Plans**: 1/1 plans executed

Plans:

- [x] 02-01-PLAN.md — Create host-side smoke test script + update installer-test SKILL.md to chain Phase 1 SSH path into smoke test workflow

### Phase 3: WebUI Save-File Backup & Restore

**Goal**: A user can, from the WebUI, take a fast save-file-only backup of their world and later restore it correctly — from either an on-box archive or a file they upload — without losing their current save if something goes wrong.
**Depends on**: Nothing (independent appliance-feature phase; not gated on Phases 1–2)
**Requirements**: BKP-01, BKP-02, BKP-03, BKP-04, BKP-05
**Success Criteria** (what must be TRUE):

  1. A WebUI "save-file backup" action produces a timestamped archive containing only the Palworld SaveGames data, without stopping the palworld container, and the archive appears in the WebUI backup list
  2. From the WebUI the user can restore from an archive already on the box (chosen from the list) OR from a `.tar.gz` archive they upload from their computer
  3. Restore requires an explicit confirmation, and before overwriting it stops palworld, snapshots the current SaveGames to a safety archive, extracts the chosen archive over SaveGames, then restarts palworld
  4. Restore validates the archive is a well-formed Palworld save archive before touching the live save, and reports an unambiguous success or failure to the user (no silent partial restore)

**Plans**: 2 plans

Plans:

- [ ] 03-01-PLAN.md — Backend: save-file backup endpoint, restore API (on-box + upload), archive validation, _run_docker stop/start
- [ ] 03-02-PLAN.md — Frontend: Save-File Backup button, restore actions + confirm on archive rows, upload-tar.gz card, JS handlers

> **Scope note:** Phase 3 is an appliance WebUI feature, distinct from the Phase 1–2 build-verification milestone. Kept in this roadmap for tracking; may be split into its own milestone later.

## Progress

**Execution Order:**
Phases 1 → 2 are the testing milestone (2 depends on 1). Phase 3 is independent and can be planned/executed in parallel with either.

| Phase | Plans Complete | Status | Completed |
|-------|----------------|--------|-----------|
| 1. Overlay Access | 1/1 | Not started (partial) | - |
| 2. Scripted Smoke Test | 1/1 | In Progress|  |
| 3. WebUI Save-File Backup & Restore | 2/2 | Complete | 2026-07-16 |
