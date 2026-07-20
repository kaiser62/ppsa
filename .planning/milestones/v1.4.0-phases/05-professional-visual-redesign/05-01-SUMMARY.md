---
phase: 05-professional-visual-redesign
plan: 01
subsystem: ui
tags: [css, design-tokens, svg-sprite, accessibility, responsive]

# Dependency graph
requires: []
provides:
  - Spacing scale (--space-xs..--space-3xl) and typography scale (--font-body/label/heading/display) as CSS custom properties in :root
  - .text-body/.text-label/.text-heading/.text-display utility classes
  - .card and .section elevation cue (1px --surface2 border) distinguishing them from page background
  - Inline SVG icon sprite (<symbol> defs for lock, unlock, wifi-signal, check, warning, refresh) at top of <body>
  - .icon utility class (16x16, currentColor fill) for consuming sprite icons via <use>
  - 44px minimum tap-height media query for .nav button/button/.btn at <=768px
  - Shared display-scale brand typography for header h1 and .login-card h1 (PPSA wordmark)
affects: [05-02, 05-03, 05-04]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "CSS custom-property design tokens (spacing + typography) declared once in :root, consumed by component selectors in the same <style> block"
    - "Inline SVG <symbol>/<use> sprite pattern for icons instead of icon fonts or per-instance inline SVGs"

key-files:
  created: []
  modified:
    - docker/webui/app/static/index.html

key-decisions:
  - "Kept .section padding on --space-lg (24px) and .card/.grid on --space-md (16px) exactly as the plan's Task 1 action specified, rather than forcing --space-md onto .section to hit the overall verification step's '>=4 occurrences' note — see Deviations."
  - "Elevation cue implemented as a flat 1px border in var(--surface2), not a box-shadow, per the plan's explicit instruction to avoid a heavier redesign than specified."

patterns-established:
  - "New tab-specific markup (Plans 05-02/03/04) must reuse .text-label/.text-heading/.text-display and the var(--space-*) tokens instead of introducing new inline font-size/margin overrides."
  - "Any future icon need beyond the 6 already defined (lock, unlock, wifi-signal, check, warning, refresh) should add a new <symbol> to the existing sprite, not a new inline SVG or icon font."

requirements-completed: [UI-01, UI-02, UI-03, UI-04]

coverage:
  - id: D1
    description: "Spacing (7 tokens) and typography (4 size + 2 weight tokens) design system declared in :root and consumed by .card, .section, .grid, .card h3, .card .value, .section h2"
    requirement: "UI-02"
    verification:
      - kind: other
        ref: "grep -c -- '--space-md: 16px' docker/webui/app/static/index.html => 1; grep -oE 'id=\"icon-[a-z-]+\"' => 6 distinct ids"
        status: pass
    human_judgment: false
  - id: D2
    description: "Inline SVG icon sprite (6 symbols) added once at top of <body>, no external icon font/CDN"
    requirement: "UI-01"
    verification:
      - kind: other
        ref: "Grep tool -o 'id=\"icon-[a-z-]+\"' on index.html returns exactly 6 distinct ids: lock, unlock, wifi-signal, check, warning, refresh"
        status: pass
    human_judgment: false
  - id: D3
    description: "Touch targets: .nav button, button, .btn reach 44px min-height at <=768px via media query; header h1 and .login-card h1 share identical display-scale brand typography"
    requirement: "UI-04, UI-03"
    verification:
      - kind: manual_procedural
        ref: "Requires opening index.html in a browser at <=768px viewport and inspecting computed heights / visual brand consistency — not verified via automated tooling in this run"
        status: unknown
    human_judgment: true
    rationale: "No browser/devtools automation was run in this execution; CSS rules were verified textually (grep) to exist with correct values, but actual rendered tap-height and visual brand match require a human/visual check, which is explicitly the job of this phase's later verification checkpoint(s)."

duration: 3min
completed: 2026-07-20
status: complete
---

# Phase 05 Plan 01: Design System Foundation Summary

**Spacing/typography CSS custom-property scale, 1px elevation border on .card/.section, inline SVG icon sprite (6 symbols), 44px touch-target media query, and unified header/login-card brand typography — all in the single `<style>` block and `<body>` of index.html.**

## Performance

- **Duration:** 3 min
- **Started:** 2026-07-20T08:36:12Z
- **Completed:** 2026-07-20T08:38:41Z
- **Tasks:** 2
- **Files modified:** 1

