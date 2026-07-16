# Codebase Concerns

**Analysis Date:** 2026-07-16

## Tech Debt

### Orphaned WebUI Frontend Code

**Issue:** Legacy frontend code exists but is unmaintained and unused.

**Files:** `docker/webui/frontend/` (entire directory — last touched at initial commit)

**Impact:** Confusion for developers; directory appears active but is not referenced by any Dockerfile, compose file, or build pipeline. The real frontend is plain JavaScript in `docker/webui/app/static/index.html`.

**Fix approach:** Delete the orphaned `docker/webui/frontend/` directory and document in CLAUDE.md that static assets live in `docker/webui/app/static/` only.

---

### Direct subprocess with shell=True in NetBird Key Generation

**Issue:** NetBird peer credential generation uses `subprocess.run()` with `shell=True`, which is a security anti-pattern even though the command string itself is not user-controlled.

**Files:** `docker/webui/app/main.py` (lines 1002, 1007)

**Impact:** While the current commands (`wg genkey | wg pubkey`) are safe (piped system binaries, not interpolating user input), shell injection risk increases with any future changes. Code review overhead on this path is higher than it needs to be.

**Fix approach:** Replace shell=True pipelines with Python subprocess chains:
```python
# Instead of: shell=True with "wg genkey | wg pubkey"
priv = subprocess.check_output(["wg", "genkey"], text=True).strip()
pub = subprocess.check_output(["wg", "pubkey"], input=priv, text=True).strip()
```

---

### Manual Exception Catching in docker SDK Error Handling

**Issue:** The `_run_docker()` helper (lines 236-239 in main.py) has duplicate exception handlers (`except Exception` twice).

**Files:** `docker/webui/app/main.py` (lines 236-239)

**Impact:** Second exception handler is unreachable; errors in the docker SDK calls might not be properly categorized.

**Fix approach:** Remove the duplicate handler block and ensure all docker SDK exceptions are caught once with a single handler that logs and returns an error message.

---

### No Test Suite for WebUI Backend

**Issue:** The PPSA WebUI backend (FastAPI + Python) has zero automated tests.

**Files:** `docker/webui/app/main.py` (1341 lines of unverified code)

**Impact:** Changes to auth, backup, firewall, or WireGuard management are not regression-tested before deployment. Recent bugs like "Save World returns 500 on empty body" (commit 63a818f) and "Backup freezes UI" (same commit) would have been caught by integration tests.

**Fix approach:**
- Create `tests/test_webui_*.py` using pytest + FastAPI TestClient
- Cover critical paths: auth (login/password change), backup/restore, firewall config, WireGuard status
- Run in CI via GitHub Actions (currently no test stage in build-release.yml)
- Minimum target: auth + backup endpoints (the two areas with recent data-loss bugs)

---

## Known Bugs (Recently Fixed but Worth Monitoring)

### Save World and Backup Endpoints Return Empty 200s

**Status:** FIXED (commit 63a818f)

**Symptoms:** Save World returns 200 with empty body; previous code tried `resp.json()` and raised JSONDecodeError → 500.

**Files:** `docker/webui/app/main.py` (palworld_post function, lines 288-299)

**Current mitigation:** Lines 294-299 now check for empty response body and return `{"status": "ok"}` instead of raising.

**Risk:** If Palworld API behavior changes (unlikely), or if other endpoints start returning unusual 200s, similar bugs could reappear without test coverage to catch them.

---

### Backup Freezes WebUI When Run Synchronously

**Status:** FIXED (commit 63a818f)

**Symptoms:** Calling `/api/backup/trigger` without `--detach` blocked uvicorn's event loop for the entire backup duration (minutes for multi-GB tar+gzip), freezing the UI for all users.

**Files:** `docker/webui/app/main.py` (lines 221-233 in _run_docker)

**Current mitigation:** Added `--detach` flag support to container.exec_run(); backup now runs in background and endpoint returns immediately.

**Risk:** Future long-running operations (large mod uploads, system reconfigurations) could fall into the same trap without explicit detach awareness.

---

### Backups Never Completed (Hot Tar Race)

**Status:** FIXED (underlying cause in backup container, not visible in this repo)

**Symptoms:** Backups were created but never marked "completed"; tar was running on live palworld-data volume while game was still writing.

**Files:** Not directly in this repo; root cause was in offen/docker-volume-backup behavior.

**Current mitigation:** Backup process now properly serializes around game pause/save.

**Risk:** If backup cron schedule is changed or the backup container is rebuilt, race conditions could resurface without integration tests.

---

## Security Considerations

