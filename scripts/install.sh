#!/usr/bin/env bash
# =============================================================================
# PPSA - First Boot Setup
# =============================================================================
# Runs automatically on first boot via ppsa-install systemd service.
# Deploys the Docker stack and configures the system.
#
# After this runs, the web UI is available at http://<ip>:8080
# =============================================================================

set -eu
# Note: deliberately no pipefail. The script uses several pipelines
# (cmd | grep ... | awk ... | head -1) where grep returning 1 on no
# match is a normal case. With pipefail, those would abort the script
# under set -e. Last-command-in-pipeline failures are still caught.

PPSA_DIR="/opt/ppsa"
DATA_DIR="$PPSA_DIR/data"
LOG_FILE="/var/log/ppsa-install.log"
FLAG_FILE="$PPSA_DIR/.installed"
# Progress file watched by ppsa-firstboot.sh (tty1 progress display).
# Single integer: the highest step number that has been entered.
PROGRESS_FILE="/run/ppsa-install.progress"

# Send script output to the log file. The systemd journal sees the script's
# exit status separately; capturing stdout in a file is the only way to
# inspect what happened on first boot. Keep it simple: no FIFO, no tee race.
# ponytail: direct redirect — robust, no background processes to leak
rm -f "$LOG_FILE"
exec > "$LOG_FILE" 2>&1
chmod 644 "$LOG_FILE" 2>/dev/null || true

# Only run once
if [ -f "$FLAG_FILE" ] && [ "${1:-}" != "--force" ]; then
    echo "PPSA already installed. Run with --force to reinstall."
    exit 0
fi

echo "=== PPSA First Boot Setup ==="
echo "Date: $(date)"
echo "Repo: $PPSA_DIR"

# Helper: announce the start of a step (writes to log AND progress file).
# Total steps must match the [N/9] markers and ppsa-firstboot.sh.
mark_step() {
    local n="$1"
    echo "$n" > "$PROGRESS_FILE" 2>/dev/null || true
    echo "[STEP] Entering step $n/$TOTAL_STEPS: ${STEP_NAMES[$((n-1))]:-}"
}
TOTAL_STEPS=9
STEP_NAMES=(
    "Resizing root partition"
    "Starting Docker"
    "Configuring environment"
    "Deploying Docker stack"
    "Installing Wi-Fi onboarding"
    "Connecting to WireGuard network"
    "NetBird enrollment"
    "Configuring firewall"
    "Marking installation complete"
)

# --- Step 0: Auto-resize root partition to fill USB drive ---
# Runs in a subshell with set -e and pipefail DISABLED. parted/growpart can
# block indefinitely on VDI/fixed virtual disks. The whole step is bounded
# by an outer 'timeout 30' so it cannot stall the rest of install.sh.
mark_step 1
echo "[1/9] Resizing root partition to fill drive..."
RESIZE_START=$(date +%s)
# ponytail: just attempt the resize. growpart is a no-op if the partition
# already fills the disk; resize2fs is a no-op if the fs is at full size.
# All calls are individually bounded with timeouts so a hung partition
# table (VDI quirk) can't stall install.sh.
(
    set +e
    set +o pipefail
    ROOT_DEV=$(findmnt -n -o SOURCE / 2>/dev/null)
    if [ -z "$ROOT_DEV" ]; then
        echo "  Skipping (no root device)."
        exit 0
    fi
    DISK="${ROOT_DEV%[0-9]*}"
    PART_NUM="${ROOT_DEV#"$DISK"}"
    if [ -z "$DISK" ] || [ -z "$PART_NUM" ]; then
        echo "  Skipping (parse fail: $ROOT_DEV)."
        exit 0
    fi
    timeout 10 growpart "$DISK" "$PART_NUM" 2>/dev/null
    RC=$?
    if [ $RC -eq 0 ]; then
        timeout 30 resize2fs "$ROOT_DEV" 2>/dev/null
        echo "  Root partition resized."
    elif [ $RC -eq 1 ]; then
        # growpart exit 1 = "already at max size" (the normal case on VDI)
        echo "  Already at full size, skipping."
    else
        echo "  growpart failed (rc=$RC); leaving partition as-is."
    fi
)
ELAPSED=$(( $(date +%s) - RESIZE_START ))
echo "  (resize step took ${ELAPSED}s)"

