"""
PPSA Web UI - Backend API

FastAPI application providing the management API for the Palworld Server Appliance.
Serves both the REST API and the static frontend files.
Requires JWT authentication on all /api/* endpoints except /api/login and /health.
"""

import os
import json
import shlex
import re
import asyncio
import subprocess
from pathlib import Path
from datetime import datetime, timedelta
from contextlib import asynccontextmanager

import httpx
import docker as _docker_sdk
_docker = _docker_sdk.from_env()
from fastapi import FastAPI, HTTPException, Depends, status
from fastapi.responses import Response
from fastapi.security import HTTPBasic, HTTPBasicCredentials, HTTPBearer
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel
from jose import JWTError, jwt
# Ponytail: replaced passlib with direct bcrypt to avoid passlib 1.7.4's internal
# self-test (sends 73-byte test password) breaking on bcrypt>=4.0.
import bcrypt as _bcrypt

def _hash_pw(plain: str) -> str:
    return _bcrypt.hashpw(plain.encode("utf-8"), _bcrypt.gensalt()).decode("utf-8")

def _verify_pw(plain: str, hashed: str) -> bool:
    try:
        return _bcrypt.checkpw(plain.encode("utf-8"), hashed.encode("utf-8"))
    except Exception:
        return False

# --- Configuration ---
DATA_DIR = Path(os.getenv("DATA_DIR", "/app/data"))
PALWORLD_API_URL = os.getenv("PALWORLD_API_URL", "http://palworld:8212")
PALWORLD_PASSWORD = os.getenv("PALWORLD_ADMIN_PASSWORD", "admin")
JWT_SECRET = os.getenv("JWT_SECRET", "ppsa-insecure-change-me")
JWT_ALGORITHM = "HS256"
JWT_EXPIRY_HOURS = 24
ENV_FILE = Path("/opt/ppsa/.env")
BACKUP_DIR = Path("/backups")  # mounted from ../backups by compose

# --- Bootstrap ---
DATA_DIR.mkdir(parents=True, exist_ok=True)
security_basic = HTTPBasic(auto_error=False)
security_bearer = HTTPBearer(auto_error=False)


# --- App ---
@asynccontextmanager
async def lifespan(app: FastAPI):
    """Startup: ensure admin user, auto-start WireGuard tunnel, launch health monitor."""
    users_file = DATA_DIR / "users.json"
    if not users_file.exists():
        users_file.write_text(json.dumps({
            "admin": _hash_pw("admin")
        }))
    # Auto-start WireGuard tunnel if config exists
    if WG_CONF.exists():
        _wg_run_raw(["wg-quick", "up", "wg0"])
    # Background tunnel health monitor
    monitor_task = asyncio.create_task(_wg_health_monitor())
    yield
    monitor_task.cancel()

app = FastAPI(title="PPSA Web UI", version="1.0.0", lifespan=lifespan)


# ---------------------------------------------------------------------------
# Health check (public)
# ---------------------------------------------------------------------------
@app.get("/health")
async def health():
    return {"status": "ok"}

@app.get("/metrics")
async def metrics():
    """Prometheus /metrics endpoint — no auth required for Prometheus scraping."""
    lines = [
        '# HELP ppsa_server_info Static info about the PPSA server',
        '# TYPE ppsa_server_info gauge',
        'ppsa_server_info{version="1.0.0"} 1',
    ]
    # Player count from Palworld REST API
    try:
        players = await palworld_get("/players")
        count = len(players) if isinstance(players, list) else 0
        lines.append('# HELP ppsa_player_count Current number of connected players')
        lines.append('# TYPE ppsa_player_count gauge')
        lines.append(f'ppsa_player_count {count}')
    except Exception:
        lines.append('# HELP ppsa_player_count Current number of connected players')
        lines.append('# TYPE ppsa_player_count gauge')
        lines.append('ppsa_player_count -1')
    # WireGuard tunnel status
    try:
        wg = _wg_run_raw(["wg", "show", "wg0"])
        active = 1 if (wg is not None and "latest handshake" in wg) else 0
    except Exception:
        active = 0
    lines.append('# HELP ppsa_tunnel_active WireGuard tunnel handshake status (1=active)')
    lines.append('# TYPE ppsa_tunnel_active gauge')
    lines.append(f'ppsa_tunnel_active {active}')
    # Backup file count
    count = 0
    try:
        if BACKUP_DIR.exists():
            count = sum(1 for f in BACKUP_DIR.iterdir() if f.suffix in (".gz", ".tar", ".tar.gz", ".zip"))
    except Exception:
        pass
    lines.append('# HELP ppsa_backup_file_count Number of backup archives')
    lines.append('# TYPE ppsa_backup_file_count gauge')
    lines.append(f'ppsa_backup_file_count {count}')
    return Response("\n".join(lines) + "\n", media_type="text/plain; charset=utf-8")


