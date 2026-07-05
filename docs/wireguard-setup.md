# WireGuard Setup

PPSA auto-joins a **wg-easy** WireGuard network on first boot. Friends connect
to the same network and play Palworld via the PPSA host's WireGuard IP — no
port forwarding on the PPSA's own router required. This is also what gates
access to the game server, Web UI, and WGDashboard by default — see
[docs/architecture.md#networking--firewall](architecture.md#networking--firewall)
for the full firewall model, and the `expose_ssh_lan` build flag if you also
want SSH reachable on the LAN.

## How it works

On first boot, the PPSA host self-registers as a peer in a wg-easy network
(subnet `10.8.0.0/24`) and brings up `wg0`. Players download a matching peer
config from the wg-easy UI and connect; Palworld traffic flows over
WireGuard to the PPSA host's WG IP (`10.8.0.x`).

```
       wg-easy (your own server, reachable at <api_url>)
       ┌──────────────────────────────────────────┐
       │  Listen:   :51830/udp (WireGuard tunnel)  │
       │  Web UI:   :51831/tcp (peer management)   │
       │  Subnet:   10.8.0.0/24                    │
       └──────────────┬───────────────────────────┘
                      │ WireGuard
       ┌──────────────┴─────────────┐    ┌────────────────────────┐
       │  PPSA host                 │    │  Player                │
       │  wg0 IP: 10.8.0.x          │◄──►│  connects to PPSA's     │
       │  Palworld :8211 on wg0     │    │  WG IP :8211            │
       └────────────────────────────┘    └────────────────────────┘
```

The PPSA host needs no inbound port forwards — it only needs outbound reach to
the wg-easy server. The wg-easy server is the one component that needs a
publicly reachable endpoint (or a LAN one, for same-network setups).

## Hosting your own wg-easy hub

Run [wg-easy](https://github.com/wg-easy/wg-easy) v15+ anywhere reachable —
a home server, a small VPS (Oracle Cloud's free tier works fine), or any
Docker host:

```yaml
services:
  wg-easy:
    image: ghcr.io/wg-easy/wg-easy:15
    container_name: wg-easy
    restart: unless-stopped
    cap_add: [NET_ADMIN, NET_CACHED, SYS_MODULE]
    sysctls: [net.ipv4.ip_forward=1, net.ipv4.conf.all.src_valid_mark=1]
    environment:
      # Only read on first start (empty DB). After that the password
      # lives in /etc/wireguard/easy.db.
      PASSWORD: ${PPSA_WG_PASSWORD}
      WG_HOST: your.domain.or.ip
      WG_PORT: 51830
      WG_DEFAULT_ADDRESS: 10.8.0.x
    volumes: [./config:/etc/wireguard]
    ports: ["51830:51830/udp", "51831:51831/tcp"]
```

If it's behind a router, forward `51830/udp` (tunnel) and `51831/tcp` (admin
UI). Point a DNS name at the public IP if you want a stable hostname instead
of a raw IP.

> To rotate the admin password, delete `easy.db` and restart with a new
> `PPSA_WG_PASSWORD`.

## Baking credentials into a PPSA build

Set these env vars when running `scripts/build-live-usb.sh`, or as GitHub
repo secrets consumed by `.github/workflows/build-release.yml` /
`build-installer.yml` (**Settings → Secrets and variables → Actions**):

| Variable | Required | Description |
|----------|----------|-------------|
| `PPSA_WG_API_URL` | yes | wg-easy base URL including the admin-UI port, e.g. `http://192.168.1.140:51831` |
| `PPSA_WG_API_USER` | yes | wg-easy username (always `admin` on v15) |
| `PPSA_WG_API_PASS` | yes | wg-easy admin password |
| `PPSA_WG_PEER_NAME` | no | Peer name in wg-easy; defaults to `ppsa-$(hostname -s)` |
| `PPSA_WG_PREFERRED_IP` | no | Requested WireGuard IP, e.g. `10.8.0.2` (wg-easy v15 may ignore it) |
| `PPSA_WG_LAN_ENDPOINT` | no | LAN wg-easy UDP endpoint, tried first at boot; falls back to the public endpoint if it doesn't get a fresh handshake |
| `PPSA_WG_PUBLIC_ENDPOINT` | no | Public wg-easy UDP endpoint, tried as a fallback |

If none of the required vars are set, the build ships
`/etc/ppsa/wireguard.json` with `"enabled": false` — registration is a no-op
until configured later via the Web UI.

## First boot behavior

`install.sh`'s WireGuard step (6 of 8) is wrapped in a timeout so a stuck API
call can't stall the whole install. On failure — network down, wrong creds,
wg-easy offline — it logs a warning and continues; registration can be
retried later via the Web UI or by re-running the script manually:

```bash
sudo /opt/ppsa/scripts/ppsa-wireguard-register.sh
# log: /var/log/ppsa-install.log
```

## Configuration file: `/etc/ppsa/wireguard.json`

```json
{
  "enabled": true,
  "api_url": "http://192.168.1.140:51831",
  "api_user": "admin",
  "api_password": "overengineered",
  "peer_name": "ppsa-server",
  "preferred_ip": "10.8.0.2"
}
```

| Field | Required | Default | Description |
|-------|----------|---------|-------------|
| `enabled` | yes | `false` | Master switch — `false` skips registration entirely |
| `api_url` | yes (if enabled) | — | wg-easy base URL, no trailing slash |
| `api_user` | yes (if enabled) | — | wg-easy username |
| `api_password` | yes (if enabled) | — | wg-easy admin password |
| `peer_name` | no | `ppsa-$(hostname -s)` | Name shown in the wg-easy peer list |
| `preferred_ip` | no | server-assigned | Requested WireGuard IP; the actual assigned IP lands in `/run/ppsa-wireguard-ip` |

File is `chmod 600` (it contains the API password).

## Verifying the tunnel

```bash
wg show
#   interface: wg0
#   peer: <wg-easy server pubkey>
#     endpoint: <ip>:51830
#     latest handshake: 14 seconds ago

ip -4 addr show wg0 | grep inet     # your assigned WG IP
cat /run/ppsa-wireguard-ip           # same, used by the tty1 progress UI
ping -c 3 10.8.0.1                   # reach the wg-easy server
```

## Player onboarding

1. Player opens the wg-easy admin UI and logs in (or the admin creates the peer for them).
2. Admin creates a new peer; player downloads the `.conf` and imports it into their WireGuard client.
3. Player's WG IP is assigned by wg-easy (e.g. `10.8.0.4`).
4. In Palworld, the player connects to the PPSA host's WG IP (e.g. `10.8.0.3:8211`).

No port forwarding needed on the player's own network — only outbound
UDP to the wg-easy server's tunnel port.

## Troubleshooting

See [docs/troubleshooting.md](troubleshooting.md#wireguard) for common issues
(API unreachable, auth failures, no handshake, DNS resolution).
