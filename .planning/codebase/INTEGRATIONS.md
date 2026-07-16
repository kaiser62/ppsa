# External Integrations

**Analysis Date:** 2026-07-16

## APIs & External Services

**Palworld Server REST API:**
- **Service:** Palworld dedicated server (via `thijsvanloef/palworld-server-docker` image)
  - **What it's used for:** Server control (start/stop/save), player management (kick/ban/unban), in-game announcements, game settings retrieval
  - **Client:** Python `httpx` async HTTP client
  - **Authentication:** HTTP Basic Auth (admin username + `PALWORLD_ADMIN_PASSWORD`)
  - **Endpoints:** `/v1/api/info`, `/v1/api/metrics`, `/v1/api/players`, `/v1/api/settings`, `/v1/api/save`, `/v1/api/stop`, `/v1/api/shutdown`, `/v1/api/announce`, `/v1/api/kick`, `/v1/api/ban`, `/v1/api/unban`
  - **Location in code:** `docker/webui/app/main.py` - `palworld_get()` and `palworld_post()` helper functions
  - **URL:** Environment variable `PALWORLD_API_URL` (default `http://palworld:8212`)

**NetBird VPN Network:**
- **Service:** NetBird management control plane
  - **What it's used for:** Unattended peer enrollment, mesh overlay network for appliance access
  - **Configuration:** `/etc/ppsa/netbird.json` (written at build time via GitHub Actions secrets)
  - **Setup key:** `PPSA_NB_SETUP_KEY` (baked into image, idempotent re-enrollment)
  - **Management URL:** `PPSA_NB_MANAGEMENT_URL` (e.g., https://nb.example.com)
  - **Binary:** `netbird` CLI (installed in Debian chroot during build)
  - **Enrollment script:** `scripts/ppsa-netbird-up.sh` (runs at boot via systemd service)
  - **Exit codes:** 0=connected, 1=config missing/invalid, 2=daemon unavailable, 3=enrollment failed
  - **Status output:** `netbird status --json` piped to Python to extract IP (saved to `/run/ppsa-netbird-ip`)

**WireGuard VPN (Deprecated, Optional):**
- **Service:** Legacy WireGuard tunnel (disabled by default, optional re-enable)
  - **What it's used for:** Peer-to-peer overlay network (backup path if NetBird unavailable)
  - **Enablement flag:** `PPSA_WG_ENABLED=true` (GitHub Actions repo variable)
  - **Configuration:** `/etc/wireguard/wg0.conf`
  - **Registration:** wg-easy API (legacy, credentials in GitHub Actions secrets)
  - **Fallback config:** Base64-encoded full config (PPSA_WG_FALLBACK_CONF_B64 secret) used if auto-registration fails
  - **Dashboard:** `ghcr.io/wgdashboard/wgdashboard:latest` on port 10086
  - **Status monitoring:** `ppsa-wg-status-snapshot.timer` (every 5s) writes JSON to `/etc/ppsa/wg-status.json`

## Data Storage

**Databases:**
- **Type:** File-based JSON (no traditional SQL database)
  - **Users:** `$DATA_DIR/users.json` (Web UI credentials, bcrypt-hashed passwords)
    - Client: Python native JSON
    - Location: `docker/webui/app/main.py`
  - **WireGuard requests/results:** `/etc/ppsa/wg-manual-request.json` and `/etc/ppsa/wg-manual-result.json` (systemd path unit IPC)
  - **WireGuard status snapshot:** `/etc/ppsa/wg-status.json` (host writes, container reads)
  - **WireGuard Dashboard database:** `wgdashboard_data` volume (local SQLite in wgdashboard container)
  - **Server configuration:** `/opt/ppsa/.env` (dotenv format, read/write via Web UI)

**File Storage:**
- **Local filesystem only**
  - **Backups:** `/backups/` directory (mounted from host `../backups`)
  - **Palworld game data:** `palworld_data` volume (Docker named volume)
  - **Web UI data:** `webui_data` volume (users.json, etc.)
  - **WireGuard configs:** `/etc/wireguard/` (mounted into webui + wgdashboard containers)
  - **PPSA config:** `/etc/ppsa/` (netbird.json, firewall.json, wg-status.json)

**Caching:**
- **Docker layer caching:** Build-time rootfs cache (`/tmp/ppsa-rootfs-cache.tar.gz`) — CI skips `debootstrap` if hash matches
- **No external caching service**

## Authentication & Identity

**Auth Provider:**
- **Custom JWT-based** (no external OAuth/OIDC)
  - **Implementation:** Python `python-jose` library with HS256 symmetric key
  - **Secret:** `JWT_SECRET` environment variable (default "ppsa-insecure-change-me" — should be overridden)
  - **Expiry:** 24 hours per token
  - **Location:** `docker/webui/app/main.py` - `create_token()` and `decode_token()` functions

**Password Hashing:**
- **Library:** bcrypt 4.0+
- **Location:** `docker/webui/app/main.py` - `_hash_pw()` and `_verify_pw()` custom helpers
- **Rationale:** Replaced `passlib` (broken compatibility with bcrypt>=4.0) with direct bcrypt calls

**Endpoints requiring authentication:**
- All `/api/*` endpoints except `/api/login` and `/health`
- Basic auth → JWT token flow: POST `/api/login` with credentials returns `{"token": "..."}`
- Subsequent requests: Bearer token in Authorization header

## Monitoring & Observability

**Error Tracking:**
- **None** (errors logged to stdout/stderr, captured by Docker logs)

**Logs:**
- **Docker logging driver:** `json-file` with 10MB max size, 3 file rotation
  - **Palworld logs:** Accessible via `/api/logs` endpoint (reads last N lines via Docker API)
  - **Web UI logs:** Captured by Docker daemon, accessible via `docker logs ppsa-webui`

**Metrics (optional Prometheus stack):**
- **Prometheus:** Scrapes `/metrics` endpoint on Web UI (exposes `ppsa_server_info`, `ppsa_player_count`, `ppsa_tunnel_active`, `ppsa_backup_file_count`)
- **Node exporter:** Host system metrics (CPU, memory, disk, network)
- **Grafana:** Visualization dashboard (`docker/webui/app/static/index.html` serves frontend; separate stack has Grafana UI on port 3000)

**Health checks:**
- **Web UI:** `GET /health` returns `{"status": "ok"}` (no auth required)
- **Container health checks:** Docker HEALTHCHECK directives defined per service in compose files
  - Palworld: RCON `Info` command every 30s
  - Web UI: curl to `/health` every 30s
  - WireGuard Dashboard: Python urllib every 30s
  - Backup: kill -0 on PID 1 every 5m
  - Watchtower: `/watchtower --health-check` every 5m

## CI/CD & Deployment

**Hosting:**
- **Self-hosted:** Appliance runs as bootable Debian image on user's hardware (USB SSD or VirtualBox VDI)
- **Build environment:** GitHub Actions (ubuntu-latest runners)

**CI Pipeline:**
- **GitHub Actions workflows:**
  - `.github/workflows/build-release.yml` — Build USB + VBox images on push/tag/workflow_dispatch
  - `.github/workflows/build-installer.yml` — Build Debian Live ISO (manual workflow_dispatch only)
- **Trigger matrix:**
  - **Push to `netbird` branch:** Build only, no release
  - **Push to `master` branch:** Build only, no release
  - **Tag push (vX.Y.Z):** Build + publish GitHub Release with artifacts
  - **workflow_dispatch:** Manual build with optional `expose_ssh_lan` flag
- **Artifact storage:** GitHub Releases (2GB asset limit enforced via zstd compression)

**Build caching:**
- **Rootfs cache:** Docker actions/cache v4 with key based on `scripts/**/*.sh`, `compose/**`, `docker/**`, `.github/workflows/build-release.yml`
- **Cache hit:** Sets `PPSA_SKIP_BOOTSTRAP=1` to reuse cached debootstrap tarball

**Deployment pipeline:**
- **First boot:** `ppsa-firstboot.service` runs `scripts/install.sh` (one-time flag prevents re-runs)
- **Steps:** Partition resize → Docker start → .env setup → docker compose up → firewall config → WiFi onboarding → NetBird enrollment
- **Post-deploy:** Watchtower automatically updates images daily at 4 AM UTC

## Environment Configuration

**Required env vars (at build time, baked into image or .env):**
- `SERVER_NAME`, `SERVER_DESCRIPTION`, `ADMIN_PASSWORD`, `MAX_PLAYERS`, `MULTITHREADING`, `COMMUNITY`, `TZ`
- `PALWORLD_API_URL`, `PALWORLD_ADMIN_PASSWORD` (Web UI needs these to proxy to game server)
- `PPSA_NB_MANAGEMENT_URL`, `PPSA_NB_SETUP_KEY` (NetBird enrollment — leave empty to disable)
- `PPSA_WG_ENABLED` (false by default; set true to enable legacy WireGuard)
- `BACKUP_SCHEDULE`, `BACKUP_RETENTION_DAYS` (cron expression, days to keep)
- `DISCORD_WEBHOOK_URL` (optional — offen/docker-volume-backup posts backup completion notices)
- `GRAFANA_PASSWORD` (only needed if monitoring overlay deployed)

**Secrets location:**
- **GitHub Actions:** Stored as repo secrets and variables (accessed via `${{ secrets.* }}` and `${{ vars.* }}` in workflows)
- **Runtime:** `.env` file on appliance (editable via Web UI Config tab)
- **Never committed:** `.env` and `.env.local` in `.gitignore`

## Webhooks & Callbacks

**Incoming:**
- **None** (appliance is typically behind firewall/NAT, not exposed to inbound HTTP)

**Outgoing:**
- **Discord webhook:** Optional backup completion notifications
  - **Provider:** Discord server
  - **Endpoint:** `DISCORD_WEBHOOK_URL` environment variable
  - **Driver:** offen/docker-volume-backup container posts JSON on backup success/failure
  - **Trigger:** Every backup (cron + manual trigger)

---

*Integration audit: 2026-07-16*
