#!/usr/bin/env bash
# =============================================================================
# PPSA - First Boot Configuration Wizard
# =============================================================================
# Run from the web UI after first login to configure the appliance.
# This sets admin password, server name, WireGuard, timezone, etc.
#
# Run: sudo bash scripts/first-boot.sh
# Or use the web UI setup wizard (/api/setup)
# =============================================================================

set -euo pipefail

PPSA_DIR="/opt/ppsa"
ENV_FILE="$PPSA_DIR/.env"
FLAG_FILE="$PPSA_DIR/.configured"

if [ -f "$FLAG_FILE" ] && [ "${1:-}" != "--force" ]; then
    echo "Configuration already complete."
    echo "Run with --force to reconfigure."
    exit 0
fi

echo "=== PPSA First Boot Configuration ==="

# --- Prompt for config ---
read -rp "Server name [My Palworld Server]: " SERVER_NAME
SERVER_NAME=${SERVER_NAME:-My Palworld Server}

read -rsp "Admin password (web UI + Palworld admin): " ADMIN_PASSWORD
echo ""
ADMIN_PASSWORD=${ADMIN_PASSWORD:-ppsa123}

read -rp "Timezone [UTC]: " TZ
TZ=${TZ:-UTC}

read -rp "Max players [16]: " MAX_PLAYERS
MAX_PLAYERS=${MAX_PLAYERS:-16}

# --- WireGuard ---
echo ""
echo "--- WireGuard Configuration (optional) ---"
read -rp "Upload wg0.conf path (leave blank to skip): " WG_CONF
if [ -n "$WG_CONF" ] && [ -f "$WG_CONF" ]; then
    mkdir -p /etc/wireguard
    cp "$WG_CONF" /etc/wireguard/wg0.conf
    chmod 600 /etc/wireguard/wg0.conf
    systemctl enable wg-quick@wg0 2>/dev/null || true
    wg-quick up wg0 2>/dev/null || echo "Check wg0.conf for errors"
    echo "WireGuard configured."
fi

# --- Write .env ---
cat > "$ENV_FILE" <<EOF
SERVER_NAME=$SERVER_NAME
SERVER_DESCRIPTION=My PPSA Server
SERVER_PASSWORD=
ADMIN_PASSWORD=$ADMIN_PASSWORD
MAX_PLAYERS=$MAX_PLAYERS
TZ=$TZ
COMMUNITY=false
RESTAPI_ENABLED=true
RESTAPI_PORT=8212
RCON_ENABLED=true
RCON_PORT=25575
EOF

# --- Restart stack ---
cd "$PPSA_DIR"
docker compose -f compose/docker-compose.yml up -d

# --- Update MOTD ---
IP=$(ip -4 addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v '127.0.0.1' | head -1)
cat > /etc/motd <<MOTDEOF
╔══════════════════════════════════════════════════╗
║     PPSA - Palworld Server Appliance             ║
║     Server: $SERVER_NAME              ║
║     Web UI: http://$IP:8080                      ║
║     Manage everything from the browser.          ║
╚══════════════════════════════════════════════════╝
MOTDEOF

date > "$FLAG_FILE"

echo ""
echo "=== Configuration Complete ==="
echo "Server:  $SERVER_NAME"
echo "Web UI:  http://$IP:8080"
echo "Login:   admin / $ADMIN_PASSWORD"
echo ""
echo "The first-boot wizard will not run again."