# --- Step 1: Ensure Docker is running ---
mark_step 2
echo "[2/9] Starting Docker..."
systemctl start docker || true

# --- Step 2: Set up environment ---
mark_step 3
echo "[3/9] Configuring environment..."
cd "$PPSA_DIR"
if [ ! -f .env ]; then
    if [ -f .env.example ]; then
        cp .env.example .env
        echo "Created default .env from .env.example"
    fi
fi

# --- Step 3: Deploy Docker stack ---
mark_step 4
echo "[4/9] Deploying Docker stack..."
# Pull can fail on no-network or registry issues — don't let it kill install.
# Ponytail: one retry on transient registry corruption (empty init.sh etc).
pull_with_retry() {
    local max=2
    for i in $(seq 1 $max); do
        if docker compose -f compose/docker-compose.yml pull; then
            return 0
        fi
        echo "Pull attempt $i/$max failed. Retrying in 5s..."
        sleep 5
    done
    return 1
}
pull_with_retry || {
    echo "WARNING: docker compose pull failed (network or registry issue)."
    echo "Will try 'up' with whatever images are cached locally."
}
# Verify palworld image isn't corrupted (transient empty init.sh seen in v0.4.0 testing)
if docker image inspect thijsvanloef/palworld-server-docker:latest >/dev/null 2>&1; then
    if ! docker run --rm --entrypoint /bin/true thijsvanloef/palworld-server-docker:latest 2>/dev/null; then
        echo "Palworld image appears corrupt. Re-pulling..."
        docker rmi -f thijsvanloef/palworld-server-docker:latest >/dev/null 2>&1
        docker pull thijsvanloef/palworld-server-docker:latest || echo "WARNING: re-pull failed"
    fi
fi
# Bring the stack up. v1.1.19+ fix: don't silently swallow 'up -d'
# failures. The b14/v1.1.19 test showed `up -d` can exit 0 but
# produce no containers (transient pull race, daemon not fully
# ready, etc.). The old code only logged a WARNING and the install
# marked 'complete' with 0 containers, so the user had to manually
# run `docker compose up -d` after first boot. This is the silent-
# failure class the user flagged as "needs to run absolutely
# without human interaction".
#
# Now we: (1) run `up -d`, (2) wait for the daemon to settle,
# (3) verify at least the webui service is running, (4) retry
# the whole pull+up cycle once if not, (5) mark installation
# complete regardless (the next firstboot can retry) but leave
# a clear marker file if the stack is still down so the splash
# screen can warn the user.
STACK_UP_OK=false
for attempt in 1 2; do
    echo "Stack up attempt $attempt..."
    if docker compose -f compose/docker-compose.yml up -d --build; then
        # Give the daemon a moment to start containers
        sleep 5
        # Verify at least one service is actually running
        if docker compose -f compose/docker-compose.yml ps --services --status running 2>/dev/null | grep -q .; then
            STACK_UP_OK=true
            echo "Docker stack is up."
            break
        else
            echo "WARNING: 'up -d' exited 0 but no services are running (attempt $attempt)."
        fi
    else
        echo "WARNING: 'up -d' failed (attempt $attempt)."
    fi
    if [ $attempt -lt 2 ]; then
        echo "Retrying in 10s (full pull + up cycle)..."
        sleep 10
        pull_with_retry || true
    fi
done
if [ "$STACK_UP_OK" != "true" ]; then
    echo "ERROR: Docker stack did not come up after 2 attempts."
    echo "  The install will mark complete but the WebUI will be unreachable."
    echo "  After first boot, run:"
    echo "    sudo docker compose -f $PPSA_DIR/compose/docker-compose.yml up -d"
    echo "  Or reboot to retry automatically."
    # Leave a marker so the splash screen and firstboot can warn
    touch /opt/ppsa/.stack-down 2>/dev/null || true
fi

