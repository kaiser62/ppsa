#!/bin/bash
# =============================================================================
# PPSA - WireGuard manual tunnel apply
# =============================================================================
# The webui container runs in its own network namespace and cannot bring
# up/down wg0 itself (wg-quick's `ip link add` would create the interface
# inside the container, invisible to the host). This script runs on the
# host (triggered by ppsa-wg-manual-apply.path watching for changes to
# /etc/ppsa/wg-manual-request.json) and does the actual wg-quick call.
#
# Request file (written by the webui, /api/wireguard/connect|disconnect):
#   {"id": "<uuid>", "action": "up"|"down"}
#
# Result file (written by this script, polled by the webui):
#   {"id": "<uuid>", "status": "ok"|"error", "detail": "...", "completed_at": "..."}
# =============================================================================

set -u

REQUEST_FILE="/etc/ppsa/wg-manual-request.json"
RESULT_FILE="/etc/ppsa/wg-manual-result.json"
WG_INTERFACE="${PPSA_WG_INTERFACE:-wg0}"

write_result() {
    local id="$1" status="$2" detail="$3"
    local tmp
    tmp=$(mktemp)
    PPSA_ID="$id" PPSA_STATUS="$status" PPSA_DETAIL="$detail" python3 - "$tmp" <<'PYEOF'
import json, os, sys, datetime
out = {
    "id": os.environ.get("PPSA_ID", ""),
    "status": os.environ.get("PPSA_STATUS", "error"),
    "detail": os.environ.get("PPSA_DETAIL", ""),
    "completed_at": datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ"),
}
with open(sys.argv[1], "w") as f:
    json.dump(out, f, indent=2)
PYEOF
    chmod 644 "$tmp"
    mv "$tmp" "$RESULT_FILE"
}

if [ ! -f "$REQUEST_FILE" ]; then
    exit 0
fi

REQ_ID=$(python3 -c "import json; print(json.load(open('$REQUEST_FILE')).get('id',''))" 2>/dev/null || true)
ACTION=$(python3 -c "import json; print(json.load(open('$REQUEST_FILE')).get('action',''))" 2>/dev/null || true)

if [ -z "$REQ_ID" ] || [ -z "$ACTION" ]; then
    write_result "$REQ_ID" "error" "Malformed request file"
    exit 0
fi

case "$ACTION" in
    up)
        if ip link show "$WG_INTERFACE" >/dev/null 2>&1; then
            OUTPUT=$(wg-quick down "$WG_INTERFACE" 2>&1)
        fi
        OUTPUT=$(wg-quick up "$WG_INTERFACE" 2>&1)
        RC=$?
        ;;
    down)
        OUTPUT=$(wg-quick down "$WG_INTERFACE" 2>&1)
        RC=$?
        ;;
    *)
        write_result "$REQ_ID" "error" "Unknown action: $ACTION"
        exit 0
        ;;
esac

if [ "$RC" -eq 0 ]; then
    write_result "$REQ_ID" "ok" "$OUTPUT"
else
    write_result "$REQ_ID" "error" "$OUTPUT"
fi
