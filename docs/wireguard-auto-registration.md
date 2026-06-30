# PPSA WireGuard Auto-Registration

> PPSA v1.1.3+ auto-joins a **wg-easy** WireGuard network on first boot. Friends
> connect to the same network and play Palworld via the PPSA host's WG IP — no
> port forwarding on the host's router required.

## What it does

On first boot, the PPSA host self-registers as a peer in a wg-easy network
(separate subnet `10.8.0.0/24`) and brings up `wg0`. Players download a
matching peer config from the wg-easy UI and connect; Palworld traffic flows
over WireGuard to the PPSA host's WG IP (`10.8.0.x`).

## Architecture

```
       wg-easy container (homeserver, 192.168.1.140:51831)
       ┌──────────────────────────────────────────┐
       │  Public DNS: pleaseee.eu.org → 118.179.74.23
       │  Listen:   :51830/udp (WireGuard)
       │  Web UI:   :51831/tcp
       │  Subnet:   10.8.0.0/24
       │  Peers:    ppsa-v113 (10.8.0.3), friends (10.8.0.4+)
       └──────────────┬───────────────────────────┘
                      │ WireGuard
       ┌──────────────┴─────────────┐    ┌────────────────────────┐
       │  PPSA host (192.168.1.143) │    │  Player (10.8.0.4)     │
       │  Peer: ppsa-v113           │◄──►│  Palworld client       │
       │  wg0 IP: 10.8.0.3          │    │  connects to 10.8.0.3  │
       │  Palworld :8211 on wg0     │    │  :8211                 │
       └────────────────────────────┘    └────────────────────────┘
```

The PPSA host sits behind the user's home router (no inbound port forwards).
The wg-easy container on the homeserver is the only host with a reachable
public endpoint.

## Setup

### Server side (one-time, on the homeserver)

