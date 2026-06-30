#!/bin/bash
# =============================================================================
# PPSA - WireGuard status snapshot
# =============================================================================
# Writes the current state of the WireGuard interface to
# /etc/ppsa/wg-status.json so the webui container (which runs in a different
# network namespace) can read it without calling wg(8) itself.
#
# Run by ppsa-wg-status-snapshot.timer every 5s. Status is therefore up to
# 5s stale — acceptable for the WebUI display.
# =============================================================================

set -u

WG_INTERFACE="${PPSA_WG_INTERFACE:-wg0}"
OUTPUT="/etc/ppsa/wg-status.json"
TMPFILE=$(mktemp)
trap 'rm -f "$TMPFILE"' EXIT

if ! command -v wg >/dev/null 2>&1; then
    echo "wg: command not found" >&2
    exit 1
fi

# Get wg show output (may fail if interface is down)
WG_OUTPUT=""
if wg show "$WG_INTERFACE" >/dev/null 2>&1; then
    WG_OUTPUT=$(wg show "$WG_INTERFACE")
fi

# Get the interface's IP address
ADDRESS=""
if [ -n "$WG_OUTPUT" ] && ip -4 addr show "$WG_INTERFACE" >/dev/null 2>&1; then
    ADDRESS=$(ip -4 addr show "$WG_INTERFACE" 2>/dev/null \
        | grep -oP 'inet \K[0-9./]+' | head -1 || true)
fi

# Build JSON via python (more reliable than shell parsing)
PPSA_IFACE="$WG_INTERFACE" \
PPSA_WG_OUTPUT="$WG_OUTPUT" \
PPSA_ADDRESS="$ADDRESS" \
python3 - "$TMPFILE" <<'PYEOF'
import json, os, sys, datetime

iface = os.environ.get("PPSA_IFACE", "wg0")
output = os.environ.get("PPSA_WG_OUTPUT", "")
address = os.environ.get("PPSA_ADDRESS", "")
out_path = sys.argv[1]

if not output:
    snapshot = {
        "interface": iface,
        "exists": False,
        "snapshot_at": datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ"),
        "public_key": None,
        "listen_port": None,
        "address": None,
        "peers": [],
    }
else:
    # Parse wg show output
    public_key = None
    listen_port = None
    fwmark = None
    peers = []
    current = None
    for line in output.splitlines():
        line = line.rstrip()
        if not line:
            continue
        if line.startswith("peer:"):
            if current is not None:
                peers.append(current)
            current = {"public_key": line.split("peer: ", 1)[1].strip()}
        elif current is None and line.startswith("  "):
            # Interface-level field
            stripped = line.strip()
            if stripped.startswith("public key:"):
                public_key = stripped.split("public key: ", 1)[1].strip()
            elif stripped.startswith("listening port:"):
                try:
                    listen_port = int(stripped.split("listening port: ", 1)[1].strip())
                except ValueError:
                    pass
            elif stripped.startswith("fwmark:"):
                fwmark = stripped.split("fwmark: ", 1)[1].strip()
        elif current is not None and line.startswith("  "):
            stripped = line.strip()
            if ":" in stripped:
                key, _, val = stripped.partition(":")
                current[key.strip().replace(" ", "_")] = val.strip()
    if current is not None:
        peers.append(current)

    snapshot = {
        "interface": iface,
        "exists": True,
        "snapshot_at": datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ"),
        "public_key": public_key,
        "listen_port": listen_port,
        "fwmark": fwmark,
        "address": address or None,
        "peers": peers,
    }

with open(out_path, "w") as f:
    json.dump(snapshot, f, indent=2)
PYEOF

# Atomic write
chmod 644 "$TMPFILE"
mv "$TMPFILE" "$OUTPUT"
