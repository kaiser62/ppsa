# NetBird control plane (self-hosted, homeserver)

Replaces the wg-easy hub model for the `netbird` branch. Everything runs on
the homeserver, $0, fully open source. Peers hole-punch direct P2P and fall
back to a **WebSocket relay on TCP 443** when UDP is blocked — the exact
failure mode that kept killing the raw-WireGuard setup.

## One-time prerequisites

1. **DNS** (must be DNS-only / grey-cloud — NOT proxied through Cloudflare;
   gRPC + UDP don't fit the tunnel):
   `nb.pleaseee.eu.org  A  <home public IP>`
2. **Router port-forwards** to the homeserver (192.168.1.140):
   - `80/tcp` (Let's Encrypt HTTP challenge)
   - `443/tcp` (dashboard, management gRPC, signal, relay WSS)
   - `3478/udp` (coturn STUN/TURN — required for cross-network direct P2P;
     without it everything still works but relays through 443)
3. docker + compose plugin on the homeserver.

## Deploy

```bash
mkdir -p ~/netbird && cd ~/netbird
export NETBIRD_DOMAIN=nb.pleaseee.eu.org
bash /path/to/repo/netbird-server/deploy.sh
```

The official quickstart generates `docker-compose.yml`, `management.json`,
Dex config and secrets in `~/netbird` — they stay on the homeserver, never
in git.

> **CRITICAL — `exposedAddress` must carry an explicit `:443`.** The quickstart
> writes `exposedAddress: 'https://<domain>'` with no port. Management still
> works (defaults to 443), but the server then advertises the **Signal** URI to
> peers *without a port* → clients dial `<domain>` portless → `dial context
> deadline exceeded` on Signal → peers register and show in the dashboard but
> **never form P2P**. `deploy.sh` auto-pins `:443`; if you edit config by hand,
> ensure `exposedAddress: 'https://<domain>:443'`. After any server config
> change, restart each enrolled client (`sudo systemctl restart netbird` /
> `Restart-Service NetBird`) so it drops the cached portless signal address.
> This is the #1 self-hosted connectivity gotcha.

## Setup keys (unattended enrollment)

Dashboard → Setup Keys → create **reusable** keys:

| key | groups | used by |
|---|---|---|
| `ppsa-appliance` | `servers` | baked into PPSA images (`PPSA_NB_SETUP_KEY` secret / `netbird.local.json`) |
| `friends` | `friends` | one-liner friends run to join |

Default ACL allows all↔all — fine for the gaming network; tighten later to
`friends -> servers` if wanted.

## Appliance / friend enrollment (all non-interactive)

```bash
# PPSA appliance: automatic on first boot (ppsa-netbird-up.service)
# Friend (any OS after installing the NetBird client):
netbird up --management-url https://nb.pleaseee.eu.org --setup-key <friends-key>
```

## Operations

```bash
cd ~/netbird
docker compose ps          # health
docker compose logs -f management
docker compose pull && docker compose up -d   # upgrade
```

Rollback: `docker compose down` — additive stack, nothing else touched.
