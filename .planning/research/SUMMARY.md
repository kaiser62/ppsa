# Project Research Summary

**Project:** PPSA v1.5.0 — Automated Installer-ISO End-to-End Testing  
**Domain:** OS installer automation with VM orchestration, boot-chain verification, and appliance integration  
**Researched:** 2026-07-20  
**Confidence:** HIGH

## Executive Summary

PPSA v1.5.0 requires automating the manual installer-ISO testing flow into a single unattended script. The recommended approach layers three proven technologies: **VBoxManage CLI** for headless VM orchestration, **wallclock-based keystroke timing** for TUI driving, and **SSH polling** for first-boot monitoring and smoke-test integration.

The critical risk is **boot-chain signature corruption** (silent fallback to unsigned GRUB), which requires **pre-boot ESP inspection** before the VM boots. Secondary risks: installer hangs, WireGuard identity theft, and NetBird enrollment timing.

## Key Findings

### Recommended Stack

- **VBoxManage CLI** (VirtualBox 7.0+): VM creation, ISO attachment, keyboard injection, screenshots
- **Python 3.12** (stdlib only): Main orchestrator script (~500 LOC)
- **PowerShell 7 (VirtualBox module)**: Extend existing `modules/VirtualBox.psm1`
- **Existing smoke-test**: `scripts/ppsa-smoke-test.py` reused as subprocess

### Expected Features

**Must have (table stakes):**
- VM lifecycle automation (create, boot, reset, destroy)
- Installer TUI keystroke injection (blind scancode sequences)
- Installer completion detection (poll `/opt/ppsa/.installed`)
- Boot-chain verification (pre-boot ESP inspection)
- Reuse existing SSH smoke test
- Single script invocation with exit code 0 (PASS) or 1 (FAIL)

### Architecture Approach

The E2E tester is a new orchestration layer that automates the proven manual skill. VM create → TUI boot → install → first-boot monitoring → SSH bootstrap → smoke test.

**Major components:**
1. **Installer E2E Script** (`scripts/ppsa-installer-e2e.py`) — Main orchestrator (~500 LOC)
2. **VirtualBox Module Extension** (`modules/VirtualBox.psm1` additions)
3. **Skill Wrapper** (`.claude/skills/ppsa-installer-e2e/SKILL.md`, future)

### Critical Pitfalls

1. **Boot-chain signature corruption** — Mitigation: Pre-boot ESP inspection before VM boots
2. **Installer hangs masquerading as progress** — Mitigation: Embed heartbeat timestamp in installer
3. **WireGuard identity theft** — Mitigation: Pre-boot hub API check; disable WireGuard by default
4. **NetBird enrollment stalls** — Mitigation: Pre-build credential injection, pre-boot control-plane check
5. **Blind keystroke sequence timing race** — Mitigation: Wallclock-based fixed delays

## Implications for Roadmap

### Phase 1: VirtualBox Module Extensions
**Effort:** ~1-2 hours | **Research flags:** None

### Phase 2: Core E2E Orchestrator Script
**Effort:** ~4-6 hours | **Research flags:** None

### Phase 3: Boot-Chain Verification & Pre-Boot ESP Inspection
**Effort:** ~2-3 hours | **Research flags:** Sbverify availability may need validation

### Phase 4: Installer Heartbeat & Resource Pre-Checks
**Effort:** ~3-4 hours | **Dependencies:** Phase 2

### Phase 5: NetBird Enrollment Hardening
**Effort:** ~2-3 hours | **Dependencies:** Phase 2

### Phase 6: Logging, Artifacts & Local Test Suite
**Effort:** ~2-3 hours | **Dependencies:** Phases 1-5

### Phase 7: CI Integration (Stretch Goal)
**Blocker:** Self-hosted runner with VirtualBox not yet available

## Confidence Assessment

| Area | Confidence | Notes |
|------|------------|-------|
| Stack | HIGH | VBoxManage and Python proven in existing builder. |
| Features | HIGH | All table-stakes documented in existing manual skill. |
| Architecture | HIGH | Thin wrapper over existing pieces. |
| Pitfalls | HIGH | Derived from documented PPSA constraints. |

**Overall confidence:** HIGH

## Gaps to Address

1. **Sbverify availability:** Verify in Debian base packages during Phase 3
2. **Empirical timeout calibration:** Hand-run Phase 2 first, capture actual timings
3. **NetBird control plane uptime:** Verify before shipping Phase 5
4. **Self-hosted runner provisioning:** Track as infrastructure dependency for Phase 7
5. **GitHub Actions secrets:** Ensure PPSA_NB_SETUP_KEY and PPSA_NB_MANAGEMENT_URL exist

## Sources

- STACK.md (2026-07-20) — Technology decisions, VBoxManage justification
- FEATURES.md (2026-07-20) — Feature landscape, table-stakes, MVP recommendation
- ARCHITECTURE.md (2026-07-20) — System design, component boundaries, data flow
- PITFALLS.md (2026-07-20) — Critical/moderate/minor pitfall analysis with mitigation

---

*Research completed: 2026-07-20*  
*Ready for roadmap: YES*