# ---------------------------------------------------------------------------
# Auth helpers
# ---------------------------------------------------------------------------
def verify_password(plain: str, hashed: str) -> bool:
    return _verify_pw(plain, hashed)

def create_token(username: str) -> str:
    exp = datetime.utcnow() + timedelta(hours=JWT_EXPIRY_HOURS)
    return jwt.encode({"sub": username, "exp": exp}, JWT_SECRET, algorithm=JWT_ALGORITHM)

def decode_token(token: str) -> str:
    """Decode JWT and return username. Raises 401 on failure."""
    try:
        payload = jwt.decode(token, JWT_SECRET, algorithms=[JWT_ALGORITHM])
        return payload["sub"]
    except JWTError:
        raise HTTPException(status_code=401, detail="Invalid or expired token")


# ---------------------------------------------------------------------------
# Dependency: require valid JWT Bearer token
# ---------------------------------------------------------------------------
def require_auth(credentials: HTTPBasicCredentials = Depends(security_bearer)):
    if credentials is None or not credentials.credentials:
        raise HTTPException(status_code=401, detail="Missing authorization token")
    return decode_token(credentials.credentials)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
def _read_file(path: Path) -> str:
    if not path.exists():
        raise HTTPException(status_code=404, detail=f"{path} not found")
    return path.read_text().strip()

def _run(cmd: list[str]) -> str:
    """Run a shell command and return stdout (used for /api/system disk probe)."""
    import subprocess
    try:
        return subprocess.check_output(cmd, timeout=10, text=True).strip()
    except Exception as e:
        return str(e)

def _run_docker(cmd: list[str]) -> str:
    """Run a docker command via the Python SDK and return stdout.

    Ponytail: was subprocess.check_output(["docker"] + ...) which always
    failed with "No such file or directory: 'docker'" because the webui
    container has no docker CLI binary. python:3.12-slim + docker==7.1.*
    SDK + /var/run/docker.sock mount is enough.
    """
    try:
        sub = cmd[0] if cmd else ""
        if sub == "ps":
            containers = _docker.containers.list(all=True)
            fmt = ""
            for i, c in enumerate(cmd[1:]):
                if c == "--format" and i + 1 < len(cmd) - 1:
                    fmt = cmd[i + 2]
                    break
                if c.startswith("--format="):
                    fmt = c.replace("--format=", "", 1)
                    break
            lines = []
            for c in containers:
                row = fmt.replace("{{.Names}}", c.name)\
                         .replace("{{.Status}}", c.status)\
                         .replace("{{.Image}}", c.image.tags[0] if c.image.tags else "<none>")
                lines.append(row)
            return "\n".join(lines)
        if sub == "logs":
            name = cmd[1]
            tail = 100
            for c in cmd:
                if c.startswith("--tail="):
                    tail = int(c.split("=")[1])
                elif c == "--tail" and len(cmd) > cmd.index(c) + 1:
                    tail = int(cmd[cmd.index(c) + 1])
            container = _docker.containers.get(name)
            return container.logs(tail=tail, stdout=True, stderr=True).decode("utf-8", errors="replace").strip()
        if sub == "restart":
            _docker.containers.get(cmd[1]).restart()
            return f"restarted {cmd[1]}"
        if sub == "exec":
            container = _docker.containers.get(cmd[1])
            exec_cmd = cmd[2:]
            exec_result = container.exec_run(exec_cmd)
            return exec_result.output.decode("utf-8", errors="replace").strip()
        return f"unsupported docker subcommand: {sub}"
    except Exception as e:
        return f"docker error: {e}"
    except Exception as e:
        return str(e)


