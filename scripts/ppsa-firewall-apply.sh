#!/usr/bin/env bash
# =============================================================================
# PPSA - WG_FRIENDS firewall rule builder
# =============================================================================
# Idempotent. Reads firewall.json for allowed TCP/UDP ports and
# the ICMP toggle, rebuilds the WG_FRIENDS iptables chain, and persists
# the ruleset. Designed to be called from the PPSA WebUI (or first-boot
# install.sh) to manage what friends connected via WireGuard
# (10.8.0.0/24) are allowed to reach on the PPSA host.
#
# Source priority for the config file:
#   1. /etc/ppsa/firewall.json (canonical, root-owned)
#   2. /var/lib/docker/volumes/<webui_data>/_data/firewall.json (webui-written)
#   3. Hardcoded defaults if neither exists
#
# The chain is jumped to from INPUT only for source 10.8.0.0/24, so it
# does not affect the host's own outbound traffic or other source nets.
# =============================================================================

set -u

CHAIN="WG_FRIENDS"
WG_NET="10.8.0.0/24"
RULES_V4="/etc/iptables/rules.v4"
# webui_data volume is created by docker compose. The exact name is
# compose_webui_data (compose project prefix + service name + _data).
WEBDATA="/var/lib/docker/volumes/compose_webui_data/_data"

mkdir -p "$(dirname "$RULES_V4")" 2>/dev/null || true

# --- Locate config file (read-only) ---
# Prefer /etc/ppsa/firewall.json (canonical), then the webui container's
# data dir (writable from webui's perspective), then use defaults.
CONFIG=""
if [ -f "/etc/ppsa/firewall.json" ]; then
  CONFIG="/etc/ppsa/firewall.json"
elif [ -f "$WEBDATA/firewall.json" ]; then
  CONFIG="$WEBDATA/firewall.json"
  echo "Using config from webui data: $CONFIG"
else
  # Write defaults to the webui data dir (writable from webui's
  # /:/host:ro mount — but webui_data is a Docker volume so it's RW)
  DEFAULT_DIR="$WEBDATA"
  mkdir -p "$DEFAULT_DIR" 2>/dev/null || true
  CONFIG="$DEFAULT_DIR/firewall.json"
  if [ ! -f "$CONFIG" ]; then
    cat > "$CONFIG" <<'JSON'
{
  "wg_friends_allowed_tcp": [22, 80, 443, 8080, 10086, 25575],
  "wg_friends_allowed_udp": [8211, 27015],
  "wg_friends_allow_icmp": true
}
JSON
    chmod 644 "$CONFIG" 2>/dev/null || true
    echo "Wrote default config to $CONFIG"
  fi
fi

# --- Parse config (python3 is in base Debian, more reliable than jq) ---
OUT=$(python3 - "$CONFIG" <<'PY'
import json, sys
c = json.load(open(sys.argv[1]))
def norm(key):
    ports = c.get(key, []) or []
    out = []
    for p in ports:
        try:
            n = int(p)
        except (TypeError, ValueError):
            continue
        if 0 < n < 65536:
            out.append(str(n))
    return ",".join(out)
print(norm("wg_friends_allowed_tcp"))
print(norm("wg_friends_allowed_udp"))
print("true" if c.get("wg_friends_allow_icmp", False) else "false")
PY
)
TCP=$(printf '%s\n' "$OUT" | sed -n '1p')
UDP=$(printf '%s\n' "$OUT" | sed -n '2p')
ICMP=$(printf '%s\n' "$OUT" | sed -n '3p')

# --- Rebuild chain (create-or-flush, then add rules fresh) ---
iptables -N "$CHAIN" 2>/dev/null || iptables -F "$CHAIN"

# Allow ICMP first (one rule, cheap)
if [ "$ICMP" = "true" ]; then
  iptables -A "$CHAIN" -p icmp -j ACCEPT
fi

# Allowed TCP ports
IFS=',' read -ra TCPPORTS <<< "$TCP"
for p in "${TCPPORTS[@]}"; do
  [ -n "$p" ] && iptables -A "$CHAIN" -p tcp --dport "$p" -j ACCEPT
done

# Allowed UDP ports
IFS=',' read -ra UDPPORTS <<< "$UDP"
for p in "${UDPPORTS[@]}"; do
  [ -n "$p" ] && iptables -A "$CHAIN" -p udp --dport "$p" -j ACCEPT
done

# Drop everything else
iptables -A "$CHAIN" -j DROP

# --- Ensure INPUT jumps to WG_FRIENDS for the WG subnet (idempotent) ---
# Insert at top so it runs before any UFW ACCEPTs (UFW inserts at a high
# position, our targeted rule should win on specificity for 10.8.0.0/24).
if ! iptables -C INPUT -s "$WG_NET" -j "$CHAIN" 2>/dev/null; then
  iptables -I INPUT 1 -s "$WG_NET" -j "$CHAIN"
fi

# --- Persist rules (best-effort, may be read-only when called from webui) ---
if command -v netfilter-persistent >/dev/null 2>&1; then
  netfilter-persistent save >/dev/null 2>&1
elif command -v iptables-save >/dev/null 2>&1; then
  # Try /etc/iptables/rules.v4 (canonical, but may be RO in chroot).
  # Fall back to webui data dir which is always writable.
  if iptables-save > "$RULES_V4" 2>/dev/null; then
    :
  else
    # Save to webui data dir as backup
    iptables-save > "$WEBDATA/iptables.rules.v4" 2>/dev/null || true
  fi
fi

echo "WG_FRIENDS rebuilt: TCP=[$TCP] UDP=[$UDP] ICMP=$ICMP"
