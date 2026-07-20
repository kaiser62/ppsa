# Feature Landscape: Automated Installer-ISO E2E Testing

**Domain:** Single-appliance OS installer automation & E2E verification (Linux/Debian boot chain, containerized stack validation)  
**Researched:** 2026-07-20  
**Focus:** PPSA v1.5.0 milestone — scripting the manual installer-test skill into a single invocation  
**Scale:** Single appliance type, single target disk, no fleet/matrix testing

---

## Table Stakes

Features required to deliver the core value: scripted installer-ISO boot → install → boot-chain verification → smoke test → single pass/fail summary.

| Feature | Why Expected | Complexity | Notes |
|---------|--------------|------------|-------|
| **VM lifecycle automation (create, boot, reset, destroy)** | Unattended testing requires no manual VirtualBox GUI steps; all phases must be CLI-callable | Low | VBoxManage commands already documented; no dependency on unattended-install feature |
| **Installer TUI keystroke injection (blind scancode sequence)** | Existing skill proves the installer responds to blind scancodes; reuse that proven pattern rather than switching to preseed/grub-editenv | Low | Already demonstrated in ppsa-installer-test skill; no new tech needed |
| **Installer completion detection** | Must distinguish "still installing" from "install finished"; if we hit the reboot, SSH should work | Medium | Poll for `/opt/ppsa/.installed` flag over SSH; fallback: poll systemd journal for "ppsa-firstboot" completion events |
| **Boot-chain verification (signed shim/GRUB, or documented fallback)** | Core value: appliance must boot post-install; must verify signature chain (if available) or document unsigned fallback path | Medium | Query `/proc/cmdline` + EFI boot path via SSH; compare against known-good patterns (shim-loaded vs standalone GRUB); no interactive console parsing |
| **Reuse existing SSH smoke test** | v1.3.0 Phase 2 already provides `ppsa-smoke-test.py` — fold its output into the E2E verdict | Low | Script already returns pass/fail; orchestrator chains it and aggregates results |
| **Single script invocation** | User invokes once, gets one PASS/FAIL summary; no manual VM management | Low | Orchestrator script manages all phases; reports exit code + summary line to stdout |
| **SSH access (NetBird overlay or ufw bootstrap)** | Test VM enrolls on first boot; Phase 1 establishes stable NetBird DNS label; Phase 2+ uses plain SSH | Medium | Depends on NetBird enrollment at first boot (already baked); orchestrator polls for overlay IP readiness |

---

## Differentiators

Features that add polish, reduce debugging time, or enable faster iteration — valuable but not required for first ship.

| Feature | Value Proposition | Complexity | Notes |
|---------|-------------------|------------|-------|
| **Log aggregation + artifact cleanup** | On failure, preserve install/boot/smoke-test logs + VM disk snapshot for later analysis; on success, clean up to save disk space | Medium | Write logs to `H:\dev\palimage\logs\<timestamp>\`; optionally snapshot VM disk before teardown |
| **Cached image pull on retry** | If first-boot Docker pull times out, second run should reuse cached layers instead of re-pulling everything | Low | Docker cache is per-VM; skip deletion of VDI on retry path (only on success) |
| **Parallel multi-image test matrix** | Test multiple PPSA versions (or build artifacts) sequentially or in parallel; report summary table | High | Out of scope for v1.5.0 (single appliance); infrastructure for phase 6+ |
| **Boot timeout tuning** | Customize Docker pull timeout, first-boot step timeouts (per phase) without editing script | Medium | Read timeouts from config file or env vars; document defaults in help text |
| **Signed boot-chain screenshot** | On success, capture screenshot of EFI boot menu or kernel boot messages proving signed path was used | Low | VirtualBox screenshot after boot, parse for "Secure Boot" / "shim" keywords; document unsigned fallback if not found |
| **Health check before smoke test** | Poll WebUI healthcheck endpoint + container status before running full smoke test, skip smoke test on partial-boot failure | Medium | Adds ~5s polling loop; reduces false FAIL if Docker stack is still coming up |
| **Custom test peer stable IP reservation** | Phase 1 creates a NetBird peer that always gets the same IP for repeat test runs; no per-VM IP churn | High | Requires NetBird control-plane setup (already self-hosted); adds one-time NetBird peer provisioning |

---

## Anti-Features

Capabilities to explicitly NOT build — they add weight without delivering value at this stage.

| Anti-Feature | Why Avoid | What to Do Instead |
|--------------|-----------|-------------------|
| **Preseed/kickstart script generation** | Existing blind-scancode pattern is proven, repeatable, and does NOT require rebuilding the ISO. Preseed adds complexity (modify ISO, rebuild, re-validate signature chain) and would only save ~2min per test run. | Stick with scancode sequence; it's automated, deterministic, and already works. |
| **Full Packer/Vagrant integration** | Packer is a full VM image builder (produces reusable boxes); PPSA already builds images via GitHub Actions + live-build. E2E tester is a consumer of CI artifacts, not a producer. Vagrant adds a dependency layer. | Use VBoxManage directly; no need for Vagrant abstraction. Keep the E2E tester as a simple orchestrator script, not a box builder. |
| **Multi-hypervisor support (KVM/Hyper-V/QEMU)** | Only VirtualBox is available on the test host. Adding KVM/Hyper-V drivers adds maintenance burden with zero immediate value. | Commit to VirtualBox MCP for all guest control; add hypervisor support in Phase 6+ if cross-platform testing becomes a requirement. |
| **Kernel module validation / driver signature checks** | VirtualBox EFI doesn't enforce Secure Boot (it's a hypervisor, not real firmware). Verifying kernel signatures is orthogonal to the PPSA boot chain. | Document that signed GRUB chain is verified by presence of shim/shim-signed artifacts in `/boot/efi`; kernel signature validation is post-boot and out of scope. |
| **In-guest test execution service (VirtualBox ValidationKit)** | VirtualBox ValidationKit is designed for VirtualBox developers (testing VBox itself), not guest OS validation. Guest Additions are not baked into PPSA images. | Use SSH + smoke test script; no need for guest-side agent infrastructure. |
| **Artifact re-signing / re-baking boot chain** | E2E tester runs CI artifacts as-built. Do not re-sign images or regenerate boot chains during test. | Boot chain is baked by `build-live-usb.sh` in CI; E2E tester only verifies the shipped chain, never modifies it. |
| **Real hardware boot testing** | Testing on real USB/SSD requires physical hardware + reproducibility is much harder. VirtualBox captures the boot semantics (UEFI, Secure Boot fallback, partition layout) that matter for end users. | Stick to VirtualBox local testing; real hardware validation is a user-deployment concern (Phase 7+). |

---

## Feature Dependencies

```
VM lifecycle (create, boot, reset) → Installer keystroke injection
    ↓