## Accomplishments
- Added 7 spacing tokens (`--space-xs` through `--space-3xl`) and 4 typography size tokens plus 2 weight tokens to `:root`, plus 4 new `.text-*` utility classes
- `.card` and `.section` now consume `var(--space-md)`/`var(--space-lg)` padding and gained a `1px solid var(--surface2)` border as an elevation cue vs. the page background
- Added a 6-symbol inline SVG icon sprite (`icon-lock`, `icon-unlock`, `icon-wifi-signal`, `icon-check`, `icon-warning`, `icon-refresh`) directly after `<body>`, plus a `.icon` utility class
- Fixed touch targets: `.nav button` padding bumped to `12px 16px`, and a `@media (max-width: 768px)` rule enforces `min-height: 44px` on `.nav button`, `button`, and `.btn`
- Unified brand typography: `header h1` and `.login-card h1` both now use `var(--font-display-size)` / `var(--font-weight-semibold)` so the PPSA wordmark reads identically on the login screen and in the app shell

## Task Commits

Each task was committed atomically:

1. **Task 1: Add spacing + typography token scale and elevation cue to :root and shared components** - `e7dc023` (feat)
2. **Task 2: Fix touch targets, add SVG icon sprite, and unify header/login brand treatment** - `0562053` (feat)

**Plan metadata:** committed in this docs commit alongside STATE.md/ROADMAP.md updates

_Note: No TDD tasks in this plan (CSS/markup-only, `tdd` not set)._

## Files Created/Modified
- `docker/webui/app/static/index.html` - Added design tokens (:root), utility classes, elevation borders on .card/.section, icon sprite in <body>, 44px touch-target media query, unified header/login-card h1 typography

## Decisions Made
- Elevation cue implemented as a flat `1px solid var(--surface2)` border (not box-shadow) per the plan's explicit instruction to avoid a heavier redesign than specified in UI-SPEC.md
- `.section` padding kept on `--space-lg` (24px) and `.card`/`.grid` kept on `--space-md` (16px) exactly as Task 1's action text specified — see Deviations below for the resulting discrepancy with the plan's own overall-verification note

## Deviations from Plan

### Auto-fixed Issues

None — no bugs, missing critical functionality, or blocking issues were encountered. Both tasks were implemented as literally specified in their `<action>` blocks.

### Noted Plan Inconsistency (not auto-fixed, documented only)

The plan's `<verification>` section step 3 states: `grep -c "space-md" docker/webui/app/static/index.html` should return `>= 4 (declared + at least 3 consumers: .card, .section, .grid)`. However, Task 1's own `<action>` text explicitly assigns `.section` to `var(--space-lg)`, not `var(--space-md)` — only `.card` and `.grid` consume `--space-md`. The actual count is 3 (1 declaration + 2 consumers: `.card`, `.grid`), not 4. This is an internal inconsistency in the plan document itself (the overall verification step's parenthetical miscounts which selector uses which token), not a defect in the implementation. I followed the more specific, authoritative Task 1 `<action>` instructions (which correctly separate `--space-md` for card-level spacing from `--space-lg` for section-level spacing, matching UI-SPEC.md's Spacing Scale table) rather than forcing `.section` onto `--space-md` just to satisfy the verification step's count. All of Task 1's own `<acceptance_criteria>` pass exactly as written.

---

**Total deviations:** 0 auto-fixed. 1 documented plan-text inconsistency (verification step miscounted expected token consumers vs. the task's own action text; implementation follows the more specific and UI-SPEC-aligned instruction).
**Impact on plan:** None on scope or correctness — `.section` correctly uses the larger `--space-lg` per UI-SPEC's Spacing Scale table ("lg: Section padding"), consistent with Task 1's explicit action text.

## Issues Encountered
- The Bash tool's `grep -c`/`grep -oE` calls intermittently returned exit code 1 / empty output for patterns containing `</style>`, `</svg>`, or `id="icon-...")` character classes, despite the content existing correctly in the file (confirmed via the Grep tool and `sed -n`). This appears to be a shell-escaping quirk of the Bash tool in this environment, not a file defect — all claims in this summary were cross-verified with the Grep tool and line-numbered `sed`/sed-based reads before being recorded as passing.

## User Setup Required

None - no external service configuration required. This is a static-asset-only CSS/SVG change with no backend, environment variable, or dependency impact.

## Next Phase Readiness
- Plans 05-02, 05-03, 05-04 can now consume `.text-label`/`.text-heading`/`.text-display`, the `var(--space-*)` tokens, and the icon sprite (`<svg class="icon"><use href="#icon-lock"/></svg>`) when restyling Dashboard/Controls/Firewall/Backup/Wi-Fi tab markup
- No blockers. Visual/tap-target verification at <=768px viewport width is deferred to this phase's later checkpoint(s) (browser-based, not yet performed in this plan)

---
*Phase: 05-professional-visual-redesign*
*Completed: 2026-07-20*

## Self-Check: PASSED

- FOUND: docker/webui/app/static/index.html
- FOUND: .planning/phases/05-professional-visual-redesign/05-01-SUMMARY.md
- FOUND: commit e7dc023 (Task 1)
- FOUND: commit 0562053 (Task 2)