# ---------------------------------------------------------------------------
# Palworld REST API proxy
# ---------------------------------------------------------------------------
async def palworld_get(path: str):
    """Proxy GET requests to the Palworld REST API."""
    async with httpx.AsyncClient() as client:
        resp = await client.get(
            f"{PALWORLD_API_URL}/v1/api{path}",
            auth=("admin", PALWORLD_PASSWORD),
            timeout=5,
        )
        if resp.status_code != 200:
            raise HTTPException(status_code=resp.status_code, detail=resp.text)
        return resp.json()

async def palworld_post(path: str, body: dict = None):
    """Proxy POST requests to the Palworld REST API."""
    async with httpx.AsyncClient() as client:
        resp = await client.post(
            f"{PALWORLD_API_URL}/v1/api{path}",
            auth=("admin", PALWORLD_PASSWORD),
            json=body or {},
            timeout=5,
        )
        if resp.status_code != 200:
            raise HTTPException(status_code=resp.status_code, detail=resp.text)
        return resp.json()


# ---------------------------------------------------------------------------
# Auth endpoints
# ---------------------------------------------------------------------------
@app.post("/api/login")
async def login(credentials: HTTPBasicCredentials = Depends(security_basic)):
    """Authenticate via HTTP Basic and return a JWT token."""
    if credentials is None:
        raise HTTPException(status_code=401, detail="Missing credentials")
    users_file = DATA_DIR / "users.json"
    users = json.loads(users_file.read_text())
    hashed = users.get(credentials.username)
    if not hashed or not verify_password(credentials.password, hashed):
        raise HTTPException(status_code=401, detail="Invalid credentials")
    return {"token": create_token(credentials.username)}


# ---------------------------------------------------------------------------
# Change password (protected)
# ---------------------------------------------------------------------------
@app.put("/api/users/password")
async def change_password(data: dict, _user: str = Depends(require_auth)):
    """Change the admin password. Expects {"current": "...", "new": "..."}."""
    users_file = DATA_DIR / "users.json"
    users = json.loads(users_file.read_text())

    current = data.get("current", "")
    new_pw = data.get("new", "")
    if len(new_pw) < 6:
        raise HTTPException(status_code=400, detail="New password must be at least 6 characters")

    # Verify current password
    hashed = users.get("admin")
    if not hashed or not verify_password(current, hashed):
        raise HTTPException(status_code=403, detail="Current password is incorrect")

    users["admin"] = _hash_pw(new_pw)
    users_file.write_text(json.dumps(users))
    return {"status": "ok"}


# ---------------------------------------------------------------------------
# Dashboard (protected)
# ---------------------------------------------------------------------------
@app.get("/api/dashboard")
async def dashboard(_user: str = Depends(require_auth)):
    """Aggregate game server status for the dashboard."""
    try:
        info = await palworld_get("/info")
        metrics = await palworld_get("/metrics")
        players = await palworld_get("/players")
    except Exception as e:
        info = {"error": str(e)}
        metrics = {}
        players = []

    return {
        "server": info,
        "metrics": metrics,
        "players": players,
        "player_count": len(players) if isinstance(players, list) else 0,
    }


