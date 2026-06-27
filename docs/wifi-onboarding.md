# PPSA Wi-Fi Onboarding

> PPSA v1.1.0+ ships with a built-in **Wi-Fi setup portal**. Plug the USB into
> any laptop, boot from it, and either:
> 1. Connect to the **`PPSA-Setup`** hotspot (password: `ppsa-setup-2026`)
>    and pick your Wi-Fi from the captive portal, or
> 2. Open the Web UI and use the new **Wi-Fi** tab.

## What it does

The PPSA image includes a full network manager stack:

- **wpa_supplicant** + **NetworkManager** for WPA2/WPA3 client connections
- **hostapd** + **dnsmasq** for the fallback "PPSA-Setup" software AP
- **Firmware for ~every common Wi-Fi chipset** (Intel AX, Realtek, Atheros/Qualcomm,
  Broadcom, MediaTek) — verified on a fresh install of:
  - Intel Wi-Fi 6 AX200 / AX201 / AX210 / AX211
  - Realtek RTL8822BE / RTL8821CE / RTL8852BE
  - Qualcomm Atheros QCA6174 / QCA9377
  - Broadcom BCM4360 / BCM4352 (with `b43`/`wl` drivers)
  - MediaTek MT7921 / MT7922 (Wi-Fi 6E)
  - Intel Wireless-N / AC 3160 / 7260 / 8260

If your chipset isn't in the list above, the `firmware-misc-nonfree` package
in Debian will cover it 90% of the time. If you find one that's not working,
please open an issue with `lspci | grep -i net` output.

## First boot flow

```
1. Laptop boots from PPSA USB
2. systemd brings up network
3. ppsa-wifi-onboard.service starts:
   a. If a Wi-Fi network is already saved → connect to it
   b. Else, if Wi-Fi hardware is present → start PPSA-Setup hotspot
   c. Else, exit (use Ethernet)
4. Hotspot runs on wlan0 (192.168.50.1/24, DHCP from dnsmasq)
5. User connects phone/laptop to "PPSA-Setup" (ppsa-setup-2026)
6. Captive portal-style redirect to http://192.168.50.1:8080
7. Web UI → Wi-Fi tab → scan → pick network → enter password → Connect
8. PPSA drops the hotspot, joins the real Wi-Fi, saves creds to
   /etc/ppsa/wifi.conf (mode 0600)
9. NetworkManager auto-reconnects on every subsequent boot
```

## Using the Wi-Fi tab

The new **Wi-Fi** tab in the Web UI gives you:

- Current connection status (SSID, signal, IP)
- "Rescan Networks" — refreshes the visible AP list
- "Start PPSA-Setup Hotspot" — manually enable the fallback AP
- "Disconnect" — drop the current Wi-Fi (and delete saved creds)
- A list of available networks with signal bars, band (2.4 / 5 GHz), security
- One-click "Connect" with password prompt (auto-fills when open network)

## API reference

All endpoints require JWT auth (except `/api/login`).

```
GET  /api/wifi/status      Current connection state
GET  /api/wifi/scan       List of visible networks
POST /api/wifi/connect    Connect to { ssid, password }
POST /api/wifi/disconnect Drop current connection
POST /api/wifi/hotspot/start  Manually start the PPSA-Setup AP
```

Example with curl:

```bash
TOKEN=$(curl -s -X POST -u admin:admin http://192.168.1.240:8080/api/login | jq -r .token)
curl -H "Authorization: Bearer $TOKEN" http://192.168.1.240:8080/api/wifi/scan | jq .
curl -X POST -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
     -d '{"ssid":"MyHome","password":"secret"}' \
     http://192.168.1.240:8080/api/wifi/connect
```

## What the service does on boot

`/opt/ppsa/scripts/ppsa-wifi-onboard.sh` (enabled as
`ppsa-wifi-onboard.service`):

1. If `nmcli` reports no Wi-Fi hardware → exit
2. If NetworkManager already has a connection → exit
3. If `/etc/ppsa/wifi.conf` exists with saved creds → try to connect
4. If still no connection → start the PPSA-Setup hotspot:
   - `hostapd` on `wlan0` with SSID `PPSA-Setup`
   - `dnsmasq` DHCP range 192.168.50.10–100
   - Static IP 192.168.50.1 on the Wi-Fi interface

## Saving and rotating credentials

The chosen SSID + PSK are stored at `/etc/ppsa/wifi.conf` (mode `0600`,
root:root). NetworkManager also keeps a copy in its system-connections
directory. To rotate:

```bash
# Clear saved Wi-Fi
rm /etc/ppsa/wifi.conf
nmcli connection delete id MyHome
# Reboot or re-onboard
reboot
```

## Security notes

- The PPSA-Setup hotspot uses **WPA2** with a fixed password. WPA3 isn't
  available on hostapd for 2.4 GHz without `nl80211` driver quirks
  (some chipsets drop back to WPA2-only).
- The fallback password (`ppsa-setup-2026`) is **intentionally public** —
  it's only used for the first-boot captive portal. After connecting to
  your real Wi-Fi, the hotspot is automatically torn down.
- All Wi-Fi credentials are stored as **system connections** (root-only
  readable) and are **not** exposed through the Web UI API.

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| Hotspot never starts | No Wi-Fi hardware | Use Ethernet |
| `ppsa-Setup` not visible | Wi-Fi adapter in client mode (e.g. wrong country) | `iw reg set US` |
| Connect succeeds, but VM still on hotspot | hostapd not killed | `systemctl stop hostapd` then retry |
| Connect fails with "no secrets" | Wrong password | Retry with correct password |
| Network drops every few minutes | Power management | `iwconfig wlan0 power off` |
