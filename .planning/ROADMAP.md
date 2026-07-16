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

## Phase Details

### Phase 1: Overlay Access
**Goal**: A freshly installed test VM is reachable over SSH at a stable NetBird overlay address, using only the appliance's existing first-boot enrollment and firewall behavior — no console-injected ufw/LAN exceptions — and the setup is repeatable without rediscovery.
**Depends on**: Nothing (first phase)
**Requirements**: NET-01, NET-02, NET-03
**Success Criteria** (what must be TRUE):
  1. SSH from the designated NetBird dev peer to a freshly installed test VM's overlay IP succeeds with no console-injected ufw/LAN exception and no manual firewall edit
  2. The test VM enrolls at the same reserved/persistent NetBird overlay IP across rebuilds and reboots, so the address doesn't need to be rediscovered per build
  3. A written procedure (in `docs/` or `.planning/`) lets a future session reproduce the test-peer enrollment and reserved-IP setup from scratch, without re-deriving it from first principles
**Plans**: TBD

### Phase 2: Scripted Smoke Test
**Goal**: Verifying a build is a single host-side script invocation over SSH that returns pass/fail, replacing the interactive VBox scancode/screenshot/log-dump loop, while still catching the specific regressions that have bitten this appliance before.
**Depends on**: Phase 1
**Requirements**: TEST-01, TEST-02, TEST-03, TEST-04
**Success Criteria** (what must be TRUE):
  1. Running one host-side script against the test VM's overlay IP checks stack-up, container health, firewall chain presence, NetBird connectivity, WireGuard dormancy, WebUI reachability, and backup completion — entirely via SSH text output, no screenshots or scancode input
  2. A single invocation of that script produces one pass/fail summary, not a sequence of separate interactive tool calls the operator has to reason about individually
  3. Raw command/container output from the run is written to a file (or handled by a subagent) rather than appearing in the main working context — only the distilled summary does
  4. The script explicitly asserts the three v1.3.0-nb.12 fixes (server-action endpoints return 200 not 500, backup trigger returns immediately without freezing the WebUI, a backup archive file actually appears in the backup directory after a run) and fails the run if any regress
**Plans**: TBD

## Progress

**Execution Order:**
Phases execute in numeric order: 1 → 2

| Phase | Plans Complete | Status | Completed |
|-------|----------------|--------|-----------|
| 1. Overlay Access | 0/TBD | Not started | - |
| 2. Scripted Smoke Test | 0/TBD | Not started | - |