# ---------------------------------------------------------------------------
# System health (protected)
# ---------------------------------------------------------------------------
@app.get("/api/system")
async def system_health(_user: str = Depends(require_auth)):
    """Host system health: CPU, memory, disk, uptime, container statuses."""
    try:
        # Memory
        mem = {}
        for line in _read_file(Path("/proc/meminfo")).splitlines():
            parts = line.split(":")
            if parts[0] in ("MemTotal", "MemAvailable", "MemFree"):
                val = parts[1].strip().split()[0]
                mem[parts[0].lower()] = int(val)  # kB

        # CPU load
        load = _read_file(Path("/proc/loadavg")).split()[:3]
        cpu_count = os.cpu_count() or 1

        # Disk
        df = _run(["df", "-B1", "/"])
        disk = {}
        for line in df.splitlines()[1:2]:
            parts = line.split()
            if len(parts) >= 6:
                disk = {
                    "total": int(parts[1]),
                    "used": int(parts[2]),
                    "available": int(parts[3]),
                    "percent": parts[4].replace("%", ""),
                }

        # Uptime
        uptime_secs = round(float(_read_file(Path("/proc/uptime")).split()[0]))

        # Docker containers
        ps_out = _run_docker(["ps", "--format", "{{.Names}}\t{{.Status}}\t{{.Image}}"])
        containers = []
        for line in ps_out.splitlines():
            parts = line.split("\t")
            if len(parts) >= 3:
                containers.append({"name": parts[0], "status": parts[1], "image": parts[2]})

    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

    mem_total_mb = round(mem.get("memtotal", 0) / 1024)
    mem_avail_mb = round(mem.get("memavailable", 0) / 1024)

    return {
        "cpu": {
            "load_1m": float(load[0]),
            "load_5m": float(load[1]),
            "load_15m": float(load[2]),
            "cores": cpu_count,
        },
        "memory": {
            "total_mb": mem_total_mb,
            "available_mb": mem_avail_mb,
            "used_mb": mem_total_mb - mem_avail_mb,
            "percent": round((mem_total_mb - mem_avail_mb) / mem_total_mb * 100, 1) if mem_total_mb else 0,
        },
        "disk": disk,
        "uptime_seconds": uptime_secs,
        "containers": containers,
    }


# ---------------------------------------------------------------------------
# Config: environment file (protected)
# ---------------------------------------------------------------------------
def _parse_env(text: str) -> dict:
    """Parse KEY=VALUE lines into a dict, skipping comments/blanks."""
    result = {}
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        if "=" in line:
            k, _, v = line.partition("=")
            result[k.strip()] = v.strip()
    return result

@app.get("/api/env")
async def get_env(_user: str = Depends(require_auth)):
    """Return the server .env file as key-value pairs."""
    if not ENV_FILE.exists():
        return {}
    return _parse_env(ENV_FILE.read_text())

@app.put("/api/env")
async def update_env(data: dict, _user: str = Depends(require_auth)):
    """Update specific keys in the .env file. Body: {"KEY": "VALUE", ...}."""
    if not ENV_FILE.exists():
        raise HTTPException(status_code=404, detail=".env file not found")
    content = ENV_FILE.read_text()
    lines = content.splitlines(keepends=True)
    updated = []
    changed_keys = []

    for key, value in data.items():
        found = False
        for i, line in enumerate(lines):
            if line.startswith(f"{key}=") or line.startswith(f"{key} ="):
                lines[i] = f"{key}={value}\n"
                found = True
                changed_keys.append(key)
                break
        if not found:
            lines.append(f"{key}={value}\n")
            changed_keys.append(key)

    ENV_FILE.write_text("".join(lines))
    return {"status": "ok", "updated": changed_keys}


# ---------------------------------------------------------------------------
# Palworld game settings (read-only, from REST API)
# ---------------------------------------------------------------------------
@app.get("/api/config")
async def get_config(_user: str = Depends(require_auth)):
    """Current Palworld runtime settings (read-only). Edit via /api/env + restart."""
    return await palworld_get("/settings")


# ---------------------------------------------------------------------------
# Server controls (protected)
# ---------------------------------------------------------------------------
@app.post("/api/server/stop")
async def stop_server(_user: str = Depends(require_auth)):
    return await palworld_post("/stop")

@app.post("/api/server/save")
async def save_world(_user: str = Depends(require_auth)):
    return await palworld_post("/save")

@app.post("/api/server/shutdown")
async def shutdown_server(
    waittime: int = 30,
    message: str = "Server maintenance",
    _user: str = Depends(require_auth),
):
    return await palworld_post("/shutdown", {"waittime": waittime, "message": message})

@app.post("/api/server/announce")
async def announce(message: str, _user: str = Depends(require_auth)):
    return await palworld_post("/announce", {"message": message})

