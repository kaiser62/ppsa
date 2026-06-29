#!/bin/bash
# ppsa-wireguard-register.sh
#
# Auto-register this PPSA host as a peer in the PPSA WireGuard gaming network.
#
# Flow:
#   1. Read config from /etc/ppsa/wireguard.json
#   2. Session-cookie auth to wg-easy API (POST /api/session)
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
#     "enabled": true,
#     "api_url": "http://wg.pleaseee.eu.org:51831",
#     "api_user": "admin",
#     "api_password": "...",
#     "peer_name": "ppsa-server",      // optional, default: ppsa-$(hostname -s)
#     "preferred_ip": "10.8.0.2"       // optional; wg-easy v15 may ignore on create
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

# resolvconf lives in /sbin /usr/sbin; not on root's PATH on minimal Debian.
export PATH="/sbin:/usr/sbin:${PATH}"

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

# Read config (use python3 for proper JSON parsing — grep/sed regex is broken
# on JSON values that contain escaped quotes or backslashes).
# Falls back to grep if python3 is unavailable.
if command -v python3 >/dev/null 2>&1; then
    # Write parsed values to a tmp file (avoid eval security issues).
    # The python script is written to a separate file first to avoid
    # bash heredoc backslash/escape issues with newlines and quotes.
    CONFIG_VALS=$(mktemp)
    PARSER_SCRIPT=$(mktemp --suffix=.py)
    cat > "${PARSER_SCRIPT}" <<'PYEOF'
import json, sys
try:
    with open(sys.argv[1]) as f:
        c = json.load(f)
    with open(sys.argv[2], 'w') as out:
        out.write('API_URL=' + repr(c.get('api_url', '')) + '\n')
        out.write('API_USER=' + repr(c.get('api_user', '')) + '\n')
        out.write('API_PASS=' + repr(c.get('api_password', '')) + '\n')
        out.write('PEER_NAME=' + repr(c.get('peer_name', '')) + '\n')
        out.write('PREFERRED_IP=' + repr(c.get('preferred_ip', '')) + '\n')
        out.write('ENABLED=' + repr(str(c.get('enabled', False)).lower()) + '\n')
except Exception as e:
    sys.stderr.write('JSON parse error: ' + str(e) + '\n')
    sys.exit(1)
PYEOF
    python3 "${PARSER_SCRIPT}" "${CONFIG_FILE}" "${CONFIG_VALS}" || {
        rm -f "${CONFIG_VALS}" "${PARSER_SCRIPT}"
        log "Failed to parse ${CONFIG_FILE} as JSON"
        fail "Invalid config file" 1
    }
    # shellcheck disable=SC1090
    . "${CONFIG_VALS}"
    rm -f "${CONFIG_VALS}" "${PARSER_SCRIPT}"
else
    # Fallback: grep-based parsing (broken on escaped chars but better than nothing)
    log "WARN: python3 not available, using fallback grep parser (broken on JSON escapes)"
    API_URL=$(grep -oP '"api_url"\s*:\s*"\K[^"]+' "${CONFIG_FILE}" 2>/dev/null || true)
    API_USER=$(grep -oP '"api_user"\s*:\s*"\K[^"]+' "${CONFIG_FILE}" 2>/dev/null || true)
    API_PASS=$(grep -oP '"api_password"\s*:\s*"\K[^"]+' "${CONFIG_FILE}" 2>/dev/null || true)
    PEER_NAME=$(grep -oP '"peer_name"\s*:\s*"\K[^"]+' "${CONFIG_FILE}" 2>/dev/null || true)
    PREFERRED_IP=$(grep -oP '"preferred_ip"\s*:\s*"\K[^"]+' "${CONFIG_FILE}" 2>/dev/null || true)
    ENABLED=$(grep -oP '"enabled"\s*:\s*\K(true|false)' "${CONFIG_FILE}" 2>/dev/null || true)
fi

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
if [[ -n "${PREFERRED_IP:-}" ]]; then
    log "Using preferred WireGuard IP: ${PREFERRED_IP} (wg-easy may ignore)"
fi

# ============================================================================
# 2. Authenticate to wg-easy (session-cookie)
# ============================================================================
# wg-easy v15 dropped HTTP Basic auth. We POST credentials to /api/session
# and save the returned Set-Cookie into a file. All subsequent calls
# present that cookie via -b.
COOKIE_FILE="/tmp/ppsa-wg-cookies.txt"
# Sensitive — make sure it's not world-readable.
touch "${COOKIE_FILE}"
chmod 600 "${COOKIE_FILE}"

