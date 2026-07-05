# Troubleshooting

## Boot & install

### PPSA gets no IP address

| Cause | Fix |
|-------|-----|
| VirtualBox bridged adapter pointed at the wrong NIC | Settings → Network → Adapter 1 → Bridged Adapter → pick the NIC connected to your router |
| DHCP not available on this network | Try a different network, or assign a static IP later via the Web UI |
| No network configured at all | Connect to the `PPSA-Setup` Wi-Fi hotspot — see [Wi-Fi onboarding](wifi-onboarding.md) |

### Console (tty1) stuck mid-step during first boot

```bash
ssh ppsa@<ppsa-ip>
sudo tail -100 /var/log/ppsa-install.log
# Force a re-run:
sudo rm /opt/ppsa/.installed && sudo systemctl restart ppsa-firstboot.service
```

### VirtualBox guest hits kernel RCU stalls / soft lockups (`containerd-shim` stuck)

Seen mainly on hosts where VirtualBox itself runs nested under another
hypervisor (Hyper-V, WSL2's Virtual Machine Platform) — the guest's timer
becomes unreliable under load. Symptoms: `rcu_preempt self-detected stall`,
`watchdog: BUG: soft lockup`, services failing to start after the stall.

Things to try, in order of effort:
1. Reinstall the shipped `vboxguest` module if it doesn't match your host's
   VirtualBox version: `sudo apt install --reinstall virtualbox-guest-dkms && sudo reboot`
2. `VBoxManage modifyvm <vm> --paravirtprovider kvm` (helps some Linux guests
   under nested Hyper-V)
3. Reduce to 1 vCPU — the stalls are timer-related, not raw CPU-starvation,
   so a single vCPU is sometimes markedly more stable than two
4. As a last resort, disable the guest's vboxservice:
   `sudo systemctl disable --now vboxservice`

## Web UI

### Web UI shows 500 / stuck on "Connecting..."

Docker is probably still pulling images, or Palworld is downloading its ~4 GB
Steam update. Wait 5-10 minutes and refresh. Check directly over SSH:
```bash
sudo docker ps -a
sudo docker logs ppsa-palworld --tail 50
```

### Players tab stuck on "Loading..."

The Palworld REST API is slow to respond right after a Steam update or
restart. Give it a minute; if it never resolves, check
`docker logs ppsa-palworld` for REST API errors.

### Palworld container shows "unhealthy"

Normal during the first launch while the Steam update downloads
(`sudo docker logs -f ppsa-palworld`). If it stays unhealthy for 30+ minutes,
check DNS/Steam reachability from inside the container:
```bash
docker exec ppsa-palworld nslookup steamcdn-a.akamaihd.net
docker exec ppsa-palworld wget -q -O - https://api.steamcmd.net
```
If DNS resolution fails, check `/etc/resolv.conf` on the PPSA host itself.

## WireGuard

### WireGuard tab shows "Not Configured"

`/etc/ppsa/wireguard.json` has `"enabled": false` or doesn't exist. Fill in
credentials via Web UI → WireGuard tab, or bake them in at build time — see
[docs/wireguard-setup.md](wireguard-setup.md).

### Registration stuck / no handshake / can't reach anything over WireGuard

Check reachability from the PPSA host in order:
```bash
curl -sS -m 5 -o /dev/null -w "%{http_code}\n" http://<wg-easy-host>:51831/api/client
# 000 = network unreachable, 401 = reachable but wrong creds, 200/2xx = fine
getent hosts <your-wg-easy-domain>   # if using a hostname, expect an IP back
wg show                              # check for a fresh 'latest handshake'
```
If reachable from a browser on your own machine but not from the PPSA host,
the wg-easy server's UDP tunnel port isn't forwarded on its router.

### Player connects but is immediately disconnected

- **Palworld container not ready yet** — wait until it's `healthy`.
- **Wrong `AllowedIPs` in the player's `.conf`.** wg-easy's default is
  `10.8.0.0/24` (PPSA's WireGuard subnet only — a split tunnel, not a full
  VPN). If a config instead has `AllowedIPs = 0.0.0.0/0` and the PPSA host
  isn't set up to forward + NAT, the player's whole LAN/internet gets routed
  through the tunnel and breaks. Fix: edit the `.conf` to
  `AllowedIPs = 10.8.0.0/24` and re-import, or fix the default on the wg-easy
  side and re-download the config.

More detail on the WireGuard flow itself: [docs/wireguard-setup.md](wireguard-setup.md).

## Wi-Fi onboarding hotspot

| Symptom | Cause | Fix |
|---------|-------|-----|
| Hotspot never starts | No Wi-Fi hardware present | Use Ethernet instead |
| `PPSA-Setup` not visible | Wi-Fi adapter regulatory domain issue | `sudo iw reg set US` (or your country) |
| Connected to a real network, but device still shows the hotspot | `hostapd` didn't stop cleanly | `sudo systemctl stop hostapd`, retry |
| "No secrets" / auth failure | Wrong Wi-Fi password | Retry with the correct password |
| Network drops every few minutes | Wi-Fi power management | `sudo iwconfig wlan0 power off` |

More detail: [docs/wifi-onboarding.md](wifi-onboarding.md).

## Maintenance

**Updating to a new release:** download the new image, write it to a fresh
USB (or replace the VDI), and boot. First boot detects existing data and
skips destructive steps. To force a clean reinstall instead:
```bash
sudo rm /opt/ppsa/.installed
sudo docker volume rm compose_palworld_data compose_webui_data compose_wgdashboard_data
sudo reboot
```

**Backups:** the `backup` container runs on `BACKUP_SCHEDULE` (default
`0 3 * * *`, 7-day retention) and writes to `/mnt/backups` (or wherever your
`.env` points `../backups`).