@app.post("/api/server/restart")
async def restart_palworld(_user: str = Depends(require_auth)):
    """Restart the Palworld Docker container (applies .env changes)."""
    out = _run_docker(["restart", "ppsa-palworld"])
    if "error" in out.lower() and "not found" in out.lower():
        raise HTTPException(status_code=404, detail="Palworld container not found")
    return {"status": "ok", "detail": "Palworld container restarting. Allow ~2 minutes for startup."}


# ---------------------------------------------------------------------------
# Player management (protected)
# ---------------------------------------------------------------------------
@app.get("/api/players")
async def get_players(_user: str = Depends(require_auth)):
    return await palworld_get("/players")

@app.post("/api/players/kick")
async def kick_player(userid: str, reason: str = "Kicked by admin", _user: str = Depends(require_auth)):
    return await palworld_post("/kick", {"userid": userid, "message": reason})

@app.post("/api/players/ban")
async def ban_player(userid: str, reason: str = "Banned by admin", _user: str = Depends(require_auth)):
    return await palworld_post("/ban", {"userid": userid, "message": reason})

@app.post("/api/players/unban")
async def unban_player(userid: str, _user: str = Depends(require_auth)):
    return await palworld_post("/unban", {"userid": userid})


# ---------------------------------------------------------------------------
# Logs (protected)
# ---------------------------------------------------------------------------
@app.get("/api/logs")
async def get_logs(tail: int = 100, _user: str = Depends(require_auth)):
    """Return last N lines of Palworld server logs."""
    out = _run_docker(["logs", "ppsa-palworld", "--tail", str(tail)])
    return {"lines": out.splitlines()}


# ---------------------------------------------------------------------------
# Backup management (protected)
# ---------------------------------------------------------------------------
@app.get("/api/backup/status")
async def backup_status(_user: str = Depends(require_auth)):
    """List backup archives and show last backup time."""
    files = []
    last_time = None
    if BACKUP_DIR.exists():
        for f in sorted(BACKUP_DIR.iterdir(), key=lambda p: p.stat().st_mtime, reverse=True):
            if f.suffix in (".gz", ".tar", ".tar.gz", ".zip"):
                stat = f.stat()
                files.append({
                    "name": f.name,
                    "size": stat.st_size,
                    "modified": datetime.fromtimestamp(stat.st_mtime).isoformat(),
                })
                if last_time is None:
                    last_time = datetime.fromtimestamp(stat.st_mtime).isoformat()

    return {
        "backup_dir": str(BACKUP_DIR),
        "last_backup": last_time,
        "file_count": len(files),
        "files": files[:20],  # last 20 only
    }

@app.post("/api/backup/trigger")
async def trigger_backup(_user: str = Depends(require_auth)):
    """Trigger a manual backup via docker exec in the backup container."""
    # The offen/docker-volume-backup container runs backup with 'backup' entrypoint
    out = _run_docker(["exec", "ppsa-backup", "backup"])
    return {"status": "triggered", "detail": out[:500]}

@app.get("/api/backup/config")
async def get_backup_config(_user: str = Depends(require_auth)):
    """Return backup-related env vars from the .env file."""
    if not ENV_FILE.exists():
        return {}
    env = _parse_env(ENV_FILE.read_text())
    return {
        "BACKUP_SCHEDULE": env.get("BACKUP_SCHEDULE", "0 3 * * *"),
        "BACKUP_RETENTION_DAYS": env.get("BACKUP_RETENTION_DAYS", "7"),
        "DISCORD_WEBHOOK_URL": env.get("DISCORD_WEBHOOK_URL", ""),
    }


# ---------------------------------------------------------------------------
# WireGuard tunnel management (protected)
# ---------------------------------------------------------------------------
WG_DIR = Path("/etc/wireguard")
WG_CONF = WG_DIR / "wg0.conf"
WG_KEY = WG_DIR / "ppsa.key"
WG_PUB = WG_DIR / "ppsa.pub"

def _wg_run(cmd: list[str]) -> str:
    """Run a wg or wg-quick command, return stdout (raises HTTPException on failure)."""
    try:
        return subprocess.check_output(cmd, timeout=15, stderr=subprocess.STDOUT, text=True).strip()
    except subprocess.CalledProcessError as e:
        raise HTTPException(status_code=500, detail=e.output or str(e))
    except FileNotFoundError:
        raise HTTPException(status_code=500, detail="wireguard-tools not installed in container")

