#!/usr/bin/env bash
# =============================================================================
# PPSA - Oracle VPS One-Command Setup
# =============================================================================
# Run this on a fresh Oracle Cloud VPS (Ubuntu 22.04+ / Debian 12+).
# It sets up WireGuard server + NAT + port forwarding for the PPSA appliance.
#
# Usage:
#   # Using cloud-init: paste oracle/cloud-init.yml during instance creation
#
#   # On existing VPS — get PPSA public key from Web UI or setup-wireguard.sh:
#   sudo bash oracle/vps-setup.sh --ppsa-public-key <PPSA_PUBLIC_KEY>
#
#   # Without key (add it later manually):
#   curl -fsSL https://raw.githubusercontent.com/.../oracle/vps-setup.sh | sudo bash
# =============================================================================

set -euo pipefail

PPSA_PUBKEY="${1:-}"  # optional: --ppsa-public-key <key>

echo "=== PPSA - Oracle VPS Setup ==="
echo ""

# --- Check root ---
if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: This script must be run as root (sudo)."
    exit 1
fi

# --- Parse args ---
while [[ $# -gt 0 ]]; do
    case "$1" in
        --ppsa-public-key) PPSA_PUBKEY="$2"; shift 2 ;;
        --help) echo "Usage: $0 [--ppsa-public-key <key>]"; exit 0 ;;
        *) echo "Unknown: $1"; exit 1 ;;
    esac
done

# --- Detect OS ---
if command -v apt-get &>/dev/null; then
    PKG_INSTALL="apt-get install -y"
    PKG_UPDATE="apt-get update -qq"
elif command -v yum &>/dev/null; then
    PKG_INSTALL="yum install -y"
    PKG_UPDATE="yum update -qq"
else
    echo "ERROR: Unsupported OS. Debian/Ubuntu or RHEL-based only."
    exit 1
fi

# --- Install packages ---
echo "[1/5] Installing WireGuard and nftables..."
$PKG_UPDATE
$PKG_INSTALL wireguard wireguard-tools nftables

# --- Generate server keys ---
echo "[2/5] Generating WireGuard keys..."
WG_PRIV=$(wg genkey)
WG_PUB=$(echo "$WG_PRIV" | wg pubkey)

# --- Build wg0.conf ---
echo "[3/5] Configuring WireGuard..."
PEER_CONFIG=""
if [ -n "$PPSA_PUBKEY" ]; then
    echo "  Using provided PPSA public key."
    PEER_CONFIG="
# PPSA Appliance
[Peer]
PublicKey = $PPSA_PUBKEY
AllowedIPs = 10.0.0.2/32
PersistentKeepalive = 25"
else
    echo "  No PPSA key provided. Add it later (see output below)."
fi

# If the config already exists (from cloud-init), update it
if [ -f /etc/wireguard/wg0.conf ]; then
    # Replace placeholder or add peer
    if grep -q "__PPSA_PUBLIC_KEY__" /etc/wireguard/wg0.conf && [ -n "$PPSA_PUBKEY" ]; then
        sed -i "s|__PPSA_PUBLIC_KEY__|$PPSA_PUBKEY|" /etc/wireguard/wg0.conf
        echo "  Updated existing wg0.conf with PPSA key."
    fi
    # Ensure private key is correct
    sed -i "s|PrivateKey = .*|PrivateKey = $WG_PRIV|" /etc/wireguard/wg0.conf
else
    cat > /etc/wireguard/wg0.conf <<WGEOF
[Interface]
PrivateKey = $WG_PRIV
Address = 10.0.0.1/24
ListenPort = 51820
SaveConfig = false
$PEER_CONFIG
WGEOF
fi
chmod 600 /etc/wireguard/wg0.conf

# --- Configure nftables ---
echo "[4/5] Configuring firewall and NAT..."
mkdir -p /etc
cat > /etc/nftables.conf <<'NFTEOF'
table ip nat {
    chain prerouting {
        type nat hook prerouting priority dstnat; policy accept;
        tcp dport { 8211, 8212, 27015, 25575 } dnat to 10.0.0.2
        udp dport { 8211, 8212, 27015 } dnat to 10.0.0.2
    }
    chain postrouting {
        type nat hook postrouting priority srcnat; policy accept;
        oifname "eth0" masquerade
    }
}
table ip filter {
    chain input {
        type filter hook input priority filter; policy drop;
        ct state established,related accept
        ct state invalid drop
        iifname "lo" accept
        tcp dport 22 accept
        udp dport 51820 accept
    }
    chain forward {
        type filter hook forward priority filter; policy drop;
        ct state established,related accept
        iifname "wg0" accept
    }
}
NFTEOF

# --- Enable IP forwarding ---
echo "[5/5] Enabling IP forwarding and services..."
echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-ppsa.conf
echo "net.ipv6.conf.all.forwarding=1" >> /etc/sysctl.d/99-ppsa.conf
sysctl -p /etc/sysctl.d/99-ppsa.conf

systemctl enable nftables
systemctl restart nftables
systemctl enable wg-quick@wg0
wg-quick down wg0 2>/dev/null || true
wg-quick up wg0

# --- Output ---
VPS_PUBLIC_IP=$(curl -4 -s ifconfig.me 2>/dev/null || echo "unknown")
echo ""
echo "=== Setup Complete ==="
echo ""
echo "  Server Public Key: $WG_PUB"
echo "  Server Endpoint:   $VPS_PUBLIC_IP:51820"
echo ""
if [ -z "$PPSA_PUBKEY" ]; then
    echo "  ⚠ No PPSA public key was provided."
    echo "  After setting up WireGuard on the PPSA appliance:"
    echo "    1. Get the PPSA public key from the web UI or:"
    echo "       sudo cat /etc/wireguard/ppsa.pub"
    echo "    2. Add it to this VPS:"
    echo "       ssh root@$VPS_PUBLIC_IP 'wg set wg0 peer <PPSA_PUB_KEY> allowed-ips 10.0.0.2/32 persistent-keepalive 25'"
    echo ""
fi
echo "  PPSA Web UI: Configure the tunnel at http://<usb-ip>:8080 (WireGuard tab)"
echo ""
