#!/bin/bash
# ppsa-wireguard-register.sh
#
# Auto-register this PPSA host as a peer in the PPSA WireGuard gaming network.
#
# Flow:
#   1. Read config from /etc/ppsa/wireguard.json
#   2. HTTP Basic auth to wg-easy API
#   3. Check if peer with our hostname already exists
#   4. If not, create the peer via API
#   5. Download the .conf file
#   6. Install to /etc/wireguard/wg0.conf
#   7. Bring up wg-quick@wg0
#   8. Persist via systemd
#   9. Save assigned IP to /run/ppsa-wireguard-ip for use by other services
#
# Config file (/etc/ppsa/wireguard.json):
#   {
#     "api_url": "http://wg.pleaseee.eu.org:51831",
#     "api_user": "admin",
#     "api_password": "...",
#     "peer_name": "ppsa-server"  // optional, default: ppsa-$(hostname -s)
#   }
#
# Exit codes:
#   0 = success
#   1 = config file missing or invalid
#   2 = API unreachable
#   3 = authentication failed
#   4 = peer creation failed
#   5 = wg-quick failed

set -Eeuo pipefail

PPSA_VERSION="1.0.0"
SCRIPT_NAME="$(basename "$0")"
LOG_TAG="[${SCRIPT_NAME}]"

CONFIG_FILE="/etc/ppsa/wireguard.json"
WG_CONF="/etc/wireguard/wg0.conf"
WG_STATE="/run/ppsa-wireguard-ip"
WG_INTERFACE="wg0"
WG_TABLE_ID=51820

log() { echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) ${LOG_TAG} $*"; }
fail() { log "ERROR: $*"; exit "${2:-1}"; }

# ============================================================================
# 1. Read config
# ============================================================================
log "PPSA WireGuard auto-registration v${PPSA_VERSION}"

if [[ ! -f "${CONFIG_FILE}" ]]; then
    log "Config file ${CONFIG_FILE} not found"
    log "Create it with: { \"api_url\": \"...\", \"api_user\": \"...\", \"api_password\": \"...\" }"
    exit 1
fi

# Read config (lightweight JSON parsing with grep/sed — no jq dependency)
API_URL=$(grep -oP '"api_url"\s*:\s*"\K[^"]+' "${CONFIG_FILE}" 2>/dev/null || true)
API_USER=$(grep -oP '"api_user"\s*:\s*"\K[^"]+' "${CONFIG_FILE}" 2>/dev/null || true)
API_PASS=$(grep -oP '"api_password"\s*:\s*"\K[^"]+' "${CONFIG_FILE}" 2>/dev/null || true)
PEER_NAME=$(grep -oP '"peer_name"\s*:\s*"\K[^"]+' "${CONFIG_FILE}" 2>/dev/null || true)
ENABLED=$(grep -oP '"enabled"\s*:\s*\K(true|false)' "${CONFIG_FILE}" 2>/dev/null || true)

if [[ -z "${API_URL}" || -z "${API_USER}" || -z "${API_PASS}" ]]; then
    fail "Missing api_url, api_user, or api_password in ${CONFIG_FILE}" 1
fi

if [[ "${ENABLED}" == "false" ]]; then
    log "WireGuard registration disabled in config (enabled=false)"
    exit 0
fi

# Default peer name
PEER_NAME="${PEER_NAME:-ppsa-$(hostname -s)}"
log "Using peer name: ${PEER_NAME}"

# ============================================================================
# 2. Build auth header
# ============================================================================
AUTH_HEADER="Authorization: Basic $(printf '%s:%s' "${API_USER}" "${API_PASS}" | base64 -w0)"

# ============================================================================
# 3. Test API reachability
# ============================================================================
log "Testing API at ${API_URL}..."
if ! curl -fsS -m 10 -o /dev/null -H "${AUTH_HEADER}" "${API_URL}/api/client"; then
    log "API unreachable or auth failed at ${API_URL}"
    log "Check that wg-easy is running and credentials are correct"
    log "(wireguard can be configured later via WebUI)"
    exit 2
fi
log "API reachable"

# ============================================================================
# 4. Check if peer already exists
# ============================================================================
log "Checking if peer '${PEER_NAME}' already exists..."

