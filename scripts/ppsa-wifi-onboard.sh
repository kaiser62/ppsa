#!/bin/bash
# =============================================================================
# PPSA - Wi-Fi Onboarding Service
# =============================================================================
# Manages the Wi-Fi connection lifecycle:
# 1. On first boot (no Wi-Fi configured): start a fallback hotspot
#    "PPSA-Setup" so a user can connect to the PPSA web UI via Wi-Fi
# 2. Once user picks a Wi-Fi network via the web UI, stop the hotspot
#    and connect the system to that network
# 3. Auto-reconnect on reboot (via NetworkManager)
# 4. If no Wi-Fi hardware present, exit silently
# =============================================================================

set -uo pipefail

LOG=/var/log/ppsa-wifi.log
exec >> "$LOG" 2>&1
echo "=== ppsa-wifi-onboard $(date) ==="

# --- Config ---
WIFI_CONFIG="/etc/ppsa/wifi.conf"        # SSID + PSK saved here after selection
HOTSPOT_SSID="PPSA-Setup"
HOTSPOT_PASS="ppsa-setup-2026"           # 14+ chars, WPA2 minimum
HOTSPOT_IP="192.168.50.1"
HOSTAPD_CONF="/etc/hostapd/hostapd-ppsa.conf"
DNSMASQ_CONF="/etc/dnsmasq.d/ppsa-hotspot.conf"
HOTSPOT_IF="wlan0"                       # default; will detect
STATE_FILE="/var/lib/ppsa/wifi-state"

# --- Helpers ---
log()  { echo "[$(date +%H:%M:%S)] $*"; }
have_wifi() { nmcli -t -f DEVICE,TYPE device 2>/dev/null | grep -q ":wifi$"; }
wifi_iface() { nmcli -t -f DEVICE,TYPE,STATE device 2>/dev/null | awk -F: '$2=="wifi" && $3=="connected"{print $1; exit}'; }

# --- Skip if no Wi-Fi hardware ---
if ! have_wifi; then
    log "No Wi-Fi hardware detected. Exiting."
    exit 0
fi

mkdir -p "$(dirname "$WIFI_CONFIG")" "$(dirname "$STATE_FILE")"

# --- Skip if already connected to a Wi-Fi network (NetworkManager handles it) ---
CURRENT_IF=$(wifi_iface)
if [ -n "$CURRENT_IF" ]; then
    log "Already connected via $CURRENT_IF. Exiting."
    exit 0
fi

# --- Skip if hotspot is already running ---
if systemctl is-active hostapd >/dev/null 2>&1 || pgrep -f "hostapd.*ppsa" >/dev/null 2>&1; then
    log "Hotspot already active. Exiting."
    exit 0
fi

# --- Skip if user already configured Wi-Fi (file exists) ---
if [ -f "$WIFI_CONFIG" ]; then
    . "$WIFI_CONFIG"
    if [ -n "${SSID:-}" ] && [ -n "${PSK:-}" ]; then
        log "Saved Wi-Fi config found: $SSID. Attempting to connect..."
        WIFI_IF=$(nmcli -t -f DEVICE,TYPE device 2>/dev/null | awk -F: '$2=="wifi"{print $1; exit}')
        if [ -n "$WIFI_IF" ]; then
            nmcli dev wifi connect "$SSID" password "$PSK" ifname "$WIFI_IF" 2>&1 | log
            nmcli con up "$SSID" 2>/dev/null | log
        fi
        # If still not connected, fall through to hotspot
        if [ -z "$(wifi_iface)" ]; then
            log "Saved Wi-Fi didn't connect. Falling through to hotspot."
        else
            log "Connected to $SSID."
            exit 0
        fi
    fi
fi

# --- Start fallback hotspot for onboarding ---
log "No Wi-Fi configured. Starting setup hotspot..."

# Detect the Wi-Fi interface
WIFI_IF=$(nmcli -t -f DEVICE,TYPE device 2>/dev/null | awk -F: '$2=="wifi"{print $1; exit}')
if [ -z "$WIFI_IF" ]; then
    WIFI_IF=$(iw dev 2>/dev/null | awk '/Interface/{print $2; exit}')
fi
if [ -z "$WIFI_IF" ]; then
    log "No Wi-Fi interface found."
    exit 1
fi
log "Using interface: $WIFI_IF"

# Generate hostapd config
cat > "$HOSTAPD_CONF" <<EOF
interface=$WIFI_IF
driver=nl80211
ssid=$HOTSPOT_SSID
hw_mode=g
channel=7
wmm_enabled=0
macaddr_acl=0
auth_algs=1
ignore_broadcast_ssid=0
wpa=2
wpa_passphrase=$HOTSPOT_PASS
wpa_key_mgmt=WPA-PSK
wpa_pairwise=TKIP
rsn_pairwise=CCMP
EOF

# Static IP for the hotspot interface
nmcli con add type ethernet ifname "$WIFI_IF" con-name ppsa-hotspot autoconnect no \
    ipv4.method manual ipv4.addresses "$HOTSPOT_IP/24" ipv4.gateway "$HOTSPOT_IP" 2>/dev/null | log
nmcli con up ppsa-hotspot 2>&1 | log

# dnsmasq DHCP for hotspot clients
mkdir -p "$(dirname "$DNSMASQ_CONF")"
cat > "$DNSMASQ_CONF" <<EOF
interface=$WIFI_IF
bind-interfaces
dhcp-range=192.168.50.10,192.168.50.100,12h
dhcp-option=3,$HOTSPOT_IP
dhcp-option=6,$HOTSPOT_IP
address=/#/$HOTSPOT_IP
log-queries
log-dhcp
log-facility=/var/log/ppsa-dnsmasq.log
EOF

# Start services
systemctl unmask hostapd 2>/dev/null || true
systemctl disable hostapd 2>/dev/null || true
# Run hostapd in foreground with our config
nohup hostapd -B "$HOSTAPD_CONF" >> "$LOG" 2>&1
sleep 2
nohup dnsmasq -C "$DNSMASQ_CONF" >> "$LOG" 2>&1

# Mark state
echo "hotspot" > "$STATE_FILE"
log "Hotspot '$HOTSPOT_SSID' started on $WIFI_IF ($HOTSPOT_IP)."
log "Users can connect with password '$HOTSPOT_PASS' and visit http://192.168.50.1/"

exit 0
