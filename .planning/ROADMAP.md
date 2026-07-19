# Roadmap: PPSA — Portable Palworld Server Appliance

## Milestones

- ✅ **v1.3.0 Build Verification & WebUI Backup** - Phases 1-3 (shipped 2026-07-17)
- 🚧 **v1.4.0 WebUI Professional Overhaul** - Phases 4-5 (in progress)

## Phases

**Phase Numbering:**

- Integer phases (1, 2, 3): Planned milestone work
- Decimal phases (2.1, 2.2): Urgent insertions (marked with INSERTED)

Decimal phases appear between their surrounding integers in numeric order.
Phase numbering is continuous across milestones — v1.4.0 continues from Phase 4.

<details>
<summary>✅ v1.3.0 Build Verification & WebUI Backup (Phases 1-3) - SHIPPED 2026-07-17</summary>

- [x] **Phase 1: Overlay Access** - A fresh test VM is reachable over SSH at a persistent, reserved NetBird overlay IP, with the enrollment procedure documented for repeat use
- [x] **Phase 2: Scripted Smoke Test** - One host-side script drives the full install checklist over that SSH connection, asserts the nb.12 regression fixes, and reports a single pass/fail summary with raw output kept out of the main context
- [x] **Phase 3: WebUI Save-File Backup & Restore** - The WebUI gains a lightweight save-file backup action and a safe restore flow (from an on-box archive or an uploaded file) that correctly replaces the live Palworld save

</details>

### 🚧 v1.4.0 WebUI Professional Overhaul (Phases 4-5) - In Progress

**Milestone Goal:** Redesign the plain-JS WebUI to look professional and intentional and fix the dashboard correctness/error-handling bugs — without changing the FastAPI + no-build architecture or the NetBird-only port exposure.

- [x] **Phase 4: Dashboard Correctness & Error Handling** - The dashboard reports the real game version, shows honest server-starting/empty states on fresh boot, and degrades gracefully with actionable messaging when upstream calls fail (completed 2026-07-20)
- [ ] **Phase 5: Professional Visual Redesign** - Every WebUI tab shares one intentional, non-templated design system as a single static bundle (no framework, no build step) that stays usable on laptop and phone

## Phase Details

<details>
<summary>✅ v1.3.0 phase details (Phases 1-3)</summary>

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

- [x] 01-01-PLAN.md — Isolated NetBird test-peer identity, stable hostname/DNS-label mechanism, live-verified SSH-over-NetBird access, and updated docs/skill

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

- [x] 03-01-PLAN.md — Backend: save-file backup endpoint, restore API (on-box + upload), archive validation, _run_docker stop/start
- [x] 03-02-PLAN.md — Frontend: Save-File Backup button, restore actions + confirm on archive rows, upload-tar.gz card, JS handlers

</details>

### Phase 4: Dashboard Correctness & Error Handling

**Goal**: The management dashboard tells the truth about the server — it shows the real running game version, distinguishes "still starting" from "broken" on a fresh boot, renders explicit empty states instead of silent blanks, and stays usable with a clear, actionable banner when an upstream/transient call fails.
**Depends on**: Nothing (independent of Phase 5; backend + data-source correctness)
**Requirements**: DASH-01, DASH-02, DASH-03, DASH-04, DASH-05
**Success Criteria** (what must be TRUE):

  1. The dashboard shows the correct running Palworld game version even when the REST `/info` version field is empty — the value is sourced reliably (e.g. parsed from the container log) rather than displaying blank
  2. On a fresh boot, while the palworld container is still initializing, the dashboard shows an explicit "server starting / initializing" state instead of blank fields or zeroed metrics
  3. Metrics and player data that are not yet available render as explicit empty states ("no players yet", "metrics unavailable") rather than silently blank or misleading zeros
  4. When a dashboard/status endpoint hits an upstream or transient failure, the page stays usable and shows a clear status banner instead of breaking or hanging
  5. Frontend surfaces API/network errors to the user with actionable messaging (what failed, what to try), never failing silently or dumping a raw stack/error string

**Plans**: 1 plan

Plans:

- [x] 04-01-PLAN.md — Harden dashboard/status backend (durable version cache, bounded concurrent upstream fetch, players_known signal, graceful /api/system degrade) + honest state-aware frontend rendering; live-verify DASH-01..05

### Phase 5: Professional Visual Redesign

**Goal**: The WebUI looks like an intentional product rather than a templated default — one cohesive design system (typography, color, spacing, components) applied consistently across the dashboard, server controls, firewall, backup, and Wi-Fi tabs — delivered as a single static bundle with no framework and no build step, and usable on both a laptop and a phone.
**Depends on**: Phase 4 (redesign builds on the corrected dashboard states/empty-state affordances so the visual layer dresses real, honest data)
**Requirements**: UI-01, UI-02, UI-03, UI-04
**Success Criteria** (what must be TRUE):

  1. Every WebUI tab (dashboard, server controls, firewall, backup, Wi-Fi) presents a cohesive, intentional visual design — typography, color, spacing, and components — that does not read as a templated/unstyled default
  2. All tabs draw from one shared design system (shared CSS variables/components) rather than ad-hoc per-tab styling, so a change to the system propagates everywhere
  3. The redesigned UI is still a single static bundle served by the existing FastAPI app — no JS framework, no bundler, no build step, and `webui/frontend/` is untouched
  4. The UI is usable and readable on both a typical laptop browser and a phone browser (the onboarding and friend-facing case), without horizontal scrolling or broken layout

**Plans**: TBD
**UI hint**: yes

## Progress

**Execution Order:**
Phases execute in numeric order. Phase 4 (dashboard correctness) is independent and can start immediately; Phase 5 (visual redesign) depends on Phase 4 so the new visual layer dresses corrected, honest dashboard data. Phase 5 routes through `/gsd-ui-phase` for a UI-SPEC design contract before planning.

| Phase | Milestone | Plans Complete | Status | Completed |
|-------|-----------|----------------|--------|-----------|
| 1. Overlay Access | v1.3.0 | 1/1 | Complete | 2026-07-17 |
| 2. Scripted Smoke Test | v1.3.0 | 1/1 | Complete | 2026-07-17 |
| 3. WebUI Save-File Backup & Restore | v1.3.0 | 2/2 | Complete | 2026-07-17 |
| 4. Dashboard Correctness & Error Handling | v1.4.0 | 1/1 | Complete    | 2026-07-20 |
| 5. Professional Visual Redesign | v1.4.0 | 0/TBD | Not started | - |
</content>
</invoke>