login_and_get_cookies() {
    log "Logging in to wg-easy API at ${API_URL} as '${API_USER}'..."

    # Build the JSON body via python so passwords with quotes / backslashes /
    # unicode are escaped correctly. Sourcing them via env vars avoids
    # putting the secret on the process command line.
    local login_body tmp_body http_code
    login_body=$(API_USER="${API_USER}" API_PASS="${API_PASS}" python3 -c \
        'import json, os; print(json.dumps({"username": os.environ["API_USER"], "password": os.environ["API_PASS"], "remember": False}))')

    tmp_body=$(mktemp)
    http_code=$(curl -sS -m 10 -o "${tmp_body}" -w "%{http_code}" \
        -c "${COOKIE_FILE}" \
        -H "Content-Type: application/json" \
        -X POST \
        -d "${login_body}" \
        "${API_URL}/api/session") || {
            log "Could not reach ${API_URL}/api/session (curl exit $?)"
            log "Check that wg-easy is running and reachable from this host"
            rm -f "${tmp_body}" "${COOKIE_FILE}"
            fail "API unreachable" 2
        }

    if [[ "${http_code}" != "200" && "${http_code}" != "201" && "${http_code}" != "204" ]]; then
        log "Login failed with HTTP ${http_code}"
        log "Response: $(head -c 200 "${tmp_body}")"
        log "Check api_user and api_password in ${CONFIG_FILE}"
        rm -f "${tmp_body}" "${COOKIE_FILE}"
        fail "Authentication failed" 3
    fi

    rm -f "${tmp_body}"

    if [[ ! -s "${COOKIE_FILE}" ]]; then
        log "Login returned HTTP ${http_code} but no session cookie was set"
        log "(wg-easy v15 may have changed its session-cookie name)"
        rm -f "${COOKIE_FILE}"
        fail "Authentication failed" 3
    fi

    log "Login successful (session cookie saved)"
}

login_and_get_cookies

# ============================================================================
# 4. Check if peer already exists
# ============================================================================
log "Checking if peer '${PEER_NAME}' already exists..."

EXISTING_ID=$(curl -fsS -m 10 -b "${COOKIE_FILE}" "${API_URL}/api/client" 2>/dev/null \
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

    # Build create body via python3 so values with quotes/backslashes are
    # escaped correctly. If preferred_ip is set, include 'address' — wg-easy
    # v15 may or may not honor it. On HTTP 422 (unprocessable), retry without
    # 'address' so the server picks the next free IP.
    build_create_body() {
        local want_ip="$1"
        PPSA_WANT_IP="${want_ip}" \
        PPSA_NAME="${PEER_NAME}" \
        PPSA_EXPIRES="${EXPIRES_AT}" \
        python3 -c '
import json, os
body = {"name": os.environ["PPSA_NAME"], "expiresAt": os.environ["PPSA_EXPIRES"]}
ip = os.environ.get("PPSA_WANT_IP", "").strip()
if ip:
    body["address"] = ip
print(json.dumps(body))
'
    }

    CREATE_RESP=$(mktemp)
    post_create() {
        local body="$1"
        curl -sS -m 10 \
            -b "${COOKIE_FILE}" \
            -H "Content-Type: application/json" \
            -o "${CREATE_RESP}" \
            -w "%{http_code}" \
            -X POST \
            -d "${body}" \
            "${API_URL}/api/client"
        return $?
    }

    HTTP_CODE=$(post_create "$(build_create_body "${PREFERRED_IP:-}")") || HTTP_CODE="000"
    if [[ "${HTTP_CODE}" == "422" && -n "${PREFERRED_IP:-}" ]]; then
        log "Server rejected preferred_ip (HTTP 422); retrying without address"
        HTTP_CODE=$(post_create "$(build_create_body "")") || HTTP_CODE="000"
    fi

    if [[ "${HTTP_CODE}" != "200" && "${HTTP_CODE}" != "201" && "${HTTP_CODE}" != "204" ]]; then
        log "Peer creation failed: HTTP ${HTTP_CODE}"
        log "Response: $(head -c 200 "${CREATE_RESP}")"
        log "Action: check api_url/reachability, or remove preferred_ip from ${CONFIG_FILE}"
        rm -f "${CREATE_RESP}"
        fail "Peer creation failed" 4
    fi
    rm -f "${CREATE_RESP}"
    log "Peer created"

    # Find the new peer ID
    PEER_ID=$(curl -fsS -m 10 -b "${COOKIE_FILE}" "${API_URL}/api/client" 2>/dev/null \
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

if ! curl -fsS -m 10 -b "${COOKIE_FILE}" \
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
# wg-quick doesn't handle an already-existing interface cleanly. Use
# syncconf to update the running interface if it exists, or up to create.
if ip link show "${WG_INTERFACE}" >/dev/null 2>&1; then
    log "${WG_INTERFACE} already exists, syncing configuration"
    if ! wg syncconf "${WG_INTERFACE}" <(wg-quick strip "${WG_INTERFACE}"); then
        log "syncconf failed, falling back to down/up"
        wg-quick down "${WG_INTERFACE}" 2>/dev/null || true
        wg-quick up "${WG_INTERFACE}" || fail "wg-quick up failed" 5
    fi
else
    wg-quick up "${WG_INTERFACE}" || fail "wg-quick up failed" 5
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

# Clean up session cookie — it contains a long-lived auth token.
rm -f "${COOKIE_FILE}"

exit 0