def _wg_run_raw(cmd: list[str]) -> str | None:
    """Run a wg/wg-quick command, return stdout or None on failure (safe for background use)."""
    try:
        return subprocess.check_output(cmd, timeout=15, stderr=subprocess.STDOUT, text=True).strip()
    except Exception:
        return None

async def _wg_health_monitor():
    """Background: check tunnel every 60s, reconnect after 3 consecutive failures."""
    failures = 0
    while True:
        await asyncio.sleep(60)
        if not WG_CONF.exists():
            failures = 0
            continue
        output = _wg_run_raw(["wg", "show", "wg0"])
        if output is None or "latest handshake" not in output:
            failures += 1
        else:
            failures = 0
        if failures >= 3:
            _wg_run_raw(["wg-quick", "down", "wg0"])
            _wg_run_raw(["wg-quick", "up", "wg0"])
            failures = 0

@app.get("/api/wireguard/status")
async def wireguard_status(_user: str = Depends(require_auth)):
    """Get WireGuard tunnel status with transfer stats and handshake info."""
    if not WG_CONF.exists():
        return {"status": "not_configured", "detail": "No wg0.conf found"}
    try:
        output = _wg_run(["wg", "show", "wg0"])
        has_handshake = "latest handshake" in output
        peer_count = output.count("peer:")

        # Parse transfer stats: "transfer: 1.23 GiB received, 456.78 MiB sent"
        transfer_rx = ""
        transfer_tx = ""
        m = re.search(r"transfer:\s*([\d.]+\s*\w+)\s*received,\s*([\d.]+\s*\w+)\s*sent", output)
        if m:
            transfer_rx, transfer_tx = m.group(1), m.group(2)

        # Parse latest handshake: "latest handshake: 1 minute, 30 seconds ago"
        handshake_str = ""
        for line in output.splitlines():
            if "latest handshake" in line:
                handshake_str = line.split(":", 1)[1].strip()
                break

        return {
            "status": "active" if has_handshake else "inactive",
            "detail": output,
            "peer_count": peer_count,
            "has_handshake": has_handshake,
            "transfer_rx": transfer_rx,
            "transfer_tx": transfer_tx,
            "latest_handshake": handshake_str,
        }
    except HTTPException:
        raise
    except Exception as e:
        return {"status": "error", "detail": str(e)}

@app.get("/api/wireguard/config")
async def wireguard_get_config(_user: str = Depends(require_auth)):
    """Return the current WireGuard client configuration (sans private key)."""
    if not WG_CONF.exists():
        return {"configured": False, "config": {}}

    text = WG_CONF.read_text()
    # Parse key fields, mask private key
    vps_endpoint = ""
    vps_pubkey = ""
    for line in text.splitlines():
        line = line.strip()
        if line.startswith("Endpoint"):
            vps_endpoint = line.split("=", 1)[1].strip()
        if line.startswith("PublicKey") and "=" in line:
            vps_pubkey = line.split("=", 1)[1].strip()

    ppsa_pub = WG_PUB.read_text().strip() if WG_PUB.exists() else ""

    return {
        "configured": True,
        "config": {
            "vps_endpoint": vps_endpoint,
            "vps_public_key": vps_pubkey,
            "ppsa_public_key": ppsa_pub,
            "interface": "wg0",
        }
    }

class ConnectRequest(BaseModel):
    vps_endpoint: str
    vps_public_key: str