### Default Credentials Widely Advertised

**Issue:** PPSA ships with well-known default credentials (admin/admin, ppsa/ppsa, artho/arthoroy).

**Files:** `README.md` (lines 128-134), `docker/webui/app/main.py` (line 66 — "admin" user auto-created)

**Current mitigation:** README prominently warns "**change immediately!**"; CLAUDE.md notes these in a table.

**Recommendation:** 
- First-boot setup should force a password change before any game container starts (currently optional)
- Add a "first_run" flag in users.json to block API calls until password is changed
- Send a warning banner to the Web UI if admin password is still "admin"

---

### JWT Secret Hardcoded Default

**Issue:** `JWT_SECRET` defaults to `"ppsa-insecure-change-me"` if `JWT_SECRET` env var is not set.

**Files:** `docker/webui/app/main.py` (line 47)

**Impact:** If the Docker Compose setup doesn't provide a real secret (via .env), tokens are signed with a known default, allowing token forgery.

**Current mitigation:** Docker Compose should inject a random secret at build/deploy time (verify in `compose/docker-compose.yml`).

**Recommendation:**
- Fail fast at container startup if JWT_SECRET is still the default (don't silently accept it)
- Generate a random 32-byte secret on first boot and persist it to /opt/ppsa/.env if not already set

---

### WebUI Container Shell Access via nsenter

**Issue:** WebUI endpoints use `nsenter` + `chroot` to execute commands on the host (for Wi-Fi config, firewall rules).

**Files:** `docker/webui/app/main.py` (many _host_exec calls throughout)

**Current mitigation:** WebUI container runs with read-only `/host` bind mount; nsenter can only read or trigger systemd units, not arbitrary shell commands.

**Risk:** Any command injection in the parameters passed to _host_exec (e.g., from user-controlled Wi-Fi SSID or firewall port input) could escalate to host root.

**Recommendation:**
- Audit all _host_exec call sites for unsanitized user input
- Use allowlist-based command templates instead of string interpolation
- Example: firewall port updates should be validated against a hardcoded port range regex before being written to firewall.json

---

## Performance Bottlenecks

### Synchronous Palworld API Calls in Event Loop

**Issue:** `palworld_get()` and `palworld_post()` make httpx calls but don't use async context properly in all code paths.

**Files:** `docker/webui/app/main.py` (lines 247-300)

**Impact:** Dashboard endpoint aggregates multiple Palworld API calls sequentially. If any call times out, the whole dashboard times out. With 5s per call and 3+ calls, dashboard can be slow to render.

**Fix approach:**
- Parallelize calls: `asyncio.gather(*[palworld_get("/info"), palworld_get("/players"), ...])`
- Cache dashboard results for 10-30s (game state doesn't change per-second)
- Return stale cache on transient upstream failure instead of blocking

---

### WireGuard/Firewall Apply Operations Block on File Polling

**Issue:** `_wg_apply()` and `_fw_trigger_apply()` poll result files in a busy-loop (0.5s sleep intervals).

**Files:** `docker/webui/app/main.py` (lines 691, 1224-1239)

**Impact:** If host-side systemd unit stalls, endpoint blocks for 15-10s before timing out. Multiple concurrent firewall changes can queue and delay.

**Fix approach:**
- Replace polling with inotify-based event notification (Python's watchdog module)
- Alternatively, add a completion signal file that host-side scripts write with a UUID matching the request

---

## Fragile Areas

### Build Script Partition Handling

**Files:** `scripts/build-live-usb.sh` (lines 85-100)

**Why fragile:** Partition node creation has multiple fallback paths (partprobe, partx, sleep). On some systems, losetup partition nodes don't appear at all without modprobe (loop module might not be loaded).

**Safe modification:**
- Test partition node creation before using it; skip if it fails
- Use `losetup -n` to list partitions first, then verify node exists before mounting
- Add logging at each fallback point so failures are debuggable

---

### DNS Resolution Order in Chroot Build

**Files:** `scripts/build-live-usb.sh` (resolved in commit 3e30b8f via systemd-resolved)

**Why fragile:** Previous versions baked a static resolv.conf with public-only DNS into the image. On DNS-restrictive networks (corporate, ISP), this breaks Palworld and NetBird connectivity.

**Monitoring:** If DNS issues resurface in user reports, check whether systemd-resolved is starting correctly in the chroot.

---

### WireGuard Dormancy on Disabled Builds

**Files:** `scripts/ppsa-wireguard-register.sh`, `scripts/install.sh`

**Why fragile:** When `PPSA_WG_ENABLED=false`, wg0.conf must be absent AND the wg-quick@wg0 systemd service must be disabled AND any fallback-conf loading must be blocked. Missing any one of these three steps causes wg0 to come up unexpectedly.

**Safe modification:** Before changing WG auto-startup logic, verify all three paths are tested:
1. No wg0.conf baked in the image
2. wg-quick@wg0.service is masked/disabled
3. ppsa-wireguard-register.sh aborts early if enabled=false

---

### SystemD Path/Timer Race on Boot

**Files:** `scripts/ppsa-firewall-request.path`, `scripts/ppsa-wg-manual-apply.path`

**Why fragile:** These systemd path units watch files in /etc/ppsa/. If the host-side /etc/ppsa is not mounted or has stale permissions, the path unit doesn't trigger. The WebUI then times out waiting for a response.

**Safe modification:** Always ensure `/etc/ppsa` is created with 755 perms in the image, and the WebUI container's /etc/ppsa bind mount is rw (it is, but verify in compose/docker-compose.yml).

---

## Scaling Limits

### Docker Image Caching on GitHub Actions

**Issue:** The build cache is invalidated on every script change, but the rootfs build (debootstrap + package install) takes 10+ minutes.

**Files:** `.github/workflows/build-release.yml` (lines 46-52)

**Current capacity:** ~30 min per build (2x parallel: USB + VBox). Bottleneck is rootfs debootstrap.

**Scaling path:**
- Consider switching to a pre-built base Docker image (Debian rootfs snapshot) to skip debootstrap on cache hits
- Use GitHub's official actions/cache@v4 with a larger key to narrow invalidation scope
- Measure actual impact: if rootfs rebuild is <2 min, caching isn't the bottleneck

---

### Backup Volume Size Headroom

**Issue:** Image default is 12 GB (IMG_SIZE_MB=12288), which was 98% full after first Palworld download in v1.1.0.

**Files:** `scripts/build-live-usb.sh` (line 21)

**Current capacity:** 12 GB total; ~4 GB system + 3.8 GB Palworld binary + 4 GB backups headroom.

**Scaling path:** 
- Add a build-time option `PPSA_IMG_SIZE_MB` (already exists as an env var override)
- Document recommended sizing: 20 GB minimum for sustained gameplay with weekly backups
- Consider implementing automatic pruning of backups older than BACKUP_RETENTION_DAYS

---

## Dependencies at Risk

### Passlib Removal (Workaround Not Upstream)

**Issue:** Passlib 1.7.4 + bcrypt >= 4.0 is broken (passlib's self-test sends 73-byte password that bcrypt rejects).

**Files:** `docker/webui/app/main.py` (lines 30-41), `requirements.txt` (line 6 comment)

**Workaround:** Direct bcrypt import with custom `_hash_pw()/_verify_pw()` helpers.

**Risk:** If passlib ever releases a fix that we want to use, we'd need to revert this workaround.

**Recommendation:** Monitor passlib releases; if passlib > 1.7.4 arrives with bcrypt support fixed, migrate back to the stdlib approach for consistency.

---

### Community Docker Image for Palworld

**Issue:** Palworld server is pulled from `thijsvanloef/palworld-server-docker` (third-party, not official).

**Files:** `compose/docker-compose.yml` (referenced in CLAUDE.md)

**Risk:** If the maintainer stops updating, or the image becomes vulnerable, PPSA users get stuck on stale versions.

**Recommendation:** Pin to a specific image tag, not `latest`. Current build should hardcode a known-good version in docker-compose.yml rather than pulling latest.

---

## Missing Critical Features

### No Remote Backup Export

**Issue:** Backups are stored on the PPSA device only (BACKUP_DIR = `/backups`). No push-to-S3, rsync, or cloud storage integration.

**Files:** `docker/webui/app/main.py` (backup endpoints read from local BACKUP_DIR only)

**Blocks:** Users cannot survive PPSA device failure; all backups are lost if the USB drive dies.

**Recommendation:** 
- Add WebUI configuration for backup destination (S3, rsync to NAS, Discord webhook, etc.)
- Integrate with offen/docker-volume-backup's own cloud-storage plugins if available
- Document manual rsync procedure for users who want off-device backups

---

### No Monitoring/Alerting Beyond Prometheus /metrics

**Issue:** PPSA exposes a Prometheus /metrics endpoint but ships no alerting rules (Grafana overlay exists but is optional and not tested).

**Files:** `docker/webui/app/main.py` (lines 89-130 — /metrics endpoint), `compose/docker-compose.monitoring.yml` (not started by default)

**Blocks:** Users cannot be notified if the game server crashes, backups fail, or the device runs out of disk.

**Recommendation:**
- Ship default Grafana dashboard and basic alert rules (game down, low disk, backup failed)
- Make optional monitoring stack more discoverable (currently buried in compose/ overlay)

---

## Test Coverage Gaps

### No End-to-End Tests for First Boot

**Issue:** Install script (`scripts/install.sh`) is not tested in CI before release. It only runs once per device, so bugs surface in production only.

**Files:** `scripts/install.sh` (430+ lines)

**Risk:** Changes to Docker Compose ordering, firewall rules, or systemd unit startup can silently break first boot. This is the most critical user-facing code path.

**Priority:** HIGH

**Recommendation:**
- Spin up a VirtualBox VM in CI after building the image and run the image in a test VM
- Verify: Docker stack starts, Web UI responds, game server has players on a test server, firewall rules are applied
- Current CI does not test the actual image post-boot (only builds it)

---

### No PowerShell Module Tests in CI

**Issue:** The local WSL builder (`modules/*.psm1`) has self-contained tests (e.g., `tests/test-logger.ps1`) but they don't run in CI.

**Files:** `modules/` (10 .psm1 files), `tests/test-*.ps1` (various tests)

**Risk:** PowerShell builder breaks without warning and dev iteration slows down.

**Recommendation:**
- Add a CI job that runs `pwsh tests/test-*.ps1` on all PR branches (not just on tag)
- Fix or remove any failing tests before merge

---

### WebUI Mod Upload Not Tested

**Issue:** Mod installation endpoint accepts zip files and extracts .pak files, but has no test coverage for edge cases.

**Files:** `docker/webui/app/main.py` (lines 612-640)

**Risk:** Malformed zips, path traversal attempts, or .pak files with unusual names could cause crashes or security issues.

**Test cases needed:**
- Bad zip file (corrupted)
- Zip with path traversal (../../etc/passwd.pak)
- Zip with no .pak files
- Very large .pak file (stress test)

---

## Architectural Concerns

### NetBird and WireGuard Coexist, Creating Path Complexity

**Issue:** Code still supports both NetBird (primary) and WireGuard (deprecated), with separate state files and enable/disable flags.

**Files:** 
- `docker/webui/app/main.py` (WG status checks, health monitors, firewall chain names "WG_FRIENDS")
- `scripts/ppsa-firewall-apply.sh` (chain supports both 100.64.0.0/10 NetBird and 10.8.0.0/24 WG)
- `scripts/install.sh` (steps for both services)

**Impact:** Firewall logic is harder to follow; WG health monitoring runs even when disabled; code paths split on enabled state.

**Recommendation:** 
- Timeline: v1.4.0 or later, after WG deprecation is well-communicated
- Remove all WG-specific code paths, systemd units, and health monitors
- Simplify firewall chain to support NetBird only
- This is a breaking change but will reduce maintenance burden significantly

---

### No Structured Logging

**Issue:** All logging is print() to stdout, captured in /var/log/ppsa-install.log. No structured logging in Python code.

**Files:** 
- `scripts/install.sh` (simple echo statements)
- `docker/webui/app/main.py` (no logging module usage)

**Impact:** Hard to parse logs programmatically; hard to forward to external log aggregation; timestamps are missing from Python app.

**Recommendation:** 
- Use Python logging module in WebUI with JSON formatter for easy parsing
- Add timestamps to all shell script output

---

## Documentation Gaps

### Disaster Recovery Not Documented

**Issue:** Backup procedures are documented, but bare-metal restore is not.

**Files:** `docs/` (no disaster-recovery.md)

**Blocks:** Users with full PPSA device failure don't know how to restore from backup to a new device.

**Recommendation:** Add `docs/disaster-recovery.md` covering:
- Download backup files from /backups (or S3 if configured)
- Write fresh PPSA image to new USB
- Boot into PPSA, navigate to Restore tab, upload backup
- Verify game state is restored

---

### Local Builder Documentation Needs WSL Path Clarification

**Issue:** `docs/local-builder.md` references `H:\dev\palimage` but this is specific to the dev machine and not portable.

**Files:** `docs/local-builder.md`, `CLAUDE.md` (line 97 — "Output lands in H:\dev\palimage")

**Impact:** New developers cloning the repo cannot easily run the local builder without hardcoding paths.

**Recommendation:** 
- Document how to override output path via builder.json
- Add a section on WSL path mapping (D: → /mnt/d, H: → /mnt/h)

---

*Concerns audit: 2026-07-16*
