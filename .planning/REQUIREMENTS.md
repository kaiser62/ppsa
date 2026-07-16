# Requirements: PPSA — Token-Efficient Build Verification

**Defined:** 2026-07-16
**Core Value:** A user can boot the appliance and their friends can reach a working Palworld server over the private overlay network — every build must preserve that end-to-end path.

> Scope note: PPSA's shipped appliance capabilities are already Validated (see
> `.planning/PROJECT.md`). This milestone targets the current active goal —
> making every future build's install verification reliable **and** cheap in
> tokens, by driving it over NetBird SSH instead of blind VBox scancode/screenshot
> loops.

## v1 Requirements

Requirements for the current milestone. Each maps to a roadmap phase.

### Overlay Access

- [ ] **NET-01**: A freshly installed test VM is reachable over SSH at its NetBird overlay IP from a designated NetBird dev peer, with no console-injected ufw/LAN exception
- [ ] **NET-02**: The test peer enrolls at a persistent, reserved NetBird IP so every build's test VM is reachable at the same overlay address (reserved IP or dedicated test setup key)
- [ ] **NET-03**: The test-peer enrollment + persistent-IP setup is documented as a repeatable procedure a future session can follow without rediscovery

### Smoke Test

- [ ] **TEST-01**: The full install smoke checklist (stack up, containers healthy, firewall chain present, NetBird connected, WG dormant, WebUI reachable, backup end-to-end) runs over SSH text output — no screenshots, no scancode typing
- [ ] **TEST-02**: The smoke checklist runs as one host-side script that returns a single pass/fail summary rather than dozens of interactive tool calls
- [ ] **TEST-03**: Raw test output (container logs, verbose command output) is captured to files or a subagent and only a distilled pass/fail summary reaches the main working context

### Regression Guard

- [ ] **TEST-04**: The scripted smoke test asserts the three v1.3.0-nb.12 fixes (server-action 200, non-blocking backup trigger, backup archive actually written) so a regression fails the run automatically

### WebUI Backup & Restore

> Appliance WebUI feature (separate concern from the testing milestone above). Added as Phase 3.

- [ ] **BKP-01**: From the WebUI, a "save-file backup" action creates a timestamped archive of ONLY the Palworld SaveGames data (not a full volume/offen backup) without stopping the palworld container, and the archive lands in the backups directory
- [ ] **BKP-02**: The WebUI lists save-file archives and can restore from one already present on the box (selected from the list)
- [ ] **BKP-03**: The WebUI can restore from a save archive uploaded by the user from their own computer
- [ ] **BKP-04**: Restore is safe-by-default: it requires an explicit user confirmation, stops palworld, backs up the current SaveGames first, extracts the chosen archive over SaveGames, then restarts palworld
- [ ] **BKP-05**: Restore validates the archive is a well-formed Palworld save archive BEFORE touching the live save, and reports a clear success/failure result to the user ("restore from webui correctly")

## v2 Requirements

Deferred — acknowledged but not in this milestone.

### CI Automation

- **CI-01**: Boot the built image inside GitHub Actions and run the smoke test there, so local VBox testing becomes exception-only
- **CI-02**: Publish smoke-test pass/fail as a release-gate check

## Out of Scope

| Feature | Reason |
|---------|--------|
| Building images locally | Build policy: GitHub Actions only; local is verification-only |
| Opening WebUI/game ports to LAN for test convenience | Appliance is NetBird-only by design |
| Removing the VBox test path entirely | Still the sanctioned local verification environment; only reducing its token cost |
| Replacing NetBird with a different overlay for testing | NetBird is the shipped primary path; test over the real network |

## Traceability

| Requirement | Phase | Status |
|-------------|-------|--------|
| NET-01 | Phase 1 | Pending |
| NET-02 | Phase 1 | Pending |
| NET-03 | Phase 1 | Pending |
| TEST-01 | Phase 2 | Pending |
| TEST-02 | Phase 2 | Pending |
| TEST-03 | Phase 2 | Pending |
| TEST-04 | Phase 2 | Pending |
| BKP-01 | Phase 3 | Pending |
| BKP-02 | Phase 3 | Pending |
| BKP-03 | Phase 3 | Pending |
| BKP-04 | Phase 3 | Pending |
| BKP-05 | Phase 3 | Pending |

**Coverage:**
- v1 requirements: 12 total
- Mapped to phases: 12
- Unmapped: 0 ✓

---
*Requirements defined: 2026-07-16*
*Last updated: 2026-07-16 after adding Phase 3 (WebUI Save-File Backup & Restore — BKP-01..05)*