# --- Step 4: Install PPSA Wi-Fi onboarding service ---
# v1.1.0 bug: the build script's chroot runs BEFORE the PPSA files are copied
# to /opt/ppsa/, so the wifi-onboard service was never installed.
# Install it here (on first boot) so the hotspot fallback is active.
mark_step 5
echo "[5/9] Installing PPSA Wi-Fi onboarding service..."
if [ -f "$PPSA_DIR/scripts/ppsa-wifi-onboard.sh" ] && [ -f "$PPSA_DIR/scripts/ppsa-wifi-onboard.service" ]; then
    chmod +x "$PPSA_DIR/scripts/ppsa-wifi-onboard.sh"
    cp "$PPSA_DIR/scripts/ppsa-wifi-onboard.service" /etc/systemd/system/ppsa-wifi-onboard.service
    systemctl daemon-reload
    # Disabled by default: NOT `systemctl enable`d (so it doesn't reconfigure
    # networking — new NetworkManager profile, hostapd/dnsmasq — on every
    # single boot) and NOT started here. It reconfigures the Wi-Fi interface
    # every time it runs when no network is saved, which caused real hardware
    # to fail to come back up cleanly on reboot. The WebUI's existing
    # POST /api/wifi/hotspot/start already does `systemctl start
    # ppsa-wifi-onboard.service` on demand, so onboarding is still one click
    # away — it's just opt-in instead of on-by-default.
    echo "  ppsa-wifi-onboard.service: installed (disabled by default — start from WebUI Wi-Fi tab)"
else
    echo "  WARNING: ppsa-wifi-onboard.sh/.service not found at $PPSA_DIR/scripts/"
fi

# --- Step 6: NetBird enrollment (PRIMARY networking path) ---
# As of the v1.3.0-nb line NetBird is the primary overlay: every appliance
# enrolls with its OWN identity via the baked reusable setup key in
# /etc/ppsa/netbird.json (uses wt0 in 100.64.0.0/10). Non-fatal — the boot
# service retries every boot. WireGuard (step 7) is deprecated/off by default.
mark_step 6
echo "[6/9] Enrolling in NetBird network..."

if [ -f "$PPSA_DIR/scripts/ppsa-netbird-up.sh" ]; then
    chmod +x "$PPSA_DIR/scripts/ppsa-netbird-up.sh"
    echo "  Enrolling in NetBird network (if configured)..."
    if timeout 300 "$PPSA_DIR/scripts/ppsa-netbird-up.sh"; then
        if [ -r /run/ppsa-netbird-ip ]; then
            nb_ip=$(cat /run/ppsa-netbird-ip 2>/dev/null || true)
            [ -n "$nb_ip" ] && echo "  NetBird connected: IP $nb_ip"
        fi
    else
        echo "  NetBird enrollment not completed (rc=$?). Will retry on next boot via ppsa-netbird-up.service."
    fi
fi
if [ -f "$PPSA_DIR/scripts/ppsa-netbird-up.service" ]; then
    cp "$PPSA_DIR/scripts/ppsa-netbird-up.service" /etc/systemd/system/ppsa-netbird-up.service
    systemctl daemon-reload
    systemctl enable ppsa-netbird-up.service
    echo "  ppsa-netbird-up.service: installed and enabled"
fi

# --- Step 7: WireGuard (LEGACY / deprecated, off by default) ---
# WireGuard stays baked for fallback but is disabled unless the image was
# built with PPSA_WG_ENABLED=true (=> /etc/ppsa/wireguard.json "enabled":true)
# or a user re-enables it via the WebUI. When disabled: the register.service
# is installed but NOT enabled, and no registration runs.
mark_step 7
echo "[7/9] WireGuard (legacy)..."

# Read config: enabled flag + api url + peer name.
wg_api_url=""; wg_peer_name=""; wg_enabled="false"
if [ -f /etc/ppsa/wireguard.json ]; then
    if command -v python3 >/dev/null 2>&1; then
        eval "$(python3 -c '
