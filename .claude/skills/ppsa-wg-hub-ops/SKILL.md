---
name: ppsa-wg-hub-ops
description: Operate and diagnose the PPSA WireGuard network via the wg-easy hub API - list/delete peers, check handshakes, diagnose a dead/unreachable PPSA server or Windows client, distinguish site outages from appliance bugs. Use when WG connectivity fails, a peer is unreachable, or hub cleanup is needed.
---

# PPSA WireGuard hub operations & diagnosis

## Topology (memorize before touching anything)

- Hub = homeserver behind user's home router, public IP `118.179.74.23`.
- **Gaming** wg-easy: WG UDP `:51830`, panel/API `http://pleaseee.eu.org:51831` (Cloudflare tunnel → TCP path is INDEPENDENT of the WG UDP path). Server pubkey `JXsOZ2jeKHiceR1S1BnMPP5bIWFHvqPbjXecBfslmIkE=`.
- **Admin** wg-easy: WG `:51820`, panel `:51821`. Separate network — never mix.
- PPSA appliance identity: peer `ppsa-server` / `10.8.0.2` (baked into every image — shared!). Real server is REMOTE (was at `118.179.209.33`), reaches hub via public endpoint only. **No LAN endpoint anywhere** (user mandate).
- Friends' clients: `kaiser62-player` 10.8.0.10 (user's Windows PC, hub LAN), `macbook` 10.8.0.15, `pallab` 10.8.0.3 (same remote site as the real server).
- Peer-to-peer forwarding on hub WORKS — that's the product goal (friends reach the Palworld server over WG).

## API (wg-easy v15 — NOT the old endpoints)

```bash
# login (username+password+remember required)
curl -s -c cj.txt -X POST http://pleaseee.eu.org:51831/api/session \
  -H 'Content-Type: application/json' \
  -d '{"username":"admin","password":"overengineered","remember":false}'
curl -s -b cj.txt http://pleaseee.eu.org:51831/api/client            # list peers
curl -s -b cj.txt -X DELETE http://pleaseee.eu.org:51831/api/client/<id>
curl -s -b cj.txt http://pleaseee.eu.org:51831/api/client/<id>/configuration  # download conf
```
Key fields per client: `latestHandshakeAt`, `endpoint` (source ip:port hub last saw), `transferRx/Tx`, `ipv4Address`, `publicKey`.

## Diagnosis playbook

1. **Pull the client list.** Compare `latestHandshakeAt` across ALL peers, not just the broken one.
2. **Site-outage signature:** all peers sharing one endpoint IP go stale the same minute while hub-LAN peers stay fresh → site-level power/router/UDP failure, NOT an appliance bug. (Seen 2026-07-11 16:37: ppsa-server + pallab, both 118.179.209.33, died same second.) Keepalive self-heals when the site recovers — nothing to fix remotely.
3. **TCP-works/UDP-dead tell:** appliance can register via the API (Cloudflare TCP) while zero WG handshakes arrive → UDP path from that site broken; hub-side DNAT is proven fine if any hairpin/LAN peer still handshakes.
4. **Duplicate peers named `ppsa-server`:** old register.sh bug created dups on transient list failures (fixed: lookup failure now falls back instead of creating). A dup with `latestHandshakeAt: null, transferRx: 0` is junk — DELETE it. Keep the lowest-id / preferred-ip (10.8.0.2) one.
5. **`Destination host unreachable` FROM 10.8.0.1** when pinging a peer IP = hub kernel knows the peer but it has no live endpoint (never/not currently connected). Kernel-level proof the peer registration exists.
6. **Windows host can't reach WG peers:** check for TWO tunnels both claiming `AllowedIPs 10.8.0.0/24` (`kaiser62-player` + stale test tunnels). Windows routes into the dead one. Disable the stale adapter; permanent fix needs admin `wireguard.exe /uninstalltunnelservice <name>` (windows-mcp PowerShell is NON-elevated — ask user). Never two tunnels on the same subnet.
7. **NAT hairpin:** a device on the hub's own LAN may fail to reach `118.179.74.23:51830`; that's a router artifact, not a server bug. Test VMs on the LAN work (hairpin OK on this router) — but VBox NAT-mode VMs don't; always bridge.

## Identity hard rule

Every appliance image shares `ppsa-server`/`10.8.0.2` (one endpoint per key on the hub). NEVER let a test VM handshake while the real server is live — last handshake steals the route. Power off test VMs (or `wg-quick down` inside) to release the identity. Appliance-side flow details: `scripts/ppsa-wireguard-register.sh` (keepalive forced, full-tunnel clamped, raw-IP endpoint, baked fallback conf at /etc/ppsa/wireguard-fallback.conf).
