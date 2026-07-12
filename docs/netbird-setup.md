# NetBird networking (primary; `netbird` mainline, `v1.3.0-nb.N`)

> **Server gotcha #1 — pin `:443`.** The self-hosted control plane's
> `config.yaml` **must** have `exposedAddress: 'https://<domain>:443'` with an
> explicit port. Without it, management works but the **Signal** URI is
> advertised portless → clients dial with no port → `dial context deadline
> exceeded` on Signal → peers register and show in the dashboard but **never
> form P2P**. `netbird-server/deploy.sh` auto-pins it; verify after any deploy.
> After any server config change, restart each enrolled client
> (`sudo systemctl restart netbird` / `Restart-Service NetBird`) so it drops the
> cached portless signal address.

## Why

The raw-WireGuard + wg-easy design failed repeatedly on NAT plumbing:
dropped idle UDP mappings, router hairpin quirks, endpoints baked at build
time, a single shared peer identity across all appliances, and a hub that
silently stopped accepting new sessions. NetBird keeps WireGuard as the data
plane but adds a control plane: peers get identities from a reusable setup
key, hole-punch direct P2P, and fall back to a WebSocket relay on TCP 443
when UDP is hostile.

What this changes for the appliance:

| | WireGuard line (master) | NetBird line (netbird branch) |
|---|---|---|
| Identity | shared `ppsa-server`/10.8.0.2 baked | unique per install (reusable key) |
| Enrollment | 560-line register script + wg-easy API | `netbird up --setup-key …` (unattended) |
| NAT failure | dead tunnel until manual fix | auto relay over TCP 443 |
| Subnet | 10.8.0.0/24 (`wg0`) | 100.64.0.0/10 (`wt0`) |

Both stacks coexist in nb test images; the WG line stays fully functional.

## Server

See [netbird-server/README.md](../netbird-server/README.md) — one-time deploy
on the homeserver (DNS record + 3 port-forwards + `deploy.sh`).

## Appliance

Baked at build time from CI secrets `PPSA_NB_MANAGEMENT_URL` +
`PPSA_NB_SETUP_KEY` (or local `netbird.local.json`) into
`/etc/ppsa/netbird.json`. First boot: `ppsa-netbird-up.service` runs
`scripts/ppsa-netbird-up.sh` — idempotent, retries with backoff, saves the
assigned IP to `/run/ppsa-netbird-ip`. The agent daemon (`netbird.service`,
pinned binary in `/usr/local/bin/netbird`) maintains the tunnel afterwards.

Firewall: `ppsa-firewall-apply.sh` jumps `100.64.0.0/10` into the same
`WG_FRIENDS` chain — NetBird friends get exactly the WG-friends port set
(`firewall.json`, editable in the WebUI Firewall tab).

Status: WebUI `GET /api/netbird/status` (connected, IP, peer counts, which
peers are relayed).

## Friends

1. Install the NetBird client: https://netbird.io/docs (Windows installer /
   `brew install netbirdio/tap/netbird` / Linux script).
2. Join (one line, no account needed):
   ```
   netbird up --management-url https://nb.pleaseee.eu.org --setup-key <friends-key>
   ```
3. Palworld: connect to the appliance's NetBird IP, port 8211.

## Verification checklist (per test build)

1. Fresh install enrolls unattended — peer appears in dashboard with unique name.
2. From another peer: ping appliance 100.x, WebUI :8080, SSH :22. LAN-direct stays blocked.
3. `iptables -S INPUT | head` shows the 100.64.0.0/10 jump.
4. Reboot: same identity reconnects, services reachable.
5. Kill test: block outbound UDP on the appliance — connection must survive via relay (`/api/netbird/status` shows peers `relayed`).
6. Second install = second unique peer (no identity theft).

## Rollback

Test-build only. Master/WG untouched; inside an nb image the WG stack still
runs in parallel. Server side: `docker compose down` in `~/netbird`.