Run [wg-easy](https://github.com/wg-easy/wg-easy) v15+ via Docker Compose
(`51830/udp` = tunnel, `51831/tcp` = UI, subnet `10.8.0.0/24`).
On Cloudflare, point `pleaseee.eu.org` at the homeserver's public IP and
forward those ports on the router.

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
      WG_HOST: pleaseee.eu.org
      WG_PORT: 51830
      WG_DEFAULT_ADDRESS: 10.8.0.x
    volumes: [./config:/etc/wireguard]
    ports: ["51830:51830/udp", "51831:51831/tcp"]
```

> **Note:** to rotate the admin password, delete `easy.db` and restart with a
> new `PPSA_WG_PASSWORD`.

### PPSA image build

Set these env vars when running `scripts/build-live-usb.sh` (or pass them as
GitHub Actions secrets — see `.github/workflows/build-release.yml`):

| Variable | Required | Example | Description |
|----------|----------|---------|-------------|
| `PPSA_WG_API_URL` | yes | `http://192.168.1.140:51831` | wg-easy base URL (port 51831 = API) |
| `PPSA_WG_API_USER` | yes | `admin` | wg-easy username (always `admin` on v15) |
| `PPSA_WG_API_PASS` | yes | `overengineered` | wg-easy admin password |
| `PPSA_WG_PEER_NAME` | no | `ppsa-server` | Peer name in wg-easy; default `ppsa-$(hostname -s)` |
| `PPSA_WG_PREFERRED_IP` | no | `10.8.0.2` | Requested WireGuard IP; wg-easy v15 may ignore |
| `PPSA_WG_LAN_ENDPOINT` | no | `192.168.1.140:51830` | LAN wg-easy UDP endpoint. At first boot, the register script tries this **first** (TCP probe); if reachable, it rewrites the wg config to use this endpoint. Bypasses DNS. v1.1.24+. |
| `PPSA_WG_PUBLIC_ENDPOINT` | no | `118.179.74.23:51830` | Public wg-easy UDP endpoint. Tried as a **fallback** if the LAN one isn't reachable. Also bypasses DNS (uses the IP directly). v1.1.24+. |

For CI builds, add them as repo secrets at
**Settings → Secrets and variables → Actions**:

```
PPSA_WG_API_URL
PPSA_WG_API_USER
PPSA_WG_API_PASS
PPSA_WG_PEER_NAME        (optional)
PPSA_WG_PREFERRED_IP     (optional)
PPSA_WG_LAN_ENDPOINT     (optional, v1.1.24+)
PPSA_WG_PUBLIC_ENDPOINT  (optional, v1.1.24+)
```

The build script bakes `/etc/ppsa/wireguard.json` (`chmod 600`) into the
image. If none of the env vars are set, the file is written with
`"enabled": false` so the install step is a no-op (configure later via WebUI).

### First boot behavior

`install.sh` is an 8-step sequence. Step **6 of 8** is WireGuard:

```
1/8 Resizing root partition
2/8 Starting Docker
3/8 Configuring environment
4/8 Deploying Docker stack
5/8 Installing Wi-Fi onboarding
6/8 Connecting to PPSA WireGuard network   <-- this
7/8 Configuring firewall
8/8 Marking installation complete
```

The step is wrapped in `timeout 60` so a stuck API call cannot stall the
install. On failure (network down, wrong creds, wg-easy offline), the script
logs a warning and continues — registration can be retried via the WebUI.

## Configuration file

Full `/etc/ppsa/wireguard.json`:

```json
{
  "enabled": true,
  "api_url": "http://192.168.1.140:51831",
  "api_user": "admin",
  "api_password": "overengineered",
  "peer_name": "ppsa-v113",
  "preferred_ip": "10.8.0.2"
}
```

| Field | Required | Default | Description |
|-------|----------|---------|-------------|
| `enabled` | yes | `false` | Master switch. `false` = skip registration entirely |
| `api_url` | yes (if enabled) | — | wg-easy base URL, no trailing slash |
| `api_user` | yes (if enabled) | — | wg-easy username (always `admin` on v15) |
| `api_password` | yes (if enabled) | — | wg-easy admin password |
| `peer_name` | no | `ppsa-$(hostname -s)` | Name shown in the wg-easy peer list |
| `preferred_ip` | no | (server-assigned) | Requested WireGuard IP (e.g. `10.8.0.2`). wg-easy v15 may ignore on create; the actual assigned IP is in `/run/ppsa-wireguard-ip`. On HTTP 422 the script retries without this field. |

The file is `chmod 600` (contains the API password). Parsing is done by
`python3` so values with quotes, backslashes, or unicode work correctly.

## Verification

```bash
# 1. Tunnel state
wg show
#   interface: wg0
#     public key: ...
#     private key: (hidden)
#   peer: <wg-easy server pubkey>
#     endpoint: <public-ip>:51830
#     latest handshake: 14 seconds ago
#     transfer: 2.02 KiB received, 2.02 KiB sent

# 2. Assigned IP
ip -4 addr show wg0 | grep inet
#   inet 10.8.0.3/24

# 3. The IP also lives in /run/ppsa-wireguard-ip (used by tty1 progress UI)
cat /run/ppsa-wireguard-ip
#   10.8.0.3

# 4. Reachability
ping -c 3 10.8.0.1         # wg-easy server
# PING 10.8.0.1 (10.8.0.1) 56(84) bytes of data.
# 64 bytes from 10.8.0.1: icmp_seq=1 ttl=64 time=2.4 ms
```

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| `Could not reach ${API_URL}/api/session` | wg-easy down, port not forwarded, DNS not resolving | `curl http://<wg-easy>:51831/api/session` from PPSA host |
| `Login failed with HTTP 401` | Wrong `api_user` / `api_password` | wg-easy v15 dropped HTTP Basic — must use session-cookie auth (script does this) |
| `No handshake yet` | wg-easy server can't reach PPSA host back | PPSA host doesn't need inbound — but DNS for `WG_HOST` must resolve on the wg-easy side |
| `JSON parse error` | Malformed `wireguard.json` | Validate with `python3 -m json.tool /etc/ppsa/wireguard.json` |
| Player can't reach `10.8.0.3:8211` | Palworld server bound to LAN IP, not `0.0.0.0` | In Palworld container, set `bind` to `0.0.0.0` |
| `resolver not found` for `pleaseee.eu.org` | `/etc/resolv.conf` empty or wrong | PPSA image has `1.1.1.1` + `/etc/hosts` entry; check `cat /etc/hosts` |

### Manual retry

If first-boot registration failed (e.g. wg-easy was offline), retry manually:

```bash
sudo /opt/ppsa/scripts/ppsa-wireguard-register.sh
# tail the log: /var/log/ppsa-install.log
```

## Test results (v1.1.3)

- Built v1.1.3 with `PPSA_WG_*` secrets, booted in VM `ppsa-v113` (192.168.1.143)
- All 8 install steps passed; step 6 (WireGuard) took ~3s
- wg-easy v15 on homeserver 192.168.1.140, DNS `pleaseee.eu.org → 118.179.74.23`
- Peer created: `ppsa-v113` (id=4), IP `10.8.0.3/24`
- `wg0.conf` `Endpoint = pleaseee.eu.org:51830` (public hostname, not raw IP)
- `wg-quick up wg0` successful, no syncconf fallback needed
- Handshake active 14s after `up`, ~2 KiB transferred (handshake + keepalives + DNS)
- DNS via `/etc/hosts` entry + `1.1.1.1` fallback
- tty1 progress UI shows `WireGuard: 10.8.0.3` on completion screen

## End-to-end test results (v1.1.5)

### Test environment

| Component | Value |
|-----------|-------|
| PPSA host VM | `ppsa-v113` (192.168.1.143, wg0 = 10.8.0.3) |
| Player VM   | `ppsa-v114` (192.168.1.197, wg0 = 10.8.0.4) |
| wg-easy     | v15, homeserver 192.168.1.140, subnet 10.8.0.0/24 |
| Public IP   | pleaseee.eu.org → 118.179.74.23 |
| Router forwarding | UDP 51830, TCP 51831 → 192.168.1.140 |

### Results

| Test | Result | Notes |
|------|--------|-------|
| ppsa-v113 → wg-easy (10.8.0.1) | 3/3 pings, ~2.8 ms | |
| ppsa-v114 → ppsa-v113 (10.8.0.3) | 3/3 pings, ~3.1 ms, TTL=63 | TTL drop from 64 = inside WG tunnel |
| Handshake via public IP | Fresh on both VMs | `wg show` shows `endpoint: 118.179.74.23:51830` |
| DNS resolution of `pleaseee.eu.org` | OK | Static `/etc/hosts` + `1.1.1.1` in resolv.conf |

### Key findings

- **Public endpoint works.** wg0.conf bakes `Endpoint = pleaseee.eu.org:51830`; the homeserver is reachable through the router's UDP 51830 forward.
- **TTL=63 confirms tunneling.** One hop more than the LAN baseline (64 → 63) is the expected WireGuard UDP encapsulation.
- **DNS is self-contained.** PPSA ships a static `/etc/hosts` entry plus `nameserver 1.1.1.1` in resolv.conf — no systemd-resolved dependency.

### Baked-in credentials (CI flow)

`PPSA_WG_*` secrets are consumed by `scripts/build-live-usb.sh` (and
`.github/workflows/build-release.yml`) at build time and written into
`/etc/ppsa/wireguard.json` (chmod 600). v1.1.5 ships with the credentials
pre-baked — install.sh step 6 just runs the registration on first boot
with no prompts.

### Limitations

- **Public access requires router port forwarding** on the homeserver network (UDP 51830, TCP 51831). LAN-only testing works without it.
- **Single baked-in endpoint.** The wg-easy URL is fixed at build time; repointing to a different instance needs a rebuild or manual edit of `/etc/ppsa/wireguard.json`.

## Player onboarding (final)

The 4-step flow under this section was verified working with the v1.1.5 public endpoint:

1. Player opens `http://pleaseee.eu.org:51831` and logs in with the wg-easy admin password.
2. Admin creates a new peer in the UI. Player downloads the `.conf` and imports it into the WireGuard client.
3. Player's WG IP is `10.8.0.4+` (assigned by wg-easy).
4. In Palworld, connect to `10.8.0.3:8211` (the PPSA host's WG IP).

> The PPSA server peer (`ppsa-server` is the default peer name baked in) is already pre-registered by the image build, so onboarding only creates the player's peer. No port forwarding on the player's network — only outbound UDP/51830 to pleaseee.eu.org.
