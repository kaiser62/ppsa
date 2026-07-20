# Milestones

## v1.5.0 Installer-ISO E2E Tester (Shipped: 2026-07-20)

**Phases completed:** 3 phases, 5 plans, 10 tasks

**Key accomplishments:**

- New stdlib-only `scripts/ppsa-installer-e2e.py` orchestrator: a VBoxManage-subprocess VM lifecycle (create/attach/boot/state/destroy) gated by a credential-driven, fail-safe pre-boot WireGuard identity collision check against the production wg-easy hub.
- Completed `scripts/ppsa-installer-e2e.py` with blind scancode installer-TUI automation, SSH-polled `/opt/ppsa/.installed` completion detection with distinguishable timeout reasons, and a single-invocation `run()` pipeline producing one PASS/FAIL/ERROR exit code.
- Additive `mark_step_activity()` heartbeat helper in `scripts/install.sh`, writing a world-readable Unix-timestamp to `/run/ppsa-install.activity` at 5 call sites inside Step 3's Docker pull/up loops, giving Plan 07-02's SSH poller a real signal to distinguish a slow install from a genuine hang.
- Extended `scripts/ppsa-installer-e2e.py` with `verify_boot_chain()` (post-boot SSH classification of signed shim/GRUB vs. unsigned fallback) and heartbeat-aware hang detection in `wait_for_install_complete()`, wired into `run()`'s existing ordered-results pipeline with a FAIL-only `overall_pass` computation.
- Extended `scripts/ppsa-installer-e2e.py` with a `run_smoke_test()` subprocess wrapper around `scripts/ppsa-smoke-test.py`, wired as a final pipeline stage into `run()`'s existing ordered-results list, plus a `[SUMMARY]` one-line verdict that names the first failing stage without requiring a re-run.

---

## v1.4.0 WebUI Professional Overhaul (Shipped: 2026-07-20)

**Phases completed:** 2 phases, 5 plans, 10 tasks

**Key accomplishments:**

- Spacing/typography CSS custom-property scale, 1px elevation border on .card/.section, inline SVG icon sprite (6 symbols), 44px touch-target media query, and unified header/login-card brand typography — all in the single `<style>` block and `<body>` of index.html.
- Removed the last two ad-hoc inline styles from the Dashboard and Server Controls tabs (#stat-version font-size, Logs button-row spacing), replacing them with shared design-system tokens/classes from Plan 05-01 and adding an overflow-wrap backstop for long version strings.
- Removed all remaining inline styles from the Firewall and Backup tabs, added the Backup empty-state next-step copy, added long-text overflow handling (port CSV/filenames/SSIDs), and replaced the Wi-Fi security column's raw emoji glyphs with the Plan 05-01 inline SVG lock/unlock icons.
- Migrated the last 7 native confirm()/alert() call sites (kick/ban/mod-remove/Wi-Fi disconnect/hotspot start-stop/firewall reset) to the existing .modal component via confirmAction(), then human-verified zero horizontal scroll and 44px touch targets at 375px/1440px across all 5 in-scope tabs — closing out Phase 5 and the v1.4.0 milestone.

---
