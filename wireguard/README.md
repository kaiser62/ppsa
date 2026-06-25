# WireGuard Tunnel Setup

The PPSA appliance connects to an Oracle VPS gateway via WireGuard to provide
a public IP for Palworld game traffic. This hides the home network IP.

## Tunnel Architecture

```
PPSA Appliance (10.0.0.2)         Oracle VPS Gateway (10.0.0.1)
  ┌──────────────────────┐          ┌──────────────────────────┐
  │ Palworld :8211       │          │ eth0 (public IP)         │
  │ Web UI   :8080       │◄─tunnel──► NAT: 8211/8212/27015    │
  │ SSH      :22         │  51820   │   → 10.0.0.2 (PPSA)     │
  └──────────────────────┘          └──────────────────────────┘
                                            │
                                       Internet (players)
```

## Quick Start (Two Commands)

### Step 1: Set up the Oracle VPS

Create an Oracle Cloud instance and run:

```bash
ssh root@<vps-ip> 'bash -s' -- < oracle/vps-setup.sh
```

This installs WireGuard, generates keys, configures NAT/firewall.
**Save the output** — you need the VPS public key and endpoint IP.

### Step 2: Connect from the Web UI

1. Open PPSA Web UI → **WireGuard** tab
2. Enter the VPS endpoint (`<vps-ip>:51820`) and VPS public key
3. Click **Connect**

The web UI generates a local key pair, writes `wg0.conf`, and starts the tunnel.
The PPSA **public key** is displayed — add it to the VPS:

```bash
ssh root@<vps-ip> 'wg set wg0 peer <PPSA_PUB_KEY> allowed-ips 10.0.0.2/32 persistent-keepalive 25'
```

### Optional: CLI Setup

If the web UI is not available (pre-configuration):

```bash
sudo bash /opt/ppsa/scripts/setup-wireguard.sh \
  --vps-endpoint <VPS_IP>:51820 \
  --vps-public-key <VPS_PUBLIC_KEY>
```

## Port Forwarding (VPS → PPSA)

| Port | Protocol | Service            |
|------|----------|--------------------|
| 8211 | UDP      | Palworld game      |
| 8212 | TCP      | Palworld REST API  |
| 27015| UDP      | Steam query        |
| 25575| TCP      | RCON (deprecated)  |

Configured automatically by `oracle/vps-setup.sh` via nftables.

## Management

- **Web UI**: WireGuard tab — status, connect, disconnect, view config
- **CLI**: `sudo wg show` / `sudo wg-quick up wg0` / `sudo wg-quick down wg0`
- **WGDashboard**: http://<server-ip>:10086 (advanced peer management)

## Files

| File | Purpose |
|------|---------|
| `/etc/wireguard/wg0.conf` | Tunnel configuration |
| `/etc/wireguard/ppsa.key` | PPSA private key |
| `/etc/wireguard/ppsa.pub` | PPSA public key |
| `scripts/setup-wireguard.sh` | CLI setup script |
| `oracle/vps-setup.sh` | VPS one-command setup |
| `oracle/cloud-init.yml` | VPS cloud-init config |