import json, sys
try:
    with open("/etc/ppsa/wireguard.json") as f:
        c = json.load(f)
    def esc(v): return str(v).replace(chr(92), chr(92)+chr(92)).replace(chr(34), chr(92)+chr(34)).replace(chr(36), chr(92)+chr(36)).replace(chr(96), chr(92)+chr(96))
    print("wg_enabled="   + esc(str(c.get("enabled", False)).lower()))
    print("wg_api_url="   + esc(c.get("api_url", "")))
    print("wg_peer_name=" + esc(c.get("peer_name", "ppsa-server")))
except Exception:
    pass
' 2>/dev/null)"
    fi
fi

if [ "$wg_enabled" = "true" ]; then
    if [ -n "$wg_api_url" ]; then
        echo "  Auto-registering with wg-easy at $wg_api_url as peer '$wg_peer_name'..."
    fi
    if [ -f "$PPSA_DIR/scripts/ppsa-wireguard-register.sh" ]; then
        chmod +x "$PPSA_DIR/scripts/ppsa-wireguard-register.sh"
        # The register script waits up to 120s internally (PPSA_WG_WAIT_TIMEOUT)
        # for the wg-easy API to come up. The systemd service re-runs on every
        # boot, so transient failures are self-healing. Outer timeout of 300s
        # is just an absolute upper bound so install can't hang forever.
        if timeout 300 "$PPSA_DIR/scripts/ppsa-wireguard-register.sh"; then
            if [ -r /run/ppsa-wireguard-ip ]; then
                wg_assigned_ip=$(cat /run/ppsa-wireguard-ip 2>/dev/null || true)
                if [ -n "$wg_assigned_ip" ]; then
                    echo "  WireGuard connected: assigned IP $wg_assigned_ip (saved to /run/ppsa-wireguard-ip)"
                fi
            fi
        else
            RC=$?
            if [ $RC -eq 124 ]; then
                echo "  WireGuard registration still in progress (timed out at 300s). Will retry on next boot via ppsa-wireguard-register.service."
            else
                echo "  WireGuard registration skipped (rc=$RC). Will retry on next boot."
            fi
        fi
    else
        echo "  ppsa-wireguard-register.sh not found, skipping"
    fi
    # Install + enable the boot re-registration unit.
    if [ -f "$PPSA_DIR/scripts/ppsa-wireguard-register.service" ]; then
        cp "$PPSA_DIR/scripts/ppsa-wireguard-register.service" /etc/systemd/system/ppsa-wireguard-register.service
        systemctl daemon-reload
        systemctl enable ppsa-wireguard-register.service
        echo "  ppsa-wireguard-register.service: installed and enabled"
    else
        echo "  ppsa-wireguard-register.service not found at $PPSA_DIR/scripts/, skipping"
    fi
else
    echo "  WireGuard is deprecated and disabled (NetBird is primary). Skipping registration."
    # Still install the unit so a WebUI re-enable can start it later, but leave
    # it DISABLED so it doesn't run on boot.
    if [ -f "$PPSA_DIR/scripts/ppsa-wireguard-register.service" ]; then
        cp "$PPSA_DIR/scripts/ppsa-wireguard-register.service" /etc/systemd/system/ppsa-wireguard-register.service
        systemctl daemon-reload
        systemctl disable ppsa-wireguard-register.service 2>/dev/null || true
        echo "  ppsa-wireguard-register.service: installed but disabled (re-enable via WebUI to activate WG)"
    fi
    # The seed image bakes wg0.conf and enables wg-quick@wg0 even when WG is
    # disabled (PPSA_WG_ENABLED=false), so the fallback tunnel comes up on
    # every boot regardless of wireguard.json enabled:false.  Stop it and
    # disable it so the legacy WG tunnel stays fully dormant.
    systemctl disable --now wg-quick@wg0 2>/dev/null || true
    # Remove baked conf so the wg-quick systemd generator doesn't
    # recreate the unit on next boot (wg-quick@.service template has
    # WantedBy=multi-user.target, and any .conf in /etc/wireguard/
    # triggers auto-generation on Debian).
    rm -f /etc/wireguard/wg0.conf 2>/dev/null || true
    echo "  wg-quick@wg0: stopped, disabled, and conf removed (fully dormant)"
fi

