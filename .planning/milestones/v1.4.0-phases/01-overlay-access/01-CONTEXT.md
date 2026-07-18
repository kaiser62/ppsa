# Phase 1: Overlay Access — Context

**Phase:** 1 — Overlay Access
**Requirements:** NET-01, NET-02, NET-03
**Source:** Inline decision capture (research disabled; key design decisions locked with the user)

## Domain

Make a freshly installed PPSA test VM reachable over SSH from a designated NetBird
dev peer, at a **stable address that survives rebuilds**, with **no console-injected
ufw/LAN exception** — replacing the current blind VBox scancode + screenshot test
entry path. This is the access foundation Phase 2's scripted smoke test runs against.

The appliance already enrolls in NetBird at first boot and SSH `:22` is already
gated through the `WG_FRIENDS` iptables chain from the NetBird subnet
`100.64.0.0/10` (see `scripts/ppsa-firewall-apply.sh`, CLAUDE.md firewall section).
So an SSH-first path needs no firewall change on the appliance — the plumbing exists;
this phase proves and documents it, and solves address stability.

## Locked Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Stable address across rebuilds | **Stable NetBird DNS name**, not a pinned IP | Each fresh install enrolls as a NEW peer with a new `100.x` IP. Set a fixed hostname on the test VM (e.g. `ppsa-test`) so NetBird auto-assigns a stable DNS label; SSH to the name. Survives IP churn with NO identity reuse (avoids the WG `10.8.0.2` shared-identity hazard). |
| Test peer setup key | **Dedicated reusable test key, local-only** | A separate reusable NetBird setup key used only for test VMs, kept OUT of the public `kaiser62/ppsa` repo (env var / local file / memory). Isolated from the appliance's CI `PPSA_NB_SETUP_KEY`. |
| Firewall for SSH | **Use existing `WG_FRIENDS` chain (no new rule)** | `:22` is already reachable from `100.64.0.0/10`; do NOT add LAN exceptions — appliance stays NetBird-only by design. |

## Canonical References

- `scripts/ppsa-firewall-apply.sh` — `WG_FRIENDS` chain, NetBird `100.64.0.0/10` jump
- `scripts/install.sh` — first-boot NetBird enrollment step
- `scripts/ppsa-wireguard-register.sh` / NetBird enroll block — where hostname/enroll happens
- `CLAUDE.md` — firewall + NetBird sections; self-hosted control plane `nb.pleaseee.eu.org`
- `.claude/skills/ppsa-installer-test/SKILL.md` — current (token-heavy) test recipe this phase replaces the access portion of
- `.planning/codebase/ARCHITECTURE.md`, `STRUCTURE.md` — appliance layout

## Claude's Discretion

- Exact mechanism to set the test VM's hostname (installer prompt vs post-install
  one-liner vs a documented manual step) — pick the lowest-friction that yields a
  stable NetBird DNS label.
- Whether the stable hostname is set on the appliance image generally or only on
  test VMs — must NOT change shipped appliance behavior for real users unless it's
  a strict improvement (a per-install hostname is fine; a hardcoded shared hostname
  is NOT — that re-creates identity collision).
- Where/how the local-only test key and the dev-peer identity are documented for a
  future session (candidate: a project skill or a `docs/` note, secrets excluded).

## Scope Fence

**In scope:** SSH reachability to a fresh test VM over NetBird at a stable DNS name;
dedicated local-only test key; repeatable, documented enrollment procedure (NET-03).

**Out of scope:** The smoke-test script itself (Phase 2 / TEST-01..04); any change
that opens appliance ports to the LAN; removing/altering the VBox boot path; touching
the WireGuard dormant stack; CI-based booting (v2 / CI-01).

## Success Criteria (from ROADMAP)

1. SSH from the designated NetBird dev peer to a freshly installed test VM's overlay
   address succeeds with no console-injected ufw/LAN exception.
2. The test VM is reachable at the same **stable NetBird DNS name** across rebuilds
   and reboots (IP may change; the name must not).
3. A written procedure lets a future session reproduce test-peer enrollment +
   stable-name setup without rediscovery, secrets excluded.

## Risk Summary

- **Identity collision** — reusing a baked peer key/hostname across VMs re-creates the
  WG `10.8.0.2` theft problem. Mitigation: per-install identity; stable *name* via
  NetBird's DNS label, not a shared baked key.
- **Self-hosted NetBird DNS behavior** — confirm the self-hosted control plane at
  `nb.pleaseee.eu.org` actually serves per-peer DNS labels resolvable from the dev
  peer (NetBird DNS management enabled). Verify before relying on the name.
- **Secret leak** — the test setup key must never land in the public repo.
