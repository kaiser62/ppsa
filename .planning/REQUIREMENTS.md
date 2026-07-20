# Requirements: PPSA v1.5.0 — Installer-ISO E2E Tester

**Defined:** 2026-07-20
**Core Value:** A single on-demand script drives a freshly-built installer ISO from
boot through full install to a target disk, verifies the boot chain came up
correctly, runs the existing SSH-based smoke test against the result, and
reports one pass/fail summary.

## v1 Requirements

### VM Orchestration

- [x] **VM-01**: Script creates, boots, resets, and destroys a VirtualBox test VM unattended via VBoxManage — no manual GUI steps
- [x] **VM-02**: Script drives the installer TUI to completion via blind scancode keystroke injection, reusing the sequence proven in the `ppsa-installer-test` skill
- [x] **VM-03**: Script detects install completion by polling for `/opt/ppsa/.installed` (or equivalent first-boot marker) over SSH, distinguishing "still installing" from "done"

### Boot Verification

- [x] **BOOT-01**: Script verifies the post-install boot chain came up correctly — signed shim/GRUB success, or explicitly documents the unsigned-fallback path when Secure Boot is off
- [x] **BOOT-02**: Script distinguishes a genuinely hung install from a slow-but-progressing one via heartbeat/timestamp polling, avoiding false-negative timeouts on slow Docker pulls

### Smoke Test & Reporting

- [x] **TEST-01**: Script invokes the existing `scripts/ppsa-smoke-test.py` against the freshly-installed box and folds its result into the overall verdict, without duplicating its logic
- [x] **TEST-02**: A single script invocation reports one pass/fail summary (exit code 0/1 + one-liner), keeping raw install/boot/smoke-test output out of the main context

### Network Safety

- [x] **NET-01**: Script performs a pre-boot safety check (or documented default) preventing the shared WireGuard identity (`10.8.0.2`) from colliding with a live production server, and tolerates NetBird enrollment delays/timeouts without hanging the whole run

## v2 Requirements

Deferred to a future milestone. Tracked but not in current roadmap.

### Polish & CI

- **POL-01**: Log aggregation with artifact cleanup (preserve logs on FAIL, clean up on PASS)
- **POL-02**: Boot timeout tuning via config file/env vars
- **POL-03**: Docker layer cache reuse on retry
- **POL-04**: Health-check polling before smoke test to reduce false failures during partial boot
- **CI-01**: Wire the E2E tester into GitHub Actions via a self-hosted VirtualBox-capable runner

## Out of Scope

| Feature | Reason |
|---------|--------|
| Preseed/kickstart ISO rewrite | Blind-scancode automation already proven and deterministic; rebuilding the ISO adds complexity for ~2 min savings |
| Packer/Vagrant integration | PPSA is a consumer of CI-built artifacts, not a box builder; VBoxManage direct control is simpler |
| Multi-hypervisor support (KVM/Hyper-V/QEMU) | Only VirtualBox available on the test host; no immediate cross-platform need |
| Kernel signature / driver validation | Orthogonal to PPSA's own boot chain; VirtualBox EFI doesn't enforce Secure Boot anyway |
| Real hardware boot testing | VirtualBox captures the boot semantics that matter; physical hardware testing is a user-deployment concern |
| Parallel multi-VM / fleet test matrix | Single appliance, single target disk — no fleet testing at this scale |

## Traceability

| Requirement | Phase | Status |
|-------------|-------|--------|
| VM-01 | Phase 6 | Complete |
| VM-02 | Phase 6 | Complete |
| VM-03 | Phase 6 | Complete |
| NET-01 | Phase 6 | Complete |
| BOOT-01 | Phase 7 | Complete |
| BOOT-02 | Phase 7 | Complete |
| TEST-01 | Phase 8 | Complete |
| TEST-02 | Phase 8 | Complete |

**Coverage:**

- v1 requirements: 8 total
- Mapped to phases: 8/8 ✓
- Unmapped: 0

---
*Requirements defined: 2026-07-20*
*Last updated: 2026-07-20 after roadmap creation (Phases 6-8, 100% coverage)*
</content>