# PPSA WireGuard status snapshot (host-side timer that writes /etc/ppsa/wg-status.json
# every 5s for the webui container to read — avoids the wg-show-in-container netns issue)
if [ -f "$PPSA_DIR/scripts/ppsa-wg-status-snapshot.sh" ] && \
   [ -f "$PPSA_DIR/scripts/ppsa-wg-status-snapshot.timer" ] && \
   [ -f "$PPSA_DIR/scripts/ppsa-wg-status-snapshot.service" ]; then
    chmod +x "$PPSA_DIR/scripts/ppsa-wg-status-snapshot.sh"
    cp "$PPSA_DIR/scripts/ppsa-wg-status-snapshot.service" /etc/systemd/system/
    cp "$PPSA_DIR/scripts/ppsa-wg-status-snapshot.timer" /etc/systemd/system/
    systemctl daemon-reload
    systemctl enable --now ppsa-wg-status-snapshot.timer
    echo "  ppsa-wg-status-snapshot: installed and enabled"
else
    echo "  ppsa-wg-status-snapshot: scripts not found, skipping"
fi

# PPSA WireGuard manual tunnel apply (host-side path unit that applies
# wg-quick up/down requested by the webui's manual Connect/Disconnect
# buttons — the webui container's own netns can't bring up wg0 itself)
if [ -f "$PPSA_DIR/scripts/ppsa-wg-manual-apply.sh" ] && \
   [ -f "$PPSA_DIR/scripts/ppsa-wg-manual-apply.path" ] && \
   [ -f "$PPSA_DIR/scripts/ppsa-wg-manual-apply.service" ]; then
    chmod +x "$PPSA_DIR/scripts/ppsa-wg-manual-apply.sh"
    cp "$PPSA_DIR/scripts/ppsa-wg-manual-apply.service" /etc/systemd/system/
    cp "$PPSA_DIR/scripts/ppsa-wg-manual-apply.path" /etc/systemd/system/
    systemctl daemon-reload
    systemctl enable --now ppsa-wg-manual-apply.path
    echo "  ppsa-wg-manual-apply: installed and enabled"
else
    echo "  ppsa-wg-manual-apply: scripts not found, skipping"
fi

# PPSA Docker Compose stack: re-apply on every boot (safety net for
# Docker container-metadata loss after an unclean shutdown/power loss —
# restart: unless-stopped alone can't help if Docker forgot the
# containers existed at all; docker compose up -d is idempotent so this
# is a no-op when the stack is already healthy).
if [ -f "$PPSA_DIR/scripts/ppsa-docker-compose.service" ]; then
    cp "$PPSA_DIR/scripts/ppsa-docker-compose.service" /etc/systemd/system/
    systemctl daemon-reload
    systemctl enable ppsa-docker-compose.service
    echo "  ppsa-docker-compose: installed and enabled"
else
    echo "  ppsa-docker-compose.service not found, skipping"
fi

# --- Step 8: Firewall ---
mark_step 8
echo "[8/9] Configuring firewall..."
ufw --force enable 2>/dev/null || true
ufw default deny incoming
ufw default allow outgoing
ufw allow 51820/udp  # WireGuard tunnel (admin)
ufw allow 51830/udp  # WireGuard tunnel (PPSA gaming)
# Game (8211/udp, 27015/udp, 8212/tcp), Web UI (8080/tcp), and WG Dashboard
# (10086/tcp) are intentionally NOT opened here. They are reachable only via
# the WG_FRIENDS iptables chain, which is jumped from the NetBird overlay
# (100.64.0.0/10) — never directly from LAN/WAN.
# Docker-published ports bypass UFW via their own iptables DNAT rules, so
# drop LAN/WAN traffic in the DOCKER-USER chain; overlay is the only source.
for _port in 8080 8211 8212 10086 27015 25575; do
    iptables -I DOCKER-USER -p tcp --dport $_port ! -s 100.64.0.0/10 -j DROP 2>/dev/null || true
done
for _port in 8211 27015; do
    iptables -I DOCKER-USER -p udp --dport $_port ! -s 100.64.0.0/10 -j DROP 2>/dev/null || true
