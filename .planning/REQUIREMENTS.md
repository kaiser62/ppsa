# Requirements: PPSA — WebUI Professional Overhaul (v1.4.0)

**Defined:** 2026-07-19
**Core Value:** A user can boot the appliance, and their friends can reach a working Palworld server over the private overlay network — every build must preserve that end-to-end path.

> Scope note: PPSA's appliance + build-verification capabilities are already
> Validated (see `.planning/PROJECT.md`). This milestone targets the management
> WebUI: make it look professional and intentional, and fix the dashboard
> correctness bugs — all without changing the FastAPI + no-build architecture or
> the NetBird-only port exposure.

## Architecture invariants (do not violate)

- Single FastAPI app (`docker/webui/app/main.py`) serves both `/api/*` and static frontend.
- Frontend is plain JS/CSS/HTML at `docker/webui/app/static/` — **no framework, no build step**.
- `webui/frontend/` is orphaned — do not touch.
- Frontend is baked into the image by `scripts/build-live-usb.sh`.
- WebUI/game ports stay NetBird-only (`100.64.0.0/10` via `WG_FRIENDS`); no LAN exposure.

## v1 Requirements

### Visual Redesign

- [ ] **UI-01**: The WebUI presents a cohesive, intentional visual design (typography, color, spacing, components) that does not read as a templated default, applied consistently across all tabs
- [ ] **UI-02**: The dashboard, server controls, firewall, backup, and Wi-Fi tabs share one design system (shared CSS variables/components) rather than ad-hoc per-tab styling
- [ ] **UI-03**: The redesigned UI remains a single static bundle with no framework and no build step, served by the existing FastAPI app
- [ ] **UI-04**: The UI is responsive/usable on a typical laptop and phone browser (the onboarding and friend-facing case)

### Dashboard Correctness

- [ ] **DASH-01**: The dashboard displays the running Palworld game server version correctly (sourced reliably even when the REST API returns an empty version field)
- [ ] **DASH-02**: On fresh boot, while the server is still initializing, the dashboard shows a clear "server starting" / initializing state instead of blank fields or zeros
- [ ] **DASH-03**: Empty or not-yet-available metrics and player data render as explicit empty states, not silently blank

### Error Handling

- [ ] **DASH-04**: Dashboard and status endpoints degrade gracefully on upstream/transient failures — the page stays usable and shows a clear status banner rather than breaking
- [ ] **DASH-05**: Frontend surfaces API/network errors to the user with actionable messaging instead of failing silently or showing raw errors

## v2 Requirements

Deferred — acknowledged but not in this milestone.

- **UI-V2-01**: Live-updating dashboard via websockets/SSE (currently poll-based)
- **UI-V2-02**: Theming / light-dark toggle

## Out of Scope

| Feature | Reason |
|---------|--------|
| Introducing a JS framework or build step (React/Vue/bundlers) | Architecture invariant: plain static, baked into image |
| Opening WebUI ports to LAN | Appliance is NetBird-only by design |
| Backend behavior changes beyond what the bugfixes require | Milestone is UI + dashboard correctness, not a backend rewrite |
| New appliance/game features | PPSA packages the community server image unchanged |
| Editing `webui/frontend/` | Orphaned copy, not the live code |

## Traceability

| Requirement | Phase | Status |
|-------------|-------|--------|
| UI-01 | TBD | Pending |
| UI-02 | TBD | Pending |
| UI-03 | TBD | Pending |
| UI-04 | TBD | Pending |
| DASH-01 | TBD | Pending |
| DASH-02 | TBD | Pending |
| DASH-03 | TBD | Pending |
| DASH-04 | TBD | Pending |
| DASH-05 | TBD | Pending |

**Coverage:**

- v1 requirements: 9 total
- Mapped to phases: filled by roadmap