@app.post("/api/wireguard/connect")
async def wireguard_connect(req: ConnectRequest, _user: str = Depends(require_auth)):
    """Generate keys, write wg0.conf, and start the tunnel."""
    WG_DIR.mkdir(parents=True, exist_ok=True)

    # Generate keys if needed
    if not WG_KEY.exists():
        priv = subprocess.check_output(["wg", "genkey"], text=True).strip()
        WG_KEY.write_text(priv + "\n")
        WG_KEY.chmod(0o600)
        pub = subprocess.check_output(["wg", "pubkey"], input=priv, text=True).strip()
        WG_PUB.write_text(pub + "\n")

    priv_key = WG_KEY.read_text().strip()
    pub_key = WG_PUB.read_text().strip() if WG_PUB.exists() else ""

    # Write wg0.conf
    conf = f"""[Interface]
PrivateKey = {priv_key}
Address = 10.0.0.2/32
DNS = 1.1.1.1, 8.8.8.8

[Peer]
PublicKey = {req.vps_public_key}
Endpoint = {req.vps_endpoint}
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
"""
    WG_CONF.write_text(conf)
    WG_CONF.chmod(0o600)

    # Start tunnel
    try:
        _wg_run(["wg-quick", "up", "wg0"])
    except Exception as e:
        return {
            "status": "config_written",
            "detail": f"Config written but tunnel start failed: {e}",
            "ppsa_public_key": pub_key,
        }

    return {
        "status": "connected",
        "detail": "WireGuard tunnel started",
        "ppsa_public_key": pub_key,
    }

@app.post("/api/wireguard/disconnect")
async def wireguard_disconnect(_user: str = Depends(require_auth)):
    """Stop the WireGuard tunnel."""
    try:
        _wg_run(["wg-quick", "down", "wg0"])
        return {"status": "disconnected", "detail": "Tunnel stopped"}
    except HTTPException:
        raise
    except Exception as e:
        return {"status": "error", "detail": str(e)}


# ---------------------------------------------------------------------------
# Wi-Fi management (runs on the host, not in this container)
# ---------------------------------------------------------------------------
def _host_exec(cmd: str, timeout: int = 30) -> tuple[int, str, str]:
    """Run a command on the PPSA host (not in a container) and return exit/out/err.

    The webui container has /host mounted read-only (the host's root
    filesystem). We chroot into it to use the host's nmcli, wpa_supplicant,
    hostapd, and other system binaries. The chroot runs commands in the
    host's mount namespace, so /proc, /sys, and network namespaces are
    still the container's — but for nmcli/wifi operations, that's fine
    because those tools work via netlink which sees the host's Wi-Fi
    interfaces regardless of mount namespace.
    """
    import subprocess
    # chroot into /host to use the host's binaries. The chroot process
    # inherits the container's network namespace, so we use nsenter-style
    # trick: run in the host's pid 1 mount namespace via nsenter if
    # available, else fall back to direct chroot.
    full_cmd = f"nsenter -t 1 -m -- chroot /host bash -c {shlex.quote(cmd)} 2>&1"
    try:
        p = subprocess.run(full_cmd, shell=True, capture_output=True, text=True, timeout=timeout)
        if p.returncode == 0 and p.stdout.strip():
            return p.returncode, p.stdout.strip(), p.stderr.strip()
        # Fallback: direct chroot (mount namespace may differ but binaries work)
        fallback = f"chroot /host bash -c {shlex.quote(cmd)} 2>&1"
        p = subprocess.run(fallback, shell=True, capture_output=True, text=True, timeout=timeout)
        return p.returncode, p.stdout.strip(), p.stderr.strip()
    except subprocess.TimeoutExpired:
        return 124, "", "timeout"
    except Exception as e:
        return 1, "", str(e)
    except Exception as e:
        return 1, "", str(e)

WIFI_CONFIG = Path("/etc/ppsa/wifi.conf")  # host path; webui runs in container but reads via exec

@app.get("/api/wifi/status")
async def wifi_status(_user: str = Depends(require_auth)):
    """Current Wi-Fi connection status, available networks, and hotspot state."""
    rc, out, err = _host_exec("nmcli -t -f ACTIVE,SSID,SIGNAL,FREQ,SECURITY,IN-USE device wifi 2>/dev/null; echo ---; nmcli -t -f NAME,UUID,TYPE,DEVICE,STATE connection --active 2>/dev/null; echo ---; systemctl is-active ppsa-hotspot 2>/dev/null")
    if rc != 0 and not out:
        raise HTTPException(status_code=500, detail=f"nmcli failed: {err}")
    return {
        "nmcli_output": out,
        "hotspot_active": "active" in out.lower() if out else False,
    }

