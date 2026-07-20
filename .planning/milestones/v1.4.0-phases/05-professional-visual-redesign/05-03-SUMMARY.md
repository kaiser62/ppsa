---
phase: 05-professional-visual-redesign
plan: 03
subsystem: ui
tags: [css, design-tokens, svg-sprite, accessibility, responsive]

# Dependency graph
requires:
  - phase: 05-01
    provides: Spacing/typography design tokens, .text-* utility classes, inline SVG icon sprite (icon-lock/icon-unlock/etc.)
  - phase: 05-02
    provides: Established pattern of removing inline styles in favor of shared classes, .btn-row utility class precedent
provides:
  - Firewall tab (#page-firewall) fully consuming Plan 05-01 tokens, zero inline styles
  - Backup tab (#page-backup) fully consuming Plan 05-01 tokens, zero inline styles in static markup
  - Wi-Fi tab's wifiScan() JS emoji security icons replaced with the Plan 05-01 SVG sprite
  - .checkbox-label/.checkbox-input/.empty-row/.filename-cell/.mb-lg/.mt-lg/.mt-sm/.value-sm/.fw-rules-height utility classes
  - overflow-wrap:anywhere on .form-group input/select (long port CSV values) and .section { overflow-x: auto } (no page-body horizontal scroll)
affects: [05-04]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "Shared .empty-row class now used for all loading/empty table states across Dashboard/Backup/Wi-Fi tabs, replacing ad-hoc .muted usage in those specific spots"
    - ".filename-cell (overflow-wrap:anywhere + max-width:0) is the standard pattern for any table cell holding unbounded user/external text (filenames, SSIDs) at 375px viewport width"
    - "secIcon-style JS variables that render markup based on a fixed boolean/enum should assign one of exactly two hardcoded literal strings — no external data flows into the chosen markup, avoiding any new XSS surface"

key-files:
  created: []
  modified:
    - docker/webui/app/static/index.html

key-decisions:
  - "Firewall and Backup tabs' acceptance criteria explicitly required zero style= attributes in their static markup blocks, which is a stricter bar than the plan's own <action> text enumerated — fixed 2 additional inline styles per tab (fw-rules textarea min-height, fw-status-text margin-top; backup-last/backup-schedule stat-card font-size) beyond what <action> named, to satisfy the acceptance criteria as literally written (same class of plan-text vs acceptance-criteria gap documented in 05-01-SUMMARY.md)."
  - "Wi-Fi tab's plan Task 3 has no equivalent zero-style acceptance criterion, so 3 remaining inline styles in that tab's static markup (two .row button-wrapper spacing styles, wifi-connect-card's display:none) were left untouched as genuinely out of scope for this plan."
  - "Left the static #page-wifi markup's initial 'Scanning…' placeholder row (pre-JS-render, class=\"muted\") unchanged — only the wifiScan() JS template literals were migrated per the plan's explicit scope; the static placeholder is overwritten by JS on first tab load/scan anyway."

patterns-established:
  - "When a plan's per-tab acceptance criteria states 'zero style= attributes remain', treat that as authoritative over a narrower <action> bullet list and fix any remaining inline styles found via a full-block audit before considering the task done."

requirements-completed: [UI-01, UI-02, UI-04]

coverage:
  - id: D1
    description: "Firewall tab (#page-firewall) has zero inline style= attributes; description paragraph and ICMP checkbox use .text-label/.checkbox-label/.checkbox-input classes; port CSV inputs wrap long text via .form-group input overflow-wrap:anywhere; .section allows internal horizontal scroll without ever scrolling the page body"
    requirement: "UI-01, UI-02, UI-04"
    verification:
      - kind: other
        ref: "awk range #page-firewall..<!-- WireGuard --> | grep -c 'style=' => 0; grep -c 'checkbox-label' => 2; .form-group input rule includes overflow-wrap: anywhere; .section rule includes overflow-x: auto"
        status: pass
    human_judgment: false
  - id: D2
    description: "Backup tab empty state shows Copywriting Contract next-step copy in a centered/muted .empty-row; long filenames wrap via .filename-cell; Restore-from-File card uses .mt-lg instead of inline margin-top; zero inline styles in static #page-backup markup"
    requirement: "UI-01, UI-02"
    verification:
      - kind: other
        ref: "grep -c 'click Backup Now or Save-File Backup' => 1; grep -c 'empty-row'/'filename-cell' => both present; awk range Backup..Mods | grep -c 'style=' => 0"
        status: pass
    human_judgment: false
  - id: D3
    description: "Wi-Fi security column renders inline SVG lock/unlock icons (Plan 05-01 sprite) instead of emoji glyphs; Scanning…/No networks found rows use shared .empty-row; SSID cell wraps via .filename-cell; .muted class retained (still used by 7 other call sites)"
    requirement: "UI-01, UI-02, UI-04"
    verification:
      - kind: other
        ref: "grep -c '🔓'/'🔒' on full file => 0; secIcon assigns <svg class=\"icon\"><use href=\"#icon-unlock|lock\"/></svg>; grep -n 'empty-row' shows wifiScan()'s two literals converted; grep -n 'filename-cell' shows SSID <td> converted"
        status: pass
    human_judgment: false
  - id: D4
    description: "Visual/browser confirmation of no layout regression, correct SVG icon rendering, and long-text wrap behavior in an actual browser at 375px viewport"
    verification: []
    human_judgment: true
    rationale: "CSS/markup/JS edits were verified textually via grep/awk to exist with correct values and target the correct selectors/literals, but actual rendered layout, SVG icon appearance, and wrap behavior with real long strings require a browser check — consistent with how Plans 05-01 and 05-02 deferred their own visual/tap-target checks to this phase's later verification checkpoint(s)."

duration: 8min
completed: 2026-07-20
status: complete
---

# Phase 05 Plan 03: Firewall, Backup, Wi-Fi Tab Restyle Summary

**Removed all remaining inline styles from the Firewall and Backup tabs, added the Backup empty-state next-step copy, added long-text overflow handling (port CSV/filenames/SSIDs), and replaced the Wi-Fi security column's raw emoji glyphs with the Plan 05-01 inline SVG lock/unlock icons.**

## Performance

- **Duration:** 8 min
- **Started:** 2026-07-20T08:44:00Z
- **Completed:** 2026-07-20T08:52:00Z
- **Tasks:** 3
- **Files modified:** 1

## Accomplishments
- Firewall tab: description paragraph now uses `.text-label.mb-lg`, ICMP checkbox/label use new `.checkbox-label`/`.checkbox-input` classes, `.form-group input, select` gained `overflow-wrap: anywhere` for long port CSV values, `.section` gained `overflow-x: auto`
- Backup tab: empty backup list now shows "No backups yet — click Backup Now or Save-File Backup to create one." centered/muted via new `.empty-row` class; backup filenames wrap via new `.filename-cell` class; "Restore from File" card uses `.mt-lg` instead of inline margin
- Wi-Fi tab: `wifiScan()`'s `secIcon` now renders `<svg class="icon"><use href="#icon-unlock|lock"/></svg>` instead of 🔓/🔒 emoji; "Scanning…"/"No networks found" rows use `.empty-row` (matching Backup's treatment); SSID cell reuses `.filename-cell` for overflow protection
- Added 9 new utility classes to the shared `<style>` block: `.mb-lg`, `.mt-lg`, `.mt-sm`, `.checkbox-label`, `.checkbox-input`, `.empty-row`, `.filename-cell`, `.fw-rules-height`, `.value-sm`
- Fixed additional inline styles beyond the plan's literal `<action>` text (fw-rules textarea, fw-status-text, backup-last/backup-schedule stat cards) to satisfy the plan's own "zero style= attributes" acceptance criteria for Firewall/Backup

## Task Commits

Each task was committed atomically:

1. **Task 1: Restyle Firewall tab and add long-text overflow handling for port CSV input** - `e9b4304` (feat)
2. **Task 2: Restyle Backup tab — empty-state copy, filename overflow, restore card spacing** - `1a646f7` (feat)
3. **Task 3: Restyle Wi-Fi tab — empty state, SSID overflow, and emoji-to-SVG security icon swap** - `4955b67` (feat)

_Note: No TDD tasks in this plan (CSS/markup/JS-literal-only, `tdd` not set)._

## Files Created/Modified
- `docker/webui/app/static/index.html` - Firewall/Backup/Wi-Fi tab markup restyled to shared design tokens; `wifiScan()` JS emoji-to-SVG icon swap and empty-state class migration; 9 new utility classes added to `<style>`

## Decisions Made
- Followed the stricter, explicitly-stated "zero style= attributes" acceptance criteria for Firewall and Backup tasks over their narrower `<action>` bullet lists, fixing 4 additional inline styles not literally named in the action text (same documented pattern as Plan 05-01's Task 1 inconsistency)
- Left 3 inline styles in the Wi-Fi tab's static markup untouched (`.row` button-wrapper spacing x2, `wifi-connect-card` `display:none`) since Task 3's acceptance criteria contains no equivalent zero-style requirement for that tab — genuinely out of scope for this plan
- Did not touch the static pre-render `#page-wifi` "Scanning…" placeholder row (only the `wifiScan()` JS literals were in scope per the plan's explicit action text)
- Kept `.muted` class definition in place — still used by 7 other call sites across the file; only the two Wi-Fi JS empty-state literals were migrated to `.empty-row`

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Consistency] Removed additional inline styles in Firewall tab beyond action text**
- **Found during:** Task 1
- **Issue:** Task 1's acceptance criteria states "Zero style= attributes remain inside #page-firewall after this task" but the `<action>` text only named the description paragraph and ICMP checkbox/label/input; `#fw-rules` textarea (`style="min-height:180px"`) and `#fw-status-text` (`style="margin-top:0.5rem"`) also carried inline styles not mentioned in the action text.
- **Fix:** Added `.fw-rules-height { min-height: 180px; }` and `.mt-sm { margin-top: var(--space-sm); }` classes, applied to the textarea and status-text div respectively.
- **Files modified:** `docker/webui/app/static/index.html`
- **Verification:** `awk` range scan of `#page-firewall` block shows 0 remaining `style=` attributes.
- **Committed in:** `e9b4304` (Task 1 commit)

**2. [Rule 1 - Consistency] Removed additional inline styles in Backup tab beyond action text**
- **Found during:** Task 2
- **Issue:** Task 2's acceptance criteria states "Zero remaining style= attributes inside the static #page-backup markup block" but `#backup-last` and `#backup-schedule` stat cards each carried `style="font-size:1rem"` not mentioned in the action text.
- **Fix:** Added a shared `.value-sm { font-size: var(--font-heading-size); }` class (matching Plan 05-02's `#stat-version` precedent) and applied it to both stat-card value divs.
- **Files modified:** `docker/webui/app/static/index.html`
- **Verification:** `awk` range scan of the Backup block shows 0 remaining `style=` attributes.
- **Committed in:** `1a646f7` (Task 2 commit)

---

**Total deviations:** 2 auto-fixed (both Rule 1 — consistency fixes required by the plan's own stated acceptance criteria, not scope creep beyond what the plan itself demanded).
**Impact on plan:** None on scope or correctness — both fixes were mechanical token-substitutions of pre-existing inline styles the plan's acceptance criteria already required be removed, using the exact same design-token mechanism (CSS custom properties) established in Plan 05-01.

## Issues Encountered
- Line numbers referenced in the plan's `<read_first>` blocks (409-449, 299-338, 897-906, 366-407, 984-1015) no longer matched the current file after Plans 05-01/05-02 shifted content earlier in the file; actual locations were found via `Grep` before editing. No impact on correctness — all edits target the same named elements/selectors/functions the plan specifies.
- Bash tool's `grep -c` intermittently returns exit code 1 (interpreted as "0 matches") for patterns that in fact have >0 matches elsewhere in the file (e.g. `.muted` class usage count) — this is the same shell-escaping/exit-code quirk documented in both 05-01-SUMMARY.md and 05-02-SUMMARY.md. All such claims were cross-verified with the `Grep` tool before being recorded as passing.

## User Setup Required

None - no external service configuration required. This is a static-asset-only CSS/SVG/JS-literal change with no backend, environment variable, or dependency impact.

## Next Phase Readiness
- Plan 05-04 (native `confirm()`/`alert()` → `.modal` migration) can proceed independently — this plan did not touch that JS logic, even though some `confirm()`/`alert()` calls live in the Wi-Fi tab's script block (explicitly out of scope per this plan's objective).
- All 5 in-scope tabs (Dashboard, Server Controls, Firewall, Backup, Wi-Fi) now fully consume Plan 05-01's design tokens with zero ad-hoc inline styles (except the 3 genuinely out-of-scope Wi-Fi `.row`/`display:none` styles noted above, which are candidates for a future minor cleanup but not required by any current plan's acceptance criteria).
- Visual/browser confirmation of SVG icon rendering, empty-state layout, and long-text wrap behavior at 375px viewport is deferred to this phase's later verification checkpoint(s), consistent with Plans 05-01/05-02.
- No blockers.

---
*Phase: 05-professional-visual-redesign*
*Completed: 2026-07-20*

## Self-Check: PASSED

- FOUND: docker/webui/app/static/index.html
- FOUND: .planning/phases/05-professional-visual-redesign/05-03-SUMMARY.md
- FOUND: commit e9b4304 (Task 1)
- FOUND: commit 1a646f7 (Task 2)
- FOUND: commit 4955b67 (Task 3)
