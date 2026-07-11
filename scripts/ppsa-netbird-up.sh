#!/bin/bash
# ppsa-netbird-up.sh
#
# Enroll / reconnect this PPSA host as a NetBird peer. Fully unattended:
# a reusable setup key baked into /etc/ppsa/netbird.json enrolls the box
# with its OWN peer identity (unlike the WG path, no identity is shared
# between appliances built from the same image).
#
# Idempotent: if the NetBird engine is already connected, exits 0 without
# touching anything. Safe to run on every boot (systemd service) and from
# install.sh's first-boot flow.
#
# Config file (/etc/ppsa/netbird.json):
#   {
#     "enabled": true,
#     "management_url": "https://nb.example.com",
#     "setup_key": "..."
#   }
#
# Exit codes:
#   0 = connected (or netbird disabled in config)
#   1 = config missing/invalid
#   2 = netbird binary or daemon unavailable
#   3 = enrollment failed after retries

set -Eeuo pipefail

export PATH="/usr/local/bin:/sbin:/usr/sbin:${PATH}"

SCRIPT_NAME="$(basename "$0")"
LOG_TAG="[${SCRIPT_NAME}]"
CONFIG_FILE="/etc/ppsa/netbird.json"
STATE_FILE="/run/ppsa-netbird-ip"

log() { echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) ${LOG_TAG} $*"; }

if ! command -v netbird >/dev/null 2>&1; then
    log "netbird binary not found"
    exit 2
fi

if [[ ! -f "${CONFIG_FILE}" ]]; then
    log "Config ${CONFIG_FILE} not found — NetBird not configured, nothing to do"
    exit 0
fi

eval "$(python3 - "${CONFIG_FILE}" <<'PYEOF'
import json, sys
try:
    with open(sys.argv[1]) as f:
        c = json.load(f)
except Exception as e:
    sys.stderr.write(f"JSON parse error: {e}\n")
    sys.exit(1)
def esc(v):
    return str(v).replace("\\", "\\\\").replace('"', '\\"').replace("$", "\\$").replace("`", "\\`")
print(f'NB_ENABLED="{esc(str(c.get("enabled", False)).lower())}"')
print(f'NB_MGMT_URL="{esc(c.get("management_url", ""))}"')
print(f'NB_SETUP_KEY="{esc(c.get("setup_key", ""))}"')
PYEOF
)" || { log "Failed to parse ${CONFIG_FILE}"; exit 1; }

if [[ "${NB_ENABLED}" != "true" ]]; then
    log "NetBird disabled in config (enabled=false)"
    exit 0
fi
if [[ -z "${NB_MGMT_URL}" || -z "${NB_SETUP_KEY}" ]]; then
    log "management_url or setup_key missing in ${CONFIG_FILE}"
    exit 1
fi

# Make sure the daemon is up (installed as a systemd service at build time).
if ! netbird status >/dev/null 2>&1; then
    systemctl start netbird.service 2>/dev/null || true
    for _ in 1 2 3 4 5 6; do
        netbird status >/dev/null 2>&1 && break
        sleep 2
    done
fi
if ! netbird status >/dev/null 2>&1; then
    log "NetBird daemon not responding"
    exit 2
fi

save_ip() {
    local ip
    ip=$(netbird status --json 2>/dev/null \
        | python3 -c 'import sys,json;print(json.load(sys.stdin).get("netbirdIp","").split("/")[0])' 2>/dev/null || true)
    if [[ -n "${ip}" ]]; then
        echo "${ip}" > "${STATE_FILE}"
        log "NetBird IP: ${ip} (saved to ${STATE_FILE})"
    fi
}

# Already connected? Done. `netbird status` prints a management/signal
# "Connected" state; the JSON output is the stable interface.
if netbird status --json 2>/dev/null \
    | python3 -c 'import sys,json;d=json.load(sys.stdin);sys.exit(0 if d.get("management",{}).get("connected") else 1)' 2>/dev/null; then
    log "Already connected"
    save_ip
    exit 0
fi

# Enroll with backoff: cold boot can beat DHCP/DNS, and the management
# server may itself be rebooting (same reasoning as wait_for_api in
# ppsa-wireguard-register.sh).
MAX_WAIT="${PPSA_NB_WAIT_TIMEOUT:-180}"
elapsed=0
delay=5
HOSTNAME_ARG="ppsa-$(hostname -s 2>/dev/null || echo server)"
while (( elapsed < MAX_WAIT )); do
    log "netbird up (management ${NB_MGMT_URL}, hostname ${HOSTNAME_ARG})..."
    if netbird up \
        --management-url "${NB_MGMT_URL}" \
        --setup-key "${NB_SETUP_KEY}" \
        --hostname "${HOSTNAME_ARG}" >/dev/null 2>&1; then
        log "NetBird connected"
        save_ip
        exit 0
    fi
    log "  ...not yet (${elapsed}s elapsed), retrying in ${delay}s"
    sleep "${delay}"
    elapsed=$(( elapsed + delay ))
    delay=$(( delay * 2 )); (( delay > 30 )) && delay=30
done

log "ERROR: NetBird enrollment failed after ${MAX_WAIT}s (will retry on next boot via ppsa-netbird-up.service)"
exit 3
