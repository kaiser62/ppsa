#!/usr/bin/env bash
# =============================================================================
# PPSA — NetBird control-plane deploy (run ON the homeserver)
# =============================================================================
# Deploys the self-hosted NetBird stack (management + signal + relay + coturn
# + dashboard + embedded Dex IdP) using NetBird's official quickstart. The
# quickstart generates docker-compose.yml + management.json + secrets into
# the CURRENT DIRECTORY — run it from a dedicated dir (e.g. ~/netbird) and
# keep those artifacts there; they contain secrets and are NOT committed.
#
# Prerequisites (see README.md):
#   - DNS-only A record:  nb.pleaseee.eu.org -> <public IP>   (NOT proxied!)
#   - Router forwards:    80/tcp, 443/tcp -> this host ; 3478/udp -> this host
#   - docker + docker compose plugin installed
#
# Usage:
#   export NETBIRD_DOMAIN=nb.pleaseee.eu.org
#   bash deploy.sh
# =============================================================================

set -euo pipefail

NETBIRD_DOMAIN="${NETBIRD_DOMAIN:-nb.pleaseee.eu.org}"

if ! command -v docker >/dev/null 2>&1; then
    echo "ERROR: docker not installed" >&2
    exit 1
fi

if docker ps --format '{{.Names}}' | grep -qE 'wg-easy'; then
    echo "NOTE: wg-easy containers detected — fine, NetBird uses different ports (80/443/3478 vs 5182x)."
fi

# Port sanity: quickstart's Traefik/proxy needs 80+443 free on the host.
for p in 80 443; do
    if ss -tlnp 2>/dev/null | grep -q ":${p} "; then
        echo "ERROR: TCP port ${p} already in use on this host — free it or edit the compose after generation." >&2
        ss -tlnp | grep ":${p} " >&2 || true
        exit 1
    fi
done

echo "Deploying NetBird for domain: ${NETBIRD_DOMAIN}"
export NETBIRD_DOMAIN
curl -fsSL https://github.com/netbirdio/netbird/releases/latest/download/getting-started.sh | bash

# --- CRITICAL: pin an explicit :443 on exposedAddress -------------------------
# The quickstart writes `exposedAddress: 'https://<domain>'` WITHOUT a port.
# Management derives :443 and works, but the combined server then advertises the
# SIGNAL URI to peers WITHOUT a port -> clients dial `<domain>` with no port ->
# `dial context deadline exceeded` on Signal -> peers register but never form
# P2P. Pinning :443 fixes it (Signal URI becomes https://<domain>:443). This is
# THE #1 self-hosted connectivity gotcha; do not remove.
CFG=""
for c in config.yaml management.json ./data/config.yaml; do
    [ -f "$c" ] && CFG="$c" && break
done
if [ -n "$CFG" ] && grep -q "https://${NETBIRD_DOMAIN}'" "$CFG" 2>/dev/null; then
    sed -i "s#https://${NETBIRD_DOMAIN}'#https://${NETBIRD_DOMAIN}:443'#g" "$CFG"
    echo "Pinned :443 on exposedAddress in $CFG (signal port fix)."
    docker compose restart 2>/dev/null || docker restart nb-server 2>/dev/null || true
else
    echo "WARN: could not auto-pin :443 — verify '${CFG:-config.yaml}' has exposedAddress: 'https://${NETBIRD_DOMAIN}:443' (WITH port), else Signal will fail for all peers."
fi
# NOTE: after ANY server config change, each already-enrolled client must
# restart its agent to drop the cached (portless) signal address:
#   Linux:   sudo systemctl restart netbird
#   Windows: Restart-Service NetBird

echo
echo "=== Next steps ==="
echo "1. Open https://${NETBIRD_DOMAIN} and create the owner account (or use the setup API)."
echo "2. Dashboard -> Setup Keys -> create TWO reusable keys:"
echo "     ppsa-appliance  (reusable, no expiry, auto-group: servers)"
echo "     friends         (reusable, auto-group: friends)"
echo "3. Store them:  gh secret set PPSA_NB_SETUP_KEY  (appliance key)"
echo "                gh secret set PPSA_NB_MANAGEMENT_URL --body https://${NETBIRD_DOMAIN}"
echo "4. Verify:  docker compose ps   (all services healthy)"
