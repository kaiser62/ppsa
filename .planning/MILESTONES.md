# Milestones

## v1.4.0 WebUI Professional Overhaul (Shipped: 2026-07-20)

**Phases completed:** 2 phases, 5 plans, 10 tasks

**Key accomplishments:**

- Spacing/typography CSS custom-property scale, 1px elevation border on .card/.section, inline SVG icon sprite (6 symbols), 44px touch-target media query, and unified header/login-card brand typography — all in the single `<style>` block and `<body>` of index.html.
- Removed the last two ad-hoc inline styles from the Dashboard and Server Controls tabs (#stat-version font-size, Logs button-row spacing), replacing them with shared design-system tokens/classes from Plan 05-01 and adding an overflow-wrap backstop for long version strings.
- Removed all remaining inline styles from the Firewall and Backup tabs, added the Backup empty-state next-step copy, added long-text overflow handling (port CSV/filenames/SSIDs), and replaced the Wi-Fi security column's raw emoji glyphs with the Plan 05-01 inline SVG lock/unlock icons.
- Migrated the last 7 native confirm()/alert() call sites (kick/ban/mod-remove/Wi-Fi disconnect/hotspot start-stop/firewall reset) to the existing .modal component via confirmAction(), then human-verified zero horizontal scroll and 44px touch targets at 375px/1440px across all 5 in-scope tabs — closing out Phase 5 and the v1.4.0 milestone.

---
