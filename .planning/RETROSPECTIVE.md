# Project Retrospective

*A living document updated after each milestone. Lessons feed forward into future planning.*

## Milestone: v1.4.0 — WebUI Professional Overhaul

**Shipped:** 2026-07-20
**Phases:** 2 | **Plans:** 5 | **Sessions:** 1 (spanning a compaction boundary)

### What Was Built
- Phase 4 — durable game-version detection (REST → container-log parse → last-known-good cache), honest fresh-boot server states, `players_known` signal, bounded concurrent upstream fetch, graceful `/api/system` degradation, actionable frontend error banners
- Phase 5 — full design-system foundation (8-pt spacing scale, 4-tier typography, 1px card/section elevation, inline SVG icon sprite replacing emoji), all 5 tabs (Dashboard/Controls/Firewall/Backup/Wi-Fi) restyled off shared tokens with zero inline styles remaining, all native `confirm()`/`alert()` calls migrated to a styled `.modal` component, responsive layout verified at 375px/1440px with 44px touch targets

### What Worked
- Splitting Phase 5 into a design-system-foundation plan (05-01) first, then three apply-the-system plans (05-02/03/04) — every later plan just consumed already-built tokens/classes instead of re-deriving spacing/typography ad hoc
- UI-SPEC design contract (via `/gsd-ui-phase`) caught two documentation gaps (missing focal point, unformalized 60/30/10 metric) before planning — both fixed with small direct edits instead of a costly researcher re-spawn
- The `checkpoint:human-verify` gate on the last plan correctly refused to let the executor self-certify a responsive layout it couldn't render — the orchestrator drove real browser preview tooling (resize to 375px/1440px, `getBoundingClientRect`, live modal trigger) before approving

### What Was Inefficient
- `Agent(isolation="worktree")` forked from the repo's default branch (`master`, via `origin/HEAD`) instead of the checked-out branch (`netbird`), causing a base-mismatch halt on the very first executor dispatch. Cost one wasted agent spawn (~64K tokens) before switching every remaining plan in the phase to sequential execution on the main tree — which was the right call anyway since all 4 plans touch the same single file and gain nothing from worktree parallelism
- One executor was stopped mid-run by direct user interruption and had to be fully relaunched from scratch (no partial credit — async agent cancellation discards all work, not just checkpointable state)

### Patterns Established
- For phases where every plan modifies the same single file, skip worktree isolation entirely and dispatch executors sequentially on the main checkout — no parallelism is lost and the worktree-base-mismatch bug is avoided outright
- Human-verify checkpoints for responsive/visual work should be resolved by the orchestrator directly driving browser preview tools (resize, eval, screenshot, inspect) rather than asking the user to do it manually or trusting a text-only executor's self-report

### Key Lessons
1. Before spawning `isolation="worktree"` executors, confirm the worktree harness will actually fork from the currently-checked-out branch, not the remote's default branch — repos with a frozen/archived long-lived branch (this repo's `master`) are exposed to this the same way a fresh clone would be
2. A phase whose plans all list the same file in `files_modified` gets zero benefit from worktree parallelism; sequential mode is strictly safer and no slower in wall-clock terms since the plans would serialize anyway

### Cost Observations
- Model mix: 0% opus, ~80% sonnet (executors + this orchestrator), ~20% haiku (verifier)
- Sessions: 1 (continued across a context-compaction boundary)
- Notable: verifier running on `haiku` for a goal-backward pass over 4 SUMMARY.md files + a live index.html diff was sufficient — no escalation to a stronger model needed since the orchestrator had already performed the one part (browser rendering) no text-only model can self-verify

---

## Cross-Milestone Trends

### Process Evolution

| Milestone | Sessions | Phases | Key Change |
|-----------|----------|--------|------------|
| v1.4.0 | 1 | 2 | First milestone run through the full GSD execute-phase wave pipeline in this project; first `/gsd-ui-phase` design-contract gate; first worktree-isolation base-mismatch encountered and worked around |

### Cumulative Quality

| Milestone | Tests | Coverage | Zero-Dep Additions |
|-----------|-------|----------|-------------------|
| v1.4.0 | 0 (no test suite for WebUI backend; verified via live browser + grep-based acceptance criteria) | N/A | 0 (no new dependencies — plain CSS/JS/SVG only) |

### Top Lessons (Verified Across Milestones)

1. Sequential execution on the main tree is the safer default whenever a phase's plans all touch one shared file — worktree isolation adds risk (branch-base mismatches) without adding real parallelism in that case