done

# SSH (22, 10022): LAN/WAN exposure is opt-in, baked at build time into
# /etc/ppsa/network-policy.json (expose_ssh_lan, set via PPSA_EXPOSE_SSH_LAN
# at build). Default is false — SSH stays reachable only through the
# WG_FRIENDS chain (port 22 is in firewall.json's default allow-list), so a
# stock build broadcasts nothing on the LAN, only the WireGuard network.
expose_ssh_lan="false"
if [ -f /etc/ppsa/network-policy.json ] && command -v python3 >/dev/null 2>&1; then
    expose_ssh_lan=$(python3 -c '
import json
try:
    with open("/etc/ppsa/network-policy.json") as f:
        print(str(json.load(f).get("expose_ssh_lan", False)).lower())
except Exception:
    print("false")
' 2>/dev/null || echo "false")
fi
if [ "$expose_ssh_lan" = "true" ]; then
    ufw allow 22/tcp     # SSH (primary) — LAN/WAN, opt-in via build flag
    ufw allow 10022/tcp  # SSH (alternate port) — LAN/WAN, opt-in via build flag
    echo "  SSH: exposed on LAN/WAN (expose_ssh_lan=true) + WireGuard"
else
    echo "  SSH: WireGuard-only (expose_ssh_lan=false); not opened on LAN/WAN"
fi

# Install ppsa-firewall-restore.service so the WG_FRIENDS chain survives
# reboots. ppsa-firewall-apply.sh writes its rules to /etc/ppsa/ (because
# /etc/iptables is RO when called from the webui chroot); this service
# iptables-restore's them at boot.
if [ -f "$PPSA_DIR/scripts/ppsa-firewall-restore.service" ]; then
  cp "$PPSA_DIR/scripts/ppsa-firewall-restore.service" /etc/systemd/system/ppsa-firewall-restore.service
  systemctl daemon-reload
  systemctl enable ppsa-firewall-restore.service
  echo "  ppsa-firewall-restore.service: installed and enabled"
fi

# Deploy the WG_FRIENDS chain (manageable from the WebUI). Non-fatal: the
# WebUI can re-apply later, and the host may not have WireGuard up yet.
if [ -f "$PPSA_DIR/scripts/ppsa-firewall-apply.sh" ]; then
  chmod +x "$PPSA_DIR/scripts/ppsa-firewall-apply.sh"
  "$PPSA_DIR/scripts/ppsa-firewall-apply.sh" || echo "  ppsa-firewall-apply failed (rc=$?) — can be re-run from WebUI"
else
  echo "  ppsa-firewall-apply.sh not found, skipping WG_FRIENDS setup"
fi

# --- Step 9: Mark complete ---
mark_step 9
echo "[9/9] Marking installation complete..."
date > "$FLAG_FILE"

# Get IP for summary (fallback to hostname if no non-loopback address)
IP=$(ip -4 addr show 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v '127.0.0.1' | head -1 || true)
[ -z "$IP" ] && IP=$(hostname -I 2>/dev/null | awk '{print $1}' || true)
[ -z "$IP" ] && IP="<this-machine>"

echo ""
echo "=== PPSA Setup Complete ==="
echo ""
echo "  Web UI:       http://$IP:8080"
echo "  WireGuard UI: http://$IP:10086"
echo "  SSH:          ssh ppsa@$IP  (password: ppsa)"
echo ""
# Warn loudly if the docker stack didn't come up (we left a marker
# in step 4). The user has to either reboot or run docker compose up
# manually; the splash makes that obvious.
if [ -f /opt/ppsa/.stack-down ]; then
    echo "  !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    echo "  !  WARNING: Docker stack did not start. WebUI is   !"
    echo "  !  unreachable. To recover, SSH in and run:        !"
    echo "  !    sudo docker compose -f $PPSA_DIR/compose/docker-compose.yml up -d"
    echo "  !  Or simply reboot to retry automatically.        !"
    echo "  !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    echo ""
fi
echo "  Open the Web UI to complete first-boot configuration."
echo "  Log in with: admin / admin"
echo ""