EXISTING_ID=$(curl -fsS -m 10 -H "${AUTH_HEADER}" "${API_URL}/api/client" 2>/dev/null \
    | python3 -c "
import sys, json
try:
    clients = json.load(sys.stdin)
    for c in clients:
        if c.get('name') == '${PEER_NAME}':
            print(c['id'])
            break
except Exception as e:
    print('', file=sys.stderr)
    sys.exit(0)
" 2>/dev/null || true)

if [[ -n "${EXISTING_ID}" ]]; then
    log "Peer '${PEER_NAME}' already exists (id=${EXISTING_ID})"
    PEER_ID="${EXISTING_ID}"
else
    # ========================================================================
    # 5. Create peer
    # ========================================================================
    log "Creating peer '${PEER_NAME}'..."

    # expiresAt: 100 years from now (effectively never, but required by API)
    EXPIRES_AT=$(date -u -d '+100 years' '+%Y-%m-%dT%H:%M:%S.000Z')

    CREATE_RESPONSE=$(curl -fsS -m 10 \
        -H "${AUTH_HEADER}" \
        -H "Content-Type: application/json" \
        -X POST \
        -d "{\"name\": \"${PEER_NAME}\", \"expiresAt\": \"${EXPIRES_AT}\"}" \
        "${API_URL}/api/client" 2>&1) || {
        log "Peer creation failed: ${CREATE_RESPONSE}"
        exit 4
    }
    log "Peer created"

    # Find the new peer ID
    PEER_ID=$(curl -fsS -m 10 -H "${AUTH_HEADER}" "${API_URL}/api/client" 2>/dev/null \
        | python3 -c "
import sys, json
try:
    clients = json.load(sys.stdin)
    for c in clients:
        if c.get('name') == '${PEER_NAME}':
            print(c['id'])
            break
except Exception:
    pass
" 2>/dev/null || true)

    if [[ -z "${PEER_ID}" ]]; then
        fail "Could not find new peer ID after creation" 4
    fi
    log "New peer id: ${PEER_ID}"
fi

# ============================================================================
# 6. Download configuration
# ============================================================================
log "Downloading configuration for peer ${PEER_ID}..."

mkdir -p /etc/wireguard
chmod 700 /etc/wireguard

if ! curl -fsS -m 10 -H "${AUTH_HEADER}" \
        "${API_URL}/api/client/${PEER_ID}/configuration" \
        -o "${WG_CONF}"; then
    fail "Failed to download peer configuration" 4
fi
chmod 600 "${WG_CONF}"
log "Configuration saved to ${WG_CONF}"

# ============================================================================
# 7. Bring up the interface
# ============================================================================
log "Bringing up ${WG_INTERFACE}..."
if ! wg-quick up "${WG_INTERFACE}"; then
    fail "wg-quick up failed" 5
fi
log "${WG_INTERFACE} is up"

# ============================================================================
# 8. Persist via systemd
# ============================================================================
log "Enabling wg-quick@${WG_INTERFACE} to start on boot..."
systemctl enable "wg-quick@${WG_INTERFACE}.service" >/dev/null 2>&1 || \
    log "WARN: systemctl enable failed (might be already enabled)"

# ============================================================================
# 9. Save assigned IP for other services
# ============================================================================
ASSIGNED_IP=$(ip -4 addr show "${WG_INTERFACE}" 2>/dev/null \
    | grep -oP 'inet \K[0-9.]+' \
    | head -1 || true)

if [[ -n "${ASSIGNED_IP}" ]]; then
    echo "${ASSIGNED_IP}" > "${WG_STATE}"
    log "Assigned WireGuard IP: ${ASSIGNED_IP} (saved to ${WG_STATE})"
fi

# ============================================================================
# 10. Verify handshake
# ============================================================================
sleep 2
HANDSHAKE=$(wg show "${WG_INTERFACE}" latest-handshakes 2>/dev/null | awk '{print $2}' | head -1 || echo "0")
if [[ "${HANDSHAKE}" != "0" ]]; then
    log "WireGuard handshake successful (peer is reachable)"
else
    log "WARN: No handshake yet (peer might not be connected from the other side)"
fi

log "PPSA WireGuard registration complete"
log "  Peer:      ${PEER_NAME}"
log "  Peer ID:   ${PEER_ID}"
log "  Endpoint:  ${API_URL}"
log "  Interface: ${WG_INTERFACE} (${ASSIGNED_IP:-no IP})"

exit 0
