# Roadmap: PPSA — Portable Palworld Server Appliance

## Milestones

- ✅ **v1.3.0 Build Verification & WebUI Backup** — Phases 1-3 (shipped 2026-07-17)
- ✅ **v1.4.0 WebUI Professional Overhaul** — Phases 4-5 (shipped 2026-07-20)
- 🚧 **v1.5.0 Installer-ISO E2E Tester** — Phases 6-8 (in progress)

## Phases

**Phase Numbering:**

- Integer phases (1, 2, 3): Planned milestone work
- Decimal phases (2.1, 2.2): Urgent insertions (marked with INSERTED)

Decimal phases appear between their surrounding integers in numeric order.
Phase numbering is continuous across milestones — v1.5.0 continues from Phase 6.

<details>
<summary>✅ v1.3.0 Build Verification & WebUI Backup (Phases 1-3) — SHIPPED 2026-07-17</summary>

- [x] Phase 1: Overlay Access (1/1 plans) — completed 2026-07-17
- [x] Phase 2: Scripted Smoke Test (1/1 plans) — completed 2026-07-17
- [x] Phase 3: WebUI Save-File Backup & Restore (2/2 plans) — completed 2026-07-17

Full details: `.planning/milestones/v1.3.0-ROADMAP.md` (if archived) — otherwise this milestone predates per-milestone archival tooling; see git history around tag range ending 2026-07-17.

</details>

<details>
<summary>✅ v1.4.0 WebUI Professional Overhaul (Phases 4-5) — SHIPPED 2026-07-20</summary>

- [x] Phase 4: Dashboard Correctness & Error Handling (1/1 plans) — completed 2026-07-20
- [x] Phase 5: Professional Visual Redesign (4/4 plans) — completed 2026-07-20

Full details: `.planning/milestones/v1.4.0-ROADMAP.md`

</details>

### 🚧 v1.5.0 Installer-ISO E2E Tester (Phases 6-8) - In Progress

**Milestone Goal:** A single on-demand script drives a freshly-built installer ISO
from boot through full install to a target disk, verifies the boot chain came up
correctly, runs the existing SSH-based smoke test against the result, and reports
one pass/fail summary.

- [x] **Phase 6: VM Orchestration & Scripted Install** - A script unattended-installs the freshly-built ISO into a disposable VirtualBox VM end to end, and refuses to run when doing so would collide with the live production WireGuard identity (completed 2026-07-20)
- [x] **Phase 7: Boot-Chain Verification & Hang Detection** - The tester tells a genuinely broken/hung install apart from a correctly-booted one (signed or documented-fallback boot chain) instead of guessing from a fixed timeout (completed 2026-07-20)
- [ ] **Phase 8: Smoke-Test Integration & Unified Reporting** - Running the whole pipeline is one script invocation that folds the existing smoke test into a single pass/fail verdict, with raw output kept out of the main context

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

<details>
<summary>✅ v1.4.0 phase details (Phases 4-5)</summary>

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

**Plans**: 4/4 plans executed

Plans:

- [x] 05-01-PLAN.md — Design system foundation: spacing/typography tokens, elevation, SVG icon sprite, touch targets, brand-consistent header
- [x] 05-02-PLAN.md — Apply system to Dashboard + Server Controls tabs
- [x] 05-03-PLAN.md — Apply system to Firewall + Backup + Wi-Fi tabs (empty states, long-text overflow, emoji-to-SVG icon swap)
- [x] 05-04-PLAN.md — Migrate remaining native confirm()/alert() calls to .modal; human-verify 375px/1440px responsive layout and touch targets

**UI hint**: yes

</details>

### Phase 6: VM Orchestration & Scripted Install

**Goal**: A script can unattended-install the freshly-built installer ISO into a disposable VirtualBox VM end to end — create, boot, drive the TUI blind, detect completion — and refuses to proceed when doing so risks the shared WireGuard identity, without needing a human at the console.
**Depends on**: Nothing (first phase of this milestone)
**Requirements**: VM-01, VM-02, VM-03, NET-01
**Success Criteria** (what must be TRUE):

  1. Running the script against a given installer ISO creates a fresh VirtualBox VM, boots it, and destroys/cleans it up afterward without any manual VirtualBox GUI interaction
  2. The script drives the installer TUI via blind scancode keystroke injection (reusing the sequence proven in the `ppsa-installer-test` skill) all the way to install completion, unattended
  3. The script correctly distinguishes "install still in progress" from "install done" by polling for `/opt/ppsa/.installed` (or equivalent marker) over SSH, rather than guessing from elapsed time
  4. Before booting, the script performs a safety check (or applies a documented safe default) that prevents the test VM from colliding with the live production box's shared WireGuard identity (`10.8.0.2`), and it tolerates a slow/failed NetBird enrollment without hanging the whole run

