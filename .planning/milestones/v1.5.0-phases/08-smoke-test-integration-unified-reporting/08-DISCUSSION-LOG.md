# Phase 8: Smoke-Test Integration & Unified Reporting - Discussion Log

**Date:** 2026-07-20

## Areas Discussed

### Invocation mechanism
- **Options presented:** Subprocess (Recommended) vs Direct import
- **Selected:** Subprocess (Recommended)
- **Notes:** Avoids coupling to `SmokeTestRunner` internals; matches existing `run_vboxmanage()` subprocess pattern.

### Raw-output log location
- **Options presented:** Fixed path, overwritten (Recommended) vs Timestamped per run
- **Selected:** Fixed path, overwritten (Recommended)
- **Notes:** Each invocation is a disposable manual test run — no retention policy needed.

### CLI surface changes
- **Options presented:** Minimal flags (`--skip-smoke-test`, `--log-file`) (Recommended) vs No new flags
- **Selected:** Minimal flags (Recommended)
- **Notes:** Smoke-test script path itself stays hardcoded (sibling script, fixed location), not a flag.

## Areas Not Discussed (Claude's Discretion)

- **One-line summary format** — user deferred to implementation. Constrained by ROADMAP.md success criteria (exit 0/1, failed-stage must be identifiable) and Phase 7's established results-list shape.

## Deferred Ideas

None — discussion stayed within phase scope.

---

*Discussion completed: 2026-07-20*