Installer completion detection (SSH readiness) ← depends on: NetBird enrollment in first-boot
    ↓
Boot-chain verification (query /proc/cmdline, EFI) ← depends on: SSH access
    ↓
Smoke test reuse (ppsa-smoke-test.py) ← depends on: boot verification passes
    ↓
Single invocation + aggregated summary
```

**Serial chain, no parallelism:** Each phase depends on the previous; cannot parallelize boots or run smoke tests before boot succeeds.

---

## Complexity & Scope Summary

| Phase | Feature | Complexity | Est. Effort (one person-day) | Risk |
|-------|---------|-----------|-----|------|
| 1 | VM lifecycle + scancode injection | Low | 2h | None (scripts already exist) |
| 2 | Installer completion detection | Medium | 4h | Polling timeout tuning; SSH retries on transient network |
| 3 | Boot-chain verification | Medium | 3h | EFI boot path parsing; handling signed vs unsigned gracefully |
| 4 | Smoke test integration | Low | 1h | Already a CLI script; just chain + aggregate result |
| 5 | Orchestration + error handling | Medium | 3h | Timeouts, cleanup, log aggregation, exit codes |
| **Total** | | | **~13h** | Low (all building on proven components) |

---

## MVP Recommendation

**Ship v1.5.0 with table-stakes only; defer differentiators to v1.6.0.**

### Must-Have (Phase 1–4)

1. **VM lifecycle automation** (VBoxManage, no GUI)
2. **Installer keystroke injection** (reuse blind scancode sequence from skill)
3. **Installer completion detection** (poll `/opt/ppsa/.installed` + SSH readiness)
4. **Boot-chain verification** (SSH + query EFI paths, document signed vs unsigned)
5. **Smoke test reuse** (chain `ppsa-smoke-test.py`, fold result into summary)
6. **Single invocation + summary** (orchestrator script, exit code + one-liner PASS/FAIL)

**Rationale:** These six deliverables solve the stated problem: unattended install from ISO → boot verification → smoke test → pass/fail verdict. Everything else is iteration.

### Nice-to-Have (v1.6.0+)

- Log aggregation + artifact cleanup
- Boot timeout tuning via config
- Cached Docker pulls on retry
- Health-check polling before smoke test
- Signed boot-chain screenshot capture

**Rationale:** These reduce debugging friction on subsequent runs but don't block the v1.5.0 release. Defer to next milestone when we have real test runs to optimize.

### Out of Scope (v1.5.0)

- Packer/Vagrant integration (over-engineered for single appliance)
- Preseed rewrite (scancode automation already works)
- Multi-hypervisor support (VirtualBox only)
- ValidationKit integration (no Guest Additions in images)
- Parallel matrix testing (single appliance, single test per run is fine)

---

## Technology Recommendations for Implementation

| Layer | Technology | Why |
|-------|-----------|-----|
| **VM orchestration** | VBoxManage CLI (via Bash or PowerShell) | Already works; no extra dependencies; integrates with virtualbox-mcp |
| **Installer automation** | Blind scancode injection (proven pattern) | Already in ppsa-installer-test skill; repeatable, deterministic |
| **Completion detection** | SSH polling + `/opt/ppsa/.installed` check | Text-based, reliable; no console parsing required |
| **Boot verification** | SSH queries to `/proc/cmdline`, EFI boot path checks | Offline from guest; no interactive parsing; tolerates signed/unsigned gracefully |
| **Smoke test** | Reuse `ppsa-smoke-test.py` as-is | Already returns structured exit code + summary |
| **Orchestration** | Bash or PowerShell script | Simple sequencer; ~300–400 lines; env vars for config |
| **Logging** | Append stdout to timestamped `.log` file on `H:` | Matches existing PPSA builder convention (builder.json logs → H:\dev\palimage\logs\) |

---

## Known Gotchas & Mitigations

| Gotcha | Symptom | Mitigation |
|--------|---------|-----------|
| **WSL2/Hyper-V starving VirtualBox** | First-boot Docker pull "stalls" on same layer >10 min; kernel watchdog "soft lockup" | Before test: `wsl --shutdown`; on stall: `VBoxManage controlvm <vm> reset` (idempotent first-boot) |
| **SSH not ready yet** | Connection refused after 5 min; install still pulling Docker layers | Poll for 30min with 5s backoff; tolerate transient failures; log each retry |
| **WireGuard identity theft** | Test VM boots with baked `10.8.0.2`; if real server is live, they fight for tunnel | Disable WG in test image (already default: `enabled: false`) or confirm real server is down via hub API |
| **EFI boot path varies** | Signed GRUB bakes immutable `/EFI/debian` prefix; unsigned uses different GRUB paths | Query both paths in `/proc/cmdline`; document "signed or unsigned" in boot verification step; both are valid |
| **NetBird overlay not ready** | First-boot enrollment takes 30s–2min; SSH before then fails | Poll NetBird status or overlay IP readiness before attempting SSH; wait up to 5min |
| **Docker pull timeout** | First-boot Docker stack pull hits registry DNS failure or slow network | Retry up to 3 times with exponential backoff; reboot allows `ppsa-docker-compose.service` to retry; cached layers persist |
| **Install disk full** | Partition grows to 40GB but VM disk is only 40GB total; leaves no room for Palworld server data | Test VM disk: 50GB minimum; document in script help; warn if insufficient |
| **Cleanup fails on locked VM** | Trying to unregister/delete VM while it's still stopping | Add 2s wait after `controlvm poweroff` before `unregistervm --delete` |

---

## Acceptance Criteria for v1.5.0

- [ ] Single shell/PowerShell script invocation: `./test-installer-iso.sh <iso-path> [--keep-vm]`
- [ ] Script returns exit code 0 on PASS, non-zero on FAIL
- [ ] Output: one-liner summary "PASS: all checks passed" or "FAIL: <phase> failed — see logs"
- [ ] Logs written to `H:\dev\palimage\logs\<timestamp>\test-*.log`
- [ ] VM created, booted from ISO, installer runs unattended, post-install boot succeeds
- [ ] SSH access established (ufw bootstrap or NetBird overlay, Phase 1 assumed to exist)
- [ ] Boot-chain verified (EFI paths + kernel cmdline)
- [ ] Smoke test runs and its result is folded into E2E verdict
- [ ] VM destroyed on success (or kept with `--keep-vm` flag for debugging)
- [ ] Idempotent: retrying the same test after a failure should not clash (VM name unique or cleaned up)
- [ ] Timeouts documented and tunable via env vars (e.g., `PPSA_INSTALL_TIMEOUT_MIN=45`)

---

## Sources

- [VirtualBox 6.0 Unattended Installation](https://docs.oracle.com/en/virtualization/virtualbox/6.0/user/basic-unattended.html)
- [VBoxManage unattended Reference](https://docs.oracle.com/en/virtualization/virtualbox/6.0/user/vboxmanage-unattended.html)
- [Debian Preseed Automation](https://wiki.debian.org/DebianInstaller/Preseed)
- [systemd Service Readiness Checks](https://www.man7.org/linux/man-pages/man5/systemd.service.5.html)
- [Packer Debian Image Builds](https://github.com/alvistack/vagrant-debian)
- [Debian Live-Build Automation](https://github.com/rgl/debian-live-builder-vagrant)
