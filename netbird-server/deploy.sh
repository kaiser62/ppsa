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

echo
echo "=== Next steps ==="
echo "1. Open https://${NETBIRD_DOMAIN} and create the owner account (or use the setup API)."
echo "2. Dashboard -> Setup Keys -> create TWO reusable keys:"
echo "     ppsa-appliance  (reusable, no expiry, auto-group: servers)"
echo "     friends         (reusable, auto-group: friends)"
echo "3. Store them:  gh secret set PPSA_NB_SETUP_KEY  (appliance key)"
echo "                gh secret set PPSA_NB_MANAGEMENT_URL --body https://${NETBIRD_DOMAIN}"
echo "4. Verify:  docker compose ps   (all services healthy)"