**Plans:** 2/2 plans complete

Plans:

- [x] 06-01-PLAN.md — Orchestrator skeleton: VirtualBox VM lifecycle (create/attach-ISO/boot/destroy via VBoxManage) + pre-boot WireGuard hub identity safety check (NET-01)
- [x] 06-02-PLAN.md — Blind scancode TUI driving (VM-02) + SSH-polled `/opt/ppsa/.installed` completion detection (VM-03) + full single-invocation `run()` pipeline, completing NET-01's NetBird-timeout tolerance

### Phase 7: Boot-Chain Verification & Hang Detection

**Goal**: After a scripted install completes, the tester can say with confidence whether the box actually booted correctly (signed shim/GRUB, or a documented unsigned-fallback path) — and, while waiting, can tell a genuinely hung install apart from one that's just slow, instead of guessing from a single fixed timeout.
**Depends on**: Phase 6 (needs a scripted install run to verify against)
**Requirements**: BOOT-01, BOOT-02
**Success Criteria** (what must be TRUE):

  1. After a scripted install, the tester reports whether the post-install boot chain came up via signed shim/GRUB, or explicitly flags that it fell back to the unsigned path (only expected/acceptable when Secure Boot is off)
  2. During a long-running install (e.g. slow Docker pulls), the tester distinguishes real progress from a genuine hang via heartbeat/timestamp polling, so a slow-but-working install is not falsely reported as failed
  3. A boot-chain verification failure and a hang-detected timeout produce distinguishable, actionable failure reasons in the tester's output rather than one generic "failed" result

**Plans:** 2/2 plans complete

Plans:

- [x] 07-01-PLAN.md — install.sh: mark_step_activity() heartbeat helper writing a world-readable Unix timestamp to /run/ppsa-install.activity, wired into Step 3's Docker pull/up loops (BOOT-02 guest side)
- [x] 07-02-PLAN.md — ppsa-installer-e2e.py: verify_boot_chain() post-boot SSH classification (BOOT-01), heartbeat-aware hang detection extending wait_for_install_complete() (BOOT-02), wired into run() with a third distinguishable SUSPECTED HANG failure reason

### Phase 8: Smoke-Test Integration & Unified Reporting

**Goal**: The whole pipeline — scripted install, boot verification, and functional smoke test — runs from a single script invocation and produces one pass/fail verdict, with all the raw noise kept out of the main working context.
**Depends on**: Phase 6, Phase 7 (needs a verified-booted box to smoke-test)
**Requirements**: TEST-01, TEST-02
**Success Criteria** (what must be TRUE):

  1. The tester invokes the existing `scripts/ppsa-smoke-test.py` against the freshly-installed box and folds its pass/fail result into the overall verdict, without reimplementing any of its checks
  2. A single script invocation covering install + boot-verify + smoke-test exits 0 on full success and 1 on any failure, printing one human-readable one-line summary
  3. Raw install/boot/smoke-test output (VM console text, SSH command output, smoke-test details) is written to a log file rather than dumped into the main context — only the distilled summary is
  4. The one-line summary makes it clear which stage failed (install, boot-verify, or smoke-test) when the overall verdict is FAIL, so a failure doesn't require re-running to diagnose

**Plans**: TBD

## Progress

**Execution Order:**
Phases execute in numeric order. Phase 6 (VM orchestration + scripted install) is the foundation; Phase 7 (boot-chain verification + hang detection) depends on Phase 6 producing a completed install to verify; Phase 8 (smoke-test integration + unified reporting) depends on both, chaining the existing smoke test onto a verified-booted box and producing the single pass/fail verdict.

| Phase | Milestone | Plans Complete | Status | Completed |
|-------|-----------|----------------|--------|-----------|
| 1. Overlay Access | v1.3.0 | 1/1 | Complete | 2026-07-17 |
| 2. Scripted Smoke Test | v1.3.0 | 1/1 | Complete | 2026-07-17 |
| 3. WebUI Save-File Backup & Restore | v1.3.0 | 2/2 | Complete | 2026-07-17 |
| 4. Dashboard Correctness & Error Handling | v1.4.0 | 1/1 | Complete | 2026-07-20 |
| 5. Professional Visual Redesign | v1.4.0 | 4/4 | Complete | 2026-07-20 |
| 6. VM Orchestration & Scripted Install | v1.5.0 | 2/2 | Complete    | 2026-07-20 |
| 7. Boot-Chain Verification & Hang Detection | v1.5.0 | 2/2 | Complete    | 2026-07-20 |
| 8. Smoke-Test Integration & Unified Reporting | v1.5.0 | 0/? | Not started | - |
</content>