@app.get("/api/wifi/scan")
async def wifi_scan(_user: str = Depends(require_auth)):
    """Trigger a Wi-Fi rescan and return the list of visible networks."""
    # Force rescan
    _host_exec("nmcli device wifi rescan 2>/dev/null", timeout=15)
    # Read the cache
    rc, out, err = _host_exec("nmcli -t -f SSID,SIGNAL,BARS,FREQ,SECURITY,IN-USE device wifi 2>/dev/null")
    if rc != 0:
        raise HTTPException(status_code=500, detail=f"scan failed: {err}")
    networks = []
    for line in out.splitlines():
        if not line.strip():
            continue
        parts = line.split(":")
        if len(parts) < 5:
            continue
        ssid, signal, bars, freq, security = parts[0], parts[1], parts[2], parts[3], ":".join(parts[4:])
        if not ssid or ssid == "--":
            continue
        networks.append({
            "ssid": ssid,
            "signal_pct": int(signal) if signal.isdigit() else 0,
            "bars": bars,
            "freq_mhz": int(freq) if freq.isdigit() else 0,
            "security": security or "Open",
            "connected": "*" in bars or "in-use" in security.lower(),
        })
    # Sort by signal strength (strongest first)
    networks.sort(key=lambda n: -n["signal_pct"])
    return {"networks": networks, "count": len(networks)}

@app.post("/api/wifi/connect")
async def wifi_connect(data: dict, _user: str = Depends(require_auth)):
    """Connect to a Wi-Fi network (SSID + password). Stops the hotspot first."""
    ssid = (data.get("ssid") or "").strip()
    psk = (data.get("password") or "").strip()
    if not ssid:
        raise HTTPException(status_code=400, detail="ssid required")
    if not psk:
        # Open network - use empty password
        connect_cmd = f"nmcli device wifi connect '{ssid}'"
    else:
        # Escape single quotes in password
        psk_escaped = psk.replace("'", "'\\''")
        connect_cmd = f"nmcli device wifi connect '{ssid}' password '{psk_escaped}'"
    rc, out, err = _host_exec(connect_cmd, timeout=60)
    if rc != 0:
        raise HTTPException(status_code=500, detail=f"connect failed: {err or out}")
    # Save the creds so we auto-reconnect on reboot
    _host_exec(f"mkdir -p /etc/ppsa && printf 'SSID=%q\\nPSK=%q\\n' '{ssid}' '{psk}' > /etc/ppsa/wifi.conf")
    # Stop the hotspot (no longer needed)
    _host_exec("systemctl stop hostapd 2>/dev/null; nmcli con down ppsa-hotspot 2>/dev/null; true")
    return {"status": "connected", "ssid": ssid, "detail": out}

@app.post("/api/wifi/disconnect")
async def wifi_disconnect(_user: str = Depends(require_auth)):
    """Disconnect from current Wi-Fi and stop the hotspot (use Ethernet)."""
    _host_exec("nmcli connection down id '$(nmcli -t -f NAME,UUID connection --active | head -1 | cut -d: -f1)' 2>/dev/null; true")
    _host_exec("rm -f /etc/ppsa/wifi.conf 2>/dev/null; true")
    return {"status": "disconnected"}

@app.post("/api/wifi/hotspot/start")
async def wifi_hotspot_start(_user: str = Depends(require_auth)):
    """Manually start the PPSA-Setup hotspot (for re-onboarding)."""
    rc, out, err = _host_exec("systemctl start ppsa-wifi-onboard.service 2>&1")
    if rc != 0:
        raise HTTPException(status_code=500, detail=f"hotspot start failed: {err}")
    return {"status": "hotspot_started", "detail": "Connect to PPSA-Setup (password: ppsa-setup-2026) and visit http://192.168.50.1/"}


# ---------------------------------------------------------------------------
# Serve static frontend
# ---------------------------------------------------------------------------
FRONTEND_DIR = Path(__file__).parent / "static"

if FRONTEND_DIR.exists():
    app.mount("/", StaticFiles(directory=str(FRONTEND_DIR), html=True), name="frontend")
