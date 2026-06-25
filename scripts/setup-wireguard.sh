#!/usr/bin/env bash
# =============================================================================
# PPSA - WireGuard Client Setup
# =============================================================================
# Configures the WireGuard tunnel from the PPSA appliance to the Oracle VPS
# gateway. Run this after setting up the VPS with oracle/vps-setup.sh.
#
# Usage:
#   sudo bash scripts/setup-wireguard.sh \
#     --vps-endpoint <VPS_IP>:51820 \
#     --vps-public-key <VPS_PUBLIC_KEY>
#
# The script generates a local key pair and outputs the public key to add
# to the VPS. Alternatively, pass --ppsa-private-key and --ppsa-public-key
# to use pre-generated keys.
#
# Or use the web UI at /api/wireguard/connect
# =============================================================================

set -euo pipefail

PPSA_DIR="/opt/ppsa"
WG_DIR="/etc/wireguard"
WG_INTERFACE="wg0"
WG_CONF="$WG_DIR/$WG_INTERFACE.conf"

VPS_ENDPOINT=""
VPS_PUBKEY=""
PPSA_PRIV=""
PPSA_PUB=""

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# --- Parse args ---
while [[ $# -gt 0 ]]; do
    case "$1" in
        --vps-endpoint) VPS_ENDPOINT="$2"; shift 2 ;;
        --vps-public-key) VPS_PUBKEY="$2"; shift 2 ;;
        --ppsa-private-key) PPSA_PRIV="$2"; shift 2 ;;
        --ppsa-public-key) PPSA_PUB="$2"; shift 2 ;;
        --help) echo "Usage: $0 --vps-endpoint <IP:51820> --vps-public-key <key>"; exit 0 ;;
        *) echo "Unknown: $1"; exit 1 ;;
    esac
done

if [ -z "$VPS_ENDPOINT" ] || [ -z "$VPS_PUBKEY" ]; then
    echo -e "${RED}ERROR: --vps-endpoint and --vps-public-key are required${NC}"
    exit 1
fi

if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}ERROR: Must be run as root${NC}"
    exit 1
fi

echo -e "${GREEN}=== PPSA WireGuard Client Setup ===${NC}"

# --- Generate or use provided keys ---
if [ -n "$PPSA_PRIV" ] && [ -n "$PPSA_PUB" ]; then
    echo "[1/4] Using provided keys..."
    echo "$PPSA_PRIV" > "$WG_DIR/ppsa.key"
    chmod 600 "$WG_DIR/ppsa.key"
else
    echo "[1/4] Generating WireGuard keys..."
    wg genkey | tee "$WG_DIR/ppsa.key" | wg pubkey > "$WG_DIR/ppsa.pub"
    chmod 600 "$WG_DIR/ppsa.key"
    PPSA_PUB=$(cat "$WG_DIR/ppsa.pub")
fi

PPSA_PRIV=$(cat "$WG_DIR/ppsa.key")

# --- Create wg0.conf ---
echo "[2/4] Creating $WG_CONF..."
# ponytail: static tunnel config, no PresharedKey. Add if forward secrecy needed.
cat > "$WG_CONF" <<EOF
[Interface]
PrivateKey = $PPSA_PRIV
Address = 10.0.0.2/32
DNS = 1.1.1.1, 8.8.8.8

# Traffic to the tunnel
Table = auto
FwMark = 0x51820

[Peer]
PublicKey = $VPS_PUBKEY
Endpoint = $VPS_ENDPOINT
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF
chmod 600 "$WG_CONF"

# --- Start tunnel ---
echo "[3/4] Starting WireGuard tunnel..."
systemctl enable wg-quick@"$WG_INTERFACE" 2>/dev/null || true
wg-quick down "$WG_INTERFACE" 2>/dev/null || true
wg-quick up "$WG_INTERFACE"

# --- Verify ---
echo "[4/4] Verifying connection..."
sleep 2
if wg show "$WG_INTERFACE" | grep -q "latest handshake"; then
    echo -e "${GREEN}Tunnel connected!${NC}"
else
    echo -e "${YELLOW}Tunnel configured but waiting for handshake.${NC}"
    echo "Make sure the VPS has this PPSA public key added:"
fi

# --- Output ---
echo ""
echo -e "${GREEN}=== WireGuard Client Setup Complete ===${NC}"
echo ""
echo "  PPSA Public Key: $(cat "$WG_DIR/ppsa.pub" 2>/dev/null || echo 'unknown')"
echo "  PPSA IP:         10.0.0.2"
echo "  VPS Endpoint:    $VPS_ENDPOINT"
echo ""
echo "  Next step: Add the PPSA public key to the VPS's wg0.conf:"
echo "    ssh user@vps 'sudo sed -i \"s|__PPSA_PUBLIC_KEY__|$(cat "$WG_DIR/ppsa.pub")|\" /etc/wireguard/wg0.conf && sudo wg-quick down wg0 && sudo wg-quick up wg0'"
echo ""
