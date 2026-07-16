# Phase 01: Overlay Access — Summary

## Plan 01: NetBird test-peer SSH path

### Tasks Completed

1. **netbird.test.json.example** — Gitignored local config template for a dedicated test-VM NetBird setup key, isolated from the appliance's own `PPSA_NB_SETUP_KEY`/`netbird.local.json`. Schema matches `netbird.local.json.example` shape: `enabled`, `management_url`, `setup_key`.

2. **.gitignore** — Extended with `netbird.test.json` entry alongside existing `netbird.local.json` block, keeping the real (secret-bearing) config out of the public repo.

3. **docs/netbird-test-peer.md** — Full documented procedure covering:
   - One-time dashboard setup key creation (`ppsa-test-vm` in its own group)
   - Per-test-run live re-enrollment commands (console-injected sequence: netbird down → hostnamectl set-hostname → write config → restart enrollment)
   - DNS-label SSH from dev peer
   - Identity reuse rules
   - Explicit "not yet executed" placeholder in the live-verification section

### Tasks Not Executed

| Task | Status | Evidence |
|------|--------|----------|
| Checkpoint 1: Create dashboard key | Unknown (human action) | Requires interactive dashboard session at `nb.pleaseee.eu.org` |
| Task 2: Live re-enrollment against real VM | Not executed | `docs/netbird-test-peer.md` §5: "not yet executed"; `.claude/skills/ppsa-installer-test/SKILL.md` §4 has no `netbird-test-peer` reference |
| Checkpoint 2: Verify reproducibility | Not executed | Depends on Task 2 |

### Acceptance Criteria Status

| Criterion | Status | Detail |
|-----------|--------|--------|
| `netbird.test.json.example` exists with valid schema | ✅ PASS | File present, keys: `_comment`, `enabled`, `management_url`, `setup_key` |
| `.gitignore` has `netbird.test.json` entry | ✅ PASS | Line exists at `.gitignore` alongside `netbird.local.json` |
| `docs/netbird-test-peer.md` exists with hostnamectl/netbird.test.json/ppsa-test-vm strings | ✅ PASS | All required content present |
| No secrets in committed files | ✅ PASS | `git log -p` shows no key material |
| SKILL.md references `netbird-test-peer` | ❌ FAIL | `grep` returns 0 matches |
| SKILL.md console-injection bootstrap preserved | ✅ PASS | `use_console_injection` present |
| Live SSH-over-NetBird verified | ❌ NOT RUN | Section 5 placeholder not filled |

### Artifacts

- `netbird.test.json.example` — Template for test-peer NetBird config
- `.gitignore` — Gitignore entry for secret-bearing config
- `docs/netbird-test-peer.md` — Full enrollment and SSH procedure doc

### Threat Model Status

| ID | Threat | Severity | Mitigation | Status |
|----|--------|----------|------------|--------|
| T-01-01 | Secret leak via git | High | `.gitignore` + acceptance grep for secret-shaped strings | SECURED |
| T-01-02 | Identity collision | Medium | Fixed hostname per VM + dedicated setup key in isolated group | SECURED (by design) |
| T-01-03 | Console injection EoP | Low | Accepted — pre-existing sanctioned mechanism | ACCEPTED |
| T-01-04 | WG_FRIENDS tampering | Low | Zero firewall changes in this phase | ACCEPTED |

### Notes

The broader "Promote NetBird to mainline" work (build-script gating, first-boot reordering, firewall, branch promotion, docs) was completed in commit `03a4a2a` and subsequent fix commits. This was tracked separately from the Phase 01 plan; the Phase 01 plan focused specifically on the persistent test-peer identity and SSH-over-NetBird procedure.

Live Task 2 execution requires:
1. A human to create the `ppsa-test-vm` reusable setup key on the NetBird dashboard
2. A CI-built test VM booted in VirtualBox
3. Console-injecting the re-enrollment procedure
4. Confirming SSH-by-DNS-label works from a dev peer
