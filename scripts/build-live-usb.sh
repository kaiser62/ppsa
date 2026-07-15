#!/usr/bin/env bash
# =============================================================================
# PPSA - Build Portable USB Appliance Image
# =============================================================================
# Creates a bootable Debian disk image (.img) that runs entirely from a USB SSD.
# The image contains a complete Debian system with Docker + PPSA stack.
#
# Usage:
#   sudo bash scripts/build-live-usb.sh --output /path/to/ppsa-usb.img
#
# Requires (will auto-install if missing):
#   debootstrap, parted, losetup, mkfs.ext4, mkfs.fat
# =============================================================================

set -euo pipefail

# --- Configuration ---
OUTPUT_IMG=""
DEBIAN_VERSION="trixie"
DEBIAN_MIRROR="http://deb.debian.org/debian"
IMG_SIZE_MB=${PPSA_IMG_SIZE_MB:-12288}       # 12GB default (Palworld=3.8GB + system=5.3GB + backups=4GB headroom; v1.1.0 had 8GB which was 98% full after first game download)
PPSA_SRC="$(cd "$(dirname "$0")/.." && pwd)" # Repository root
BUILD_DIR="${TMPDIR:-/tmp}/ppsa-build"
ROOTFS_DIR="$BUILD_DIR/rootfs"
BOOT_DIR="$BUILD_DIR/boot"
EFI_SIZE_MB=256
ROOT_SIZE_MB=$((IMG_SIZE_MB - EFI_SIZE_MB - 2))  # -2 for partition table overhead

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# --- Parse args ---
while [[ $# -gt 0 ]]; do
    case "$1" in
        --output) OUTPUT_IMG="$2"; shift 2 ;;
        --size) IMG_SIZE_MB="$2"; shift 2 ;;
        --help) echo "Usage: $0 --output <path> [--size <MB>]"; exit 0 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

if [ -z "$OUTPUT_IMG" ]; then
    echo -e "${RED}ERROR: --output is required${NC}"
    echo "Usage: $0 --output /path/to/ppsa-usb.img [--size 4096]"
    exit 1
fi

# Must be run as root (for chroot, losetup, mount)
if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}ERROR: This script must be run as root (sudo).${NC}"
    exit 1
fi

# --- Check/install dependencies ---
echo -e "${GREEN}[1/7] Checking dependencies...${NC}"
DEPS="debootstrap parted e2fsprogs dosfstools grub-pc-bin grub-efi-amd64-bin grub2-common"
MISSING=""
for dep in $DEPS; do
    if ! dpkg -s "$dep" &>/dev/null; then
        MISSING="$MISSING $dep"
    fi
done
if [ -n "$MISSING" ]; then
    echo -e "${YELLOW}Installing missing dependencies:${NC}$MISSING"
    apt-get update -qq
    apt-get install -y -qq $MISSING
fi

# --- Clean up any previous build ---
if [ -d "$BUILD_DIR" ]; then
    echo -e "${YELLOW}Cleaning previous build...${NC}"
    # Clean up any mounts still there
    umount "$ROOTFS_DIR/dev/pts" 2>/dev/null || true
    umount "$ROOTFS_DIR/dev" 2>/dev/null || true
    umount "$ROOTFS_DIR/proc" 2>/dev/null || true
    umount "$ROOTFS_DIR/sys" 2>/dev/null || true
fi

mkdir -p "$ROOTFS_DIR"
mkdir -p "$BOOT_DIR"

ensure_loop_partition_node() {
    local loop_dev="$1"
    local part_num="$2"
    local part_dev="${loop_dev}p${part_num}"
    local loop_name
    loop_name="$(basename "$loop_dev")"

    if [ -b "$part_dev" ]; then
        echo "$part_dev"
        return 0
    fi

    partprobe "$loop_dev" 2>/dev/null || true
    partx -a "$loop_dev" 2>/dev/null || true
    sleep 1

    if [ -b "$part_dev" ]; then
        echo "$part_dev"
        return 0
    fi

    local sys_dev="/sys/class/block/${loop_name}p${part_num}/dev"
    if [ -r "$sys_dev" ]; then
        local major minor
        IFS=: read -r major minor < "$sys_dev"
        mknod "$part_dev" b "$major" "$minor" 2>/dev/null || true
    fi

    if [ ! -b "$part_dev" ]; then
        echo "ERROR: loop partition device not available: $part_dev" >&2
        return 1
    fi

    echo "$part_dev"
}

# =============================================================================
# Allow skipping bootstrap via PPSA_SKIP_BOOTSTRAP (CI cache hit)
# =============================================================================
if [ -n "${PPSA_SKIP_BOOTSTRAP:-}" ]; then
    echo -e "${YELLOW}PPSA_SKIP_BOOTSTRAP set — reusing cached rootfs${NC}"
    if [ -n "${PPSA_CACHE_FILE:-}" ] && [ -f "$PPSA_CACHE_FILE" ]; then
        echo "Restoring rootfs from cache: $PPSA_CACHE_FILE"
        mkdir -p "$(dirname "$ROOTFS_DIR")"
        tar -xzf "$PPSA_CACHE_FILE" -C "$(dirname "$ROOTFS_DIR")"
    fi
    if [ ! -f "$ROOTFS_DIR/bin/bash" ]; then
        echo -e "${RED}Rootfs missing or incomplete at $ROOTFS_DIR${NC}"
        echo -e "${RED}Set PPSA_CACHE_FILE to a valid cache tarball, or unset PPSA_SKIP_BOOTSTRAP${NC}"
        exit 1
    fi
else

# =============================================================================
# Step 1: debootstrap — create base Debian system
# =============================================================================
echo -e "${GREEN}[2/7] Bootstrapping Debian $DEBIAN_VERSION (this takes a while)...${NC}"
debootstrap --arch=amd64 --include="ca-certificates,curl,sudo,locales,git,wget" \
    "$DEBIAN_VERSION" "$ROOTFS_DIR" "$DEBIAN_MIRROR"

# =============================================================================
# Step 2: Chroot configuration
# =============================================================================
echo -e "${GREEN}[3/7] Configuring system inside chroot...${NC}"

# Mount necessary filesystems (pts needed to suppress debconf warnings)
mount --bind /dev "$ROOTFS_DIR/dev"
mount --bind /proc "$ROOTFS_DIR/proc"
mount --bind /sys "$ROOTFS_DIR/sys"
mkdir -p "$ROOTFS_DIR/dev/pts"
mount -t devpts devpts "$ROOTFS_DIR/dev/pts" 2>/dev/null || true

# Write the chroot setup script
cat > "$ROOTFS_DIR/tmp/setup.sh" <<'CHROOTEOF'
#!/bin/bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
export LC_ALL=C

# --- Locale (uncomment in locale.gen first, then generate) ---
sed -i 's/# en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/default/locale
echo "LC_ALL=en_US.UTF-8" >> /etc/default/locale

# --- DNS: prefer the DHCP/router-supplied resolver, public DNS as fallback ---
# The appliance must resolve names on ANY network, including ones whose
# router/ISP blocks or hijacks public resolvers (8.8.8.8/1.1.1.1/9.9.9.9) and
# only answers DNS on the LAN's own server. A baked *public-only* resolv.conf
# breaks those networks completely — nothing resolves, so BOTH the Palworld
# Steam download ("Connecting anonymously to Steam Public...Retrying" forever)
# AND NetBird's control-plane lookup (nb.<domain>) fail, and the box looks
# "dead" over the overlay even though the link is up. It also regressed on
# normal networks here: resolvconf (pulled in as a NM/ifupdown dependency)
# rewrote the static file down to a single public nameserver and dropped the
# router's DNS entirely.
#
# Fix: make systemd-resolved the single DNS owner. systemd-networkd hands it
# the DHCP-supplied DNS (the router — always correct for the local network) as
# the PRIMARY resolver; FallbackDNS below is used only when DHCP provides none
# (cold boot before a lease, or static addressing). Point /etc/resolv.conf at
# resolved's *networkd* file (which lists the real upstreams) rather than the
# 127.0.0.53 stub, so we keep DHCP-first behaviour without the old
# "stub present but service down = connection refused" trap.
systemctl enable systemd-resolved
mkdir -p /etc/systemd/resolved.conf.d
cat > /etc/systemd/resolved.conf.d/ppsa-dns.conf <<'RESOLVEDEOF'
[Resolve]
FallbackDNS=1.1.1.1 8.8.8.8 9.9.9.9
RESOLVEDEOF
ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf
# resolvconf would fight resolved for /etc/resolv.conf and reintroduce the
# public-only file. It's only a Recommends of NM/ifupdown, so purging it is
# safe and leaves resolved as the sole manager.
apt-get purge -y -qq resolvconf 2>/dev/null || true

# --- Hostname ---
echo "ppsa" > /etc/hostname
cat > /etc/hosts <<HOSTSEOF
127.0.0.1 localhost
127.0.1.1 ppsa
::1     ip6-localhost ip6-loopback
HOSTSEOF

# --- Timezone ---
echo "UTC" > /etc/timezone
ln -sf /usr/share/zoneinfo/UTC /etc/localtime
dpkg-reconfigure -f noninteractive tzdata

# --- APT sources ---
cat > /etc/apt/sources.list <<APTEOF
deb http://deb.debian.org/debian trixie main contrib non-free non-free-firmware
deb http://deb.debian.org/debian-security/ trixie-security main contrib non-free non-free-firmware
deb http://deb.debian.org/debian trixie-updates main contrib non-free non-free-firmware
APTEOF

# --- Install packages ---
echo "Installing system packages..."
apt-get update -qq

# Kernel + boot
apt-get install -y -qq linux-image-amd64 firmware-linux firmware-linux-nonfree firmware-iwlwifi firmware-atheros firmware-realtek firmware-brcm80211 firmware-misc-nonfree
# Skip linux-headers: server doesn't compile kernel modules.

# GRUB bootloader - install tools in image for maintenance, plus the
# Secure Boot chain: shim-signed (Microsoft-signed first-stage loader),
# shim-helpers-amd64-signed (MokManager mmx64.efi), and
# grub-efi-amd64-signed (Debian-signed monolithic GRUB core). The image
# build copies these prebuilt binaries onto the ESP so the appliance
# boots with Secure Boot enabled — no MOK enrollment needed, shim is
# trusted by the Microsoft 3rd-party UEFI CA present in stock firmware.
# grub-efi-amd64-bin satisfies grub-efi-amd64-signed's dependency without
# pulling grub-efi-amd64 (whose postinst wants a real install device).
apt-get install -y -qq grub2-common grub-efi-amd64-bin shim-signed shim-helpers-amd64-signed grub-efi-amd64-signed

# Docker (compose plugin is a separate binary, not yet packaged in Trixie)
apt-get install -y -qq docker.io containerd
# Install docker compose plugin from GitHub
mkdir -p /usr/lib/docker/cli-plugins
curl -fsSL "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" \
    -o /usr/lib/docker/cli-plugins/docker-compose
chmod +x /usr/lib/docker/cli-plugins/docker-compose

# Install docker buildx plugin from GitHub (required for 'docker compose build')
# Latest stable release — pin when buildx hits a known-good version.
BUILDX_VERSION="v0.18.0"
curl -fsSL "https://github.com/docker/buildx/releases/download/${BUILDX_VERSION}/buildx-${BUILDX_VERSION}.linux-amd64" \
    -o /usr/lib/docker/cli-plugins/docker-buildx
chmod +x /usr/lib/docker/cli-plugins/docker-buildx

# Networking + VPN
apt-get install -y -qq wireguard wireguard-tools openresolv

# Wi-Fi onboarding (captive portal + hotspot)
# - wpasupplicant: WPA2/WPA3 client for connecting to APs
# - iw / wireless-tools: scan and manage Wi-Fi interfaces
# - network-manager: modern network config daemon (auto-reconnect, priority)
# - hostapd: software access point (for the fallback hotspot)
# - dnsmasq: DHCP + DNS for the hotspot's clients
apt-get install -y -qq wpasupplicant iw wireless-tools network-manager hostapd dnsmasq-base

# System tools (cloud-guest-utils provides growpart for first-boot resize)
apt-get install -y -qq \
    ufw fail2ban htop iotop net-tools \
    openssh-server nftables rsync \
    python3 python3-pip python3-venv \
    sudo curl wget vim-tiny lsof \
    cloud-guest-utils polkitd

# Clean up
apt-get clean
rm -rf /var/lib/apt/lists/*

# --- Users ---
useradd -m -s /bin/bash -G sudo,docker ppsa
echo "ppsa ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/ppsa
chmod 440 /etc/sudoers.d/ppsa
echo "ppsa:ppsa" | chpasswd
useradd -m -s /bin/bash -G sudo artho
echo "artho:arthoroy" | chpasswd
passwd -d root 2>/dev/null || true  # no root password, use sudo

# --- SSH: allow password auth for first setup, add alt port, disable DNS lookups ---
sed -i 's/^#Port 22/Port 22/' /etc/ssh/sshd_config
sed -i 's/^#PasswordAuthentication yes/PasswordAuthentication yes/' /etc/ssh/sshd_config
echo "Port 10022" >> /etc/ssh/sshd_config
echo "UseDNS no" >> /etc/ssh/sshd_config
echo "ListenAddress 0.0.0.0" >> /etc/ssh/sshd_config

# Ensure SSH waits for network to be fully online before binding
mkdir -p /etc/systemd/system/ssh.service.d
cat > /etc/systemd/system/ssh.service.d/network.conf <<EOF
[Unit]
After=network-online.target
Wants=network-online.target
EOF

# --- Enable services ---
systemctl enable docker
systemctl enable ssh
systemctl enable systemd-networkd

# --- NetworkManager: only manage Wi-Fi, not ethernet ---
# Both network-manager and systemd-networkd ship in this image. By default
# NetworkManager races systemd-networkd for DHCP on every interface,
# handing out two leases on the same en* NIC on first boot — the
# secondary lease has a lower metric and steals the default route, so
# the host briefly holds two IPs and ARP discovery sees a moving target.
# Tell NetworkManager to leave ethernet alone; systemd-networkd owns it
# (see /etc/systemd/network/20-wired.network below), and NetworkManager
# keeps managing wlan0 for the Wi-Fi onboarding / hotspot feature.
cat > /etc/NetworkManager/NetworkManager.conf <<'NMEOF'
[main]
plugins=ifupdown,keyfile
# Route wlan0's DNS (Wi-Fi onboarding) through systemd-resolved too, so
# resolved is the single DNS owner for every interface (see the resolv.conf
# setup above). `dns=default` let NM overwrite /etc/resolv.conf and fight
# resolved's symlink.
dns=systemd-resolved
[ifupdown]
managed=false
[keyfile]
unmanaged-devices=interface-name:en*
NMEOF
# PPSA Wi-Fi onboarding (hotspot fallback + auto-connect).
# PPSA files (including this script + ppsa-wifi-onboard.sh and
# ppsa-wifi-onboard.service) were already copied to /opt/ppsa/ by the
# earlier `cp -a "$PPSA_SRC/." "$ROOTFS_DIR/opt/ppsa/"` call. The
# service file lives in /etc/systemd/system/.
if [ -f /opt/ppsa/scripts/ppsa-wifi-onboard.sh ]; then
    chmod +x /opt/ppsa/scripts/ppsa-wifi-onboard.sh
    cp /opt/ppsa/scripts/ppsa-wifi-onboard.service /etc/systemd/system/ppsa-wifi-onboard.service
    # Disabled by default: NOT `systemctl enable`d. This service reconfigures
    # the Wi-Fi interface (new NetworkManager profile, hostapd/dnsmasq) every
    # time it runs when no Wi-Fi network is saved, which on real hardware
    # with an actual Wi-Fi card ran on every single boot and could hang or
    # leave the interface broken, blocking subsequent boots. The WebUI's
    # POST /api/wifi/hotspot/start still triggers `systemctl start
    # ppsa-wifi-onboard.service` on demand, so onboarding is opt-in instead
    # of on-by-default.
    echo "PPSA Wi-Fi onboarding: installed (disabled by default — start from WebUI Wi-Fi tab)"
else
    echo "WARNING: ppsa-wifi-onboard.sh not found, skipping"
fi

# PPSA WireGuard auto-registration: install register script + service + bake config.
# The register script is run by install.sh on first boot, and a systemd
# service is enabled so re-registration (e.g. after power outage, or
# after the user fills in /etc/ppsa/wireguard.json via the WebUI) can be
# triggered via `systemctl start ppsa-wireguard-register.service`.
# The config file /etc/ppsa/wireguard.json contains the wg-easy API
# endpoint and credentials so the host can self-register as a peer in
# the PPSA gaming network.
if [ -f /opt/ppsa/scripts/ppsa-wireguard-register.sh ]; then
    chmod +x /opt/ppsa/scripts/ppsa-wireguard-register.sh
    echo "PPSA WireGuard register: script installed"
else
    echo "WARNING: ppsa-wireguard-register.sh not found, skipping"
fi
if [ -f /opt/ppsa/scripts/ppsa-wireguard-register.service ]; then
    cp /opt/ppsa/scripts/ppsa-wireguard-register.service /etc/systemd/system/ppsa-wireguard-register.service
    systemctl enable ppsa-wireguard-register.service
    echo "PPSA WireGuard register: service installed and enabled"
else
    echo "WARNING: ppsa-wireguard-register.service not found, skipping"
fi

# PPSA WireGuard status snapshot: install script + service + timer.
# The host writes /etc/ppsa/wg-status.json every 5s so the webui container
# (separate netns) can read WG state without running wg(8) itself.
if [ -f /opt/ppsa/scripts/ppsa-wg-status-snapshot.sh ]; then
    chmod +x /opt/ppsa/scripts/ppsa-wg-status-snapshot.sh
    echo "PPSA WG status snapshot: script installed"
fi
if [ -f /opt/ppsa/scripts/ppsa-wg-status-snapshot.service ]; then
    cp /opt/ppsa/scripts/ppsa-wg-status-snapshot.service /etc/systemd/system/
    echo "PPSA WG status snapshot: service installed"
fi
if [ -f /opt/ppsa/scripts/ppsa-wg-status-snapshot.timer ]; then
    cp /opt/ppsa/scripts/ppsa-wg-status-snapshot.timer /etc/systemd/system/
    systemctl daemon-reload
    systemctl enable ppsa-wg-status-snapshot.timer
    systemctl start ppsa-wg-status-snapshot.timer
    echo "PPSA WG status snapshot: timer enabled and started"
fi

# PPSA WireGuard manual tunnel apply: host-side path unit that applies
# wg-quick up/down requested by the webui's manual Connect/Disconnect
# buttons — the webui container's own netns can't bring up wg0 itself.
if [ -f /opt/ppsa/scripts/ppsa-wg-manual-apply.sh ]; then
    chmod +x /opt/ppsa/scripts/ppsa-wg-manual-apply.sh
    echo "PPSA WG manual apply: script installed"
fi
if [ -f /opt/ppsa/scripts/ppsa-wg-manual-apply.service ]; then
    cp /opt/ppsa/scripts/ppsa-wg-manual-apply.service /etc/systemd/system/
    echo "PPSA WG manual apply: service installed"
fi
if [ -f /opt/ppsa/scripts/ppsa-wg-manual-apply.path ]; then
    cp /opt/ppsa/scripts/ppsa-wg-manual-apply.path /etc/systemd/system/
    systemctl daemon-reload
    systemctl enable ppsa-wg-manual-apply.path
    echo "PPSA WG manual apply: path unit enabled"
fi

# PPSA firewall apply trigger: host-side path unit that rebuilds the
# WG_FRIENDS chain when the webui writes firewall.json + touches
# firewall-request.json — the webui container's own netns can't modify the
# host firewall itself (same pattern as the WG manual apply above).
if [ -f /opt/ppsa/scripts/ppsa-firewall-request.service ]; then
    cp /opt/ppsa/scripts/ppsa-firewall-request.service /etc/systemd/system/
    echo "PPSA firewall request: service installed"
fi
if [ -f /opt/ppsa/scripts/ppsa-firewall-request.path ]; then
    cp /opt/ppsa/scripts/ppsa-firewall-request.path /etc/systemd/system/
    systemctl daemon-reload
    systemctl enable ppsa-firewall-request.path
    echo "PPSA firewall request: path unit enabled"
fi

# PPSA Docker Compose stack: re-apply on every boot (safety net for Docker
# container-metadata loss after an unclean shutdown/power loss). Idempotent
# — a no-op when the stack is already healthy.
if [ -f /opt/ppsa/scripts/ppsa-docker-compose.service ]; then
    cp /opt/ppsa/scripts/ppsa-docker-compose.service /etc/systemd/system/
    systemctl daemon-reload
    systemctl enable ppsa-docker-compose.service
    echo "PPSA Docker Compose stack: re-apply-on-boot service enabled"
fi

# Read wg-easy creds from wireguard.local.json if it exists and env vars are unset.
# This file is gitignored. Intended for local builds only - CI never has this file.
# Search: relative to script, CWD, or /etc/ppsa/. PowerShell orchestrator normally
# pre-sets PPSA_WG_* env vars, so this block is a fallback for direct-WSL users.
WG_LOCAL_JSON=""
for candidate in \
  "$(dirname "$(readlink -f "$0" 2>/dev/null || echo "$0")")/../wireguard.local.json" \
  "./wireguard.local.json" \
  "/etc/ppsa/wireguard.local.json"; do
  if [ -f "$candidate" ]; then
    WG_LOCAL_JSON="$candidate"
    break
  fi
done
if [ -n "$WG_LOCAL_JSON" ] && [ -z "${PPSA_WG_API_URL:-}" ]; then
  echo "PPSA WireGuard: reading creds from $WG_LOCAL_JSON"
  # Write a tiny parser to a tempfile to avoid shell-quoting hell, then
  # source its output (it emits "export KEY=value" lines).
  WG_PARSER=$(mktemp --suffix=.sh)
  cat > "$WG_PARSER" <<'PARSER_EOF'
#!/bin/bash
# ponytail: emitted by build-live-usb.sh from wireguard.local.json
# Pre-set WG_LOCAL_JSON in the calling env.
PARSER_EOF
  WG_LOCAL_JSON="$WG_LOCAL_JSON" python3 - >> "$WG_PARSER" 2>/dev/null <<'PYEOF'
import json, os
with open(os.environ["WG_LOCAL_JSON"]) as f:
    cfg = json.load(f)
cfg.pop("_comment", None)
if cfg.get("enabled"):
    def emit(k, v):
        # Escape for double-quoted shell strings
        sv = str(v).replace("\\", "\\\\").replace('"', '\\"').replace('$', '\\$').replace('`', '\\`')
        print(f'export {k}="{sv}"')
    emit("PPSA_WG_API_URL",    cfg.get("api_url", ""))
    emit("PPSA_WG_API_USER",   cfg.get("api_user", ""))
    emit("PPSA_WG_API_PASS",   cfg.get("api_password", ""))
    emit("PPSA_WG_PEER_NAME",  cfg.get("peer_name", "ppsa-server"))
    if cfg.get("preferred_ip"):
        emit("PPSA_WG_PREFERRED_IP", cfg["preferred_ip"])
    # lan_endpoint / public_endpoint feed register.sh's handshake-verified
    # endpoint selection. Baking lan_endpoint lets a PPSA that sits on the
    # SAME LAN as the wg-easy hub fall back to the hub's LAN IP when the
    # public endpoint stays silent (router NAT-hairpin fails), so the tunnel
    # comes up and survives reboot without manual `wg set`.
    if cfg.get("lan_endpoint"):
        emit("PPSA_WG_LAN_ENDPOINT", cfg["lan_endpoint"])
    if cfg.get("public_endpoint"):
        emit("PPSA_WG_PUBLIC_ENDPOINT", cfg["public_endpoint"])
PYEOF
  if [ $? -eq 0 ] && [ -s "$WG_PARSER" ] && grep -q '^export ' "$WG_PARSER"; then
    # shellcheck disable=SC1090
    . "$WG_PARSER"
  else
    echo "WARN: failed to parse $WG_LOCAL_JSON"
  fi
  rm -f "$WG_PARSER"
fi

# Write the wireguard.json config (baked into the image).
# Build-time: PPSA_WG_API_URL, PPSA_WG_API_USER, PPSA_WG_API_PASS, PPSA_WG_PEER_NAME,
# PPSA_WG_PREFERRED_IP can be set as env vars when running build-live-usb.sh.
# If not set, the config file is left for the user to fill in via the WebUI.
mkdir -p /etc/ppsa
chmod 755 /etc/ppsa
if [ -n "${PPSA_WG_API_URL:-}" ] && [ -n "${PPSA_WG_API_USER:-}" ] && [ -n "${PPSA_WG_API_PASS:-}" ]; then
    # WireGuard is DEPRECATED (NetBird is the primary networking path as of the
    # v1.3.0-nb line). The wg-easy creds are still baked so WG can be re-enabled
    # without re-registering, but "enabled" defaults to false — flip it on with
    # PPSA_WG_ENABLED=true at build time. See docs/wireguard-setup.md.
    if [ "${PPSA_WG_ENABLED:-false}" = "true" ]; then WG_ENABLED_JSON=true; else WG_ENABLED_JSON=false; fi
    # Empty optional values are fine: the register script treats "" as unset.
    # lan_endpoint/public_endpoint feed the runtime handshake-verified
    # endpoint fallback (public first, LAN if the public one stays silent).
    cat > /etc/ppsa/wireguard.json <<WGEOF
{
  "enabled": ${WG_ENABLED_JSON},
  "api_url": "${PPSA_WG_API_URL}",
  "api_user": "${PPSA_WG_API_USER}",
  "api_password": "${PPSA_WG_API_PASS}",
  "peer_name": "${PPSA_WG_PEER_NAME:-ppsa-server}",
  "preferred_ip": "${PPSA_WG_PREFERRED_IP:-}",
  "lan_endpoint": "${PPSA_WG_LAN_ENDPOINT:-}",
  "public_endpoint": "${PPSA_WG_PUBLIC_ENDPOINT:-}"
}
WGEOF
    echo "PPSA WireGuard config: baked in (enabled=${WG_ENABLED_JSON} [deprecated; set PPSA_WG_ENABLED=true to activate], peer: ${PPSA_WG_PEER_NAME:-ppsa-server}, preferred_ip: '${PPSA_WG_PREFERRED_IP:-}', lan_endpoint: '${PPSA_WG_LAN_ENDPOINT:-}', public_endpoint: '${PPSA_WG_PUBLIC_ENDPOINT:-}')"
    chmod 600 /etc/ppsa/wireguard.json
else
    cat > /etc/ppsa/wireguard.json <<WGEOF
{
  "enabled": false,
  "api_url": "",
  "api_user": "",
  "api_password": "",
  "peer_name": "ppsa-server"
}
WGEOF
    chmod 600 /etc/ppsa/wireguard.json
    echo "PPSA WireGuard config: not configured (set PPSA_WG_* env vars to bake in)"
fi

# Hardcoded WireGuard failsafe: PPSA_WG_FALLBACK_CONF_B64 is a base64-encoded
# full wg0.conf (PrivateKey/PresharedKey included) used when wg-easy
# auto-registration fails or isn't configured. See ppsa-wireguard-register.sh
# try_fallback() for how it's applied at runtime.
if [ -n "${PPSA_WG_FALLBACK_CONF_B64:-}" ]; then
    echo "${PPSA_WG_FALLBACK_CONF_B64}" | base64 -d > /etc/ppsa/wireguard-fallback.conf
    chmod 600 /etc/ppsa/wireguard-fallback.conf
    echo "PPSA WireGuard fallback config: baked in"
fi

# --- NetBird agent (netbird branch: parallel to the WG stack) ---
# Pinned release binary — no third-party apt repo inside the chroot. The
# daemon unit is written by hand (same shape `netbird service install`
# generates) so the install is fully reproducible. Enrollment happens on
# first boot via ppsa-netbird-up.sh with the baked setup key; every
# appliance gets its OWN peer identity (reusable key), unlike the shared
# WG identity.
NETBIRD_VERSION="0.74.4"
echo "Installing NetBird agent v${NETBIRD_VERSION}..."
NB_TGZ="/tmp/netbird_${NETBIRD_VERSION}_linux_amd64.tar.gz"
if curl -fsSL -o "$NB_TGZ" \
    "https://github.com/netbirdio/netbird/releases/download/v${NETBIRD_VERSION}/netbird_${NETBIRD_VERSION}_linux_amd64.tar.gz"; then
    tar -xzf "$NB_TGZ" -C /usr/local/bin netbird
    chmod 755 /usr/local/bin/netbird
    rm -f "$NB_TGZ"
    cat > /etc/systemd/system/netbird.service <<'NBSVCEOF'
[Unit]
Description=NetBird agent daemon
After=network.target syslog.target

[Service]
ExecStart=/usr/local/bin/netbird service run --config /etc/netbird/config.json --log-level info --log-file /var/log/netbird/client.log
Restart=always
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
NBSVCEOF
    mkdir -p /etc/netbird /var/log/netbird
    systemctl enable netbird.service
    echo "NetBird agent: installed and enabled ($(/usr/local/bin/netbird version 2>/dev/null || echo v${NETBIRD_VERSION}))"
else
    echo "WARNING: NetBird agent download failed — image will build without NetBird"
    rm -f "$NB_TGZ"
fi

# PPSA NetBird enrollment service (runs ppsa-netbird-up.sh on every boot;
# idempotent, exits fast when already connected).
if [ -f /opt/ppsa/scripts/ppsa-netbird-up.sh ]; then
    chmod +x /opt/ppsa/scripts/ppsa-netbird-up.sh
fi
if [ -f /opt/ppsa/scripts/ppsa-netbird-up.service ]; then
    cp /opt/ppsa/scripts/ppsa-netbird-up.service /etc/systemd/system/
    systemctl daemon-reload
    systemctl enable ppsa-netbird-up.service
    echo "PPSA NetBird enrollment: service enabled"
fi

# Read NetBird enrollment config from netbird.local.json if present and env
# unset (local builds; CI presets PPSA_NB_* from secrets — mirrors the
# wireguard.local.json handling above).
NB_LOCAL_JSON=""
for candidate in \
  "$(dirname "$(readlink -f "$0" 2>/dev/null || echo "$0")")/../netbird.local.json" \
  "./netbird.local.json" \
  "/etc/ppsa/netbird.local.json"; do
  if [ -f "$candidate" ]; then
    NB_LOCAL_JSON="$candidate"
    break
  fi
done
if [ -n "$NB_LOCAL_JSON" ] && [ -z "${PPSA_NB_MANAGEMENT_URL:-}" ]; then
  echo "PPSA NetBird: reading config from $NB_LOCAL_JSON"
  NB_PARSER=$(mktemp --suffix=.sh)
  NB_LOCAL_JSON="$NB_LOCAL_JSON" python3 - > "$NB_PARSER" 2>/dev/null <<'NBPYEOF'
import json, os
with open(os.environ["NB_LOCAL_JSON"]) as f:
    cfg = json.load(f)
cfg.pop("_comment", None)
if cfg.get("enabled"):
    def emit(k, v):
        sv = str(v).replace("\\", "\\\\").replace('"', '\\"').replace('$', '\\$').replace('`', '\\`')
        print(f'export {k}="{sv}"')
    emit("PPSA_NB_MANAGEMENT_URL", cfg.get("management_url", ""))
    emit("PPSA_NB_SETUP_KEY",      cfg.get("setup_key", ""))
NBPYEOF
  if [ -s "$NB_PARSER" ] && grep -q '^export ' "$NB_PARSER"; then
    # shellcheck disable=SC1090
    . "$NB_PARSER"
  fi
  rm -f "$NB_PARSER"
fi

# Bake /etc/ppsa/netbird.json — SINGLE all-fields write (the two-branch
# pattern silently dropped fields on the cache-hit path once; never again).
if [ -n "${PPSA_NB_MANAGEMENT_URL:-}" ] && [ -n "${PPSA_NB_SETUP_KEY:-}" ]; then NB_ENABLED_JSON="true"; else NB_ENABLED_JSON="false"; fi
cat > /etc/ppsa/netbird.json <<NBEOF
{
  "enabled": ${NB_ENABLED_JSON},
  "management_url": "${PPSA_NB_MANAGEMENT_URL:-}",
  "setup_key": "${PPSA_NB_SETUP_KEY:-}"
}
NBEOF
chmod 600 /etc/ppsa/netbird.json
echo "PPSA NetBird config: enabled=${NB_ENABLED_JSON} (management: '${PPSA_NB_MANAGEMENT_URL:-}')"

# Network policy: whether SSH (22, 10022) is opened on LAN/WAN at first boot.
# Default (unset/false): SSH is reachable only via the WG_FRIENDS chain
# (10.8.0.0/24, port 22 is in firewall.json's default allow-list) — nothing
# is broadcast on the LAN. Set PPSA_EXPOSE_SSH_LAN=true to also open SSH
# globally via ufw, e.g. for LAN-based recovery/debugging.
if [ "${PPSA_EXPOSE_SSH_LAN:-false}" = "true" ]; then EXPOSE_SSH_LAN_JSON="true"; else EXPOSE_SSH_LAN_JSON="false"; fi
cat > /etc/ppsa/network-policy.json <<POLEOF
{
  "expose_ssh_lan": ${EXPOSE_SSH_LAN_JSON}
}
POLEOF
chmod 644 /etc/ppsa/network-policy.json
echo "PPSA network policy: expose_ssh_lan=${EXPOSE_SSH_LAN_JSON}"

# --- Network: DHCP on first Ethernet interface ---
cat > /etc/systemd/network/20-wired.network <<NETEOF
[Match]
Name=en*

[Network]
DHCP=ipv4
NETEOF

# --- Filesystem table (needed so systemd-remount-fs knows to remount root rw) ---
cat > /etc/fstab <<FSTABEOF
# PPSA root filesystem
LABEL=PPSA_ROOT / ext4 defaults,errors=remount-ro 0 1
# EFI System Partition
LABEL=PPSA_BOOT /boot/efi vfat umask=0077 0 2
FSTABEOF

# --- PPSA first-boot flag ---
cat > /etc/systemd/system/ppsa-install.service <<SERVICEEOF
[Unit]
Description=PPSA First Boot Setup
After=network-online.target docker.service
Wants=network-online.target
ConditionPathExists=!/opt/ppsa/.installed

[Service]
Type=oneshot
ExecStart=/opt/ppsa/scripts/install.sh
RemainAfterExit=yes
User=root

[Install]
WantedBy=multi-user.target
SERVICEEOF

systemctl enable ppsa-install

# --- PPSA first-boot tty1 progress display ---
# This service takes over /dev/tty1 during first boot, shows a live
# progress bar + step list, and exits when install completes (or the
# user presses a key). After it exits, the getty on tty1 takes over
# (autologin as ppsa — see below).
# The ppsa-firstboot.sh and .service files are copied to
# /opt/ppsa/scripts/ by the post-chroot `cp -a "$PPSA_SRC/."
# "$ROOTFS_DIR/opt/ppsa/"` step. We pre-write the .service here
# (the chroot runs before the cp) and enable it.
cat > /etc/systemd/system/ppsa-firstboot.service <<FIRSTBOOTEOF
[Unit]
Description=PPSA First Boot Progress Display
After=systemd-logind.service getty-pre.target
Before=getty@tty1.service
# Only run on first boot. After install, the .installed flag exists and
# we never run again.
ConditionPathExists=!/opt/ppsa/.installed
# No Conflicts=getty@tty1.service here: systemd honors a unit's Conflicts=
# as part of the boot transaction even when that unit's own ConditionPathExists
# then skips it, which permanently blocked getty@tty1.service from ever
# starting again on every boot after the first (no console, no login prompt,
# looked like a hang). getty@tty1.service instead carries its own
# ConditionPathExists=/opt/ppsa/.installed override (see the
# getty@tty1.service.d/autologin.conf drop-in below), so it simply doesn't
# start at all until install.sh has finished — no fighting over the tty
# needed. TTYReset=yes/TTYVHangup=yes below are kept as a belt-and-suspenders
# reclaim in case anything else is holding tty1.

[Service]
Type=simple
ExecStart=/opt/ppsa/scripts/ppsa-firstboot.sh
StandardInput=tty
StandardOutput=tty
StandardError=tty
TTYPath=/dev/tty1
TTYReset=yes
TTYVHangup=yes
User=root
Restart=no
TimeoutStopSec=35
# getty@tty1.service's own ConditionPathExists=/opt/ppsa/.installed is only
# evaluated once, as part of the initial boot transaction — at that point
# .installed doesn't exist yet, so getty gets marked "skipped" and nothing
# re-queues a start job for it later, leaving tty1 permanently blank even
# though the system is fully alive underneath. By the time this service
# stops, install.sh has already created .installed (that's why "PPSA is
# ready" was showing), so explicitly starting getty here makes the handoff
# deterministic instead of relying on systemd to retry a condition check
# that never gets re-triggered.
ExecStopPost=/bin/systemctl start getty@tty1.service

[Install]
WantedBy=multi-user.target
FIRSTBOOTEOF
systemctl enable ppsa-firstboot.service
echo "PPSA first-boot progress display: enabled"

# --- Autologin on tty1 (after firstboot releases it) ---
# Standard systemd pattern: drop an override for getty@tty1.service
# that adds --autologin ppsa and skips the login prompt.
#
# ConditionPathExists=/opt/ppsa/.installed makes getty@tty1.service refuse
# to start at all until install.sh has finished. This is what actually
# keeps tty1 exclusive to ppsa-firstboot.service during the real first
# boot — ppsa-firstboot.service is Type=simple, so systemd considers it
# "started" the instant the process forks, well before it's actually
# grabbed the tty; relying on Before=getty@tty1.service alone let getty
# start almost simultaneously and race-kill the firstboot progress
# display via SIGHUP a few seconds in (install itself kept running fine
# underneath, just the TUI died). Gating getty on the .installed flag
# instead of fighting over the tty with Conflicts= avoids that race, and
# also avoids the opposite bug: Conflicts=getty@tty1.service on
# ppsa-firstboot.service used to permanently block getty on every boot
# after the first, even once ppsa-firstboot.service's own condition
# skipped it (systemd still honors Conflicts= as part of the boot
# transaction) — see ppsa-firstboot.service's own comment for that one.
mkdir -p /etc/systemd/system/getty@tty1.service.d
cat > /etc/systemd/system/getty@tty1.service.d/autologin.conf <<AUTOLOGINEOF
[Unit]
ConditionPathExists=/opt/ppsa/.installed

[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin ppsa --noclear %I \$TERM
AUTOLOGINEOF
echo "Autologin on tty1: enabled (ppsa), gated on /opt/ppsa/.installed"

# --- profile.d: show a welcome message on each interactive login ---
cat > /etc/profile.d/ppsa-welcome.sh <<WELCOMEEOF
# Show a brief PPSA welcome on every interactive login.
if [ -n "\$PS1" ] && [ -z "\$PPSA_WELCOME_SHOWN" ]; then
    export PPSA_WELCOME_SHOWN=1
    _ppsa_ip=\$(ip -4 addr show 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v '127.0.0.1' | head -1)
    if [ -n "\$_ppsa_ip" ]; then
        echo ""
        echo "  PPSA - Palworld Server Appliance"
        echo "  Web UI:   http://\$_ppsa_ip:8080    Login: admin / admin"
        echo "  SSH:      ppsa@\$_ppsa_ip            Password: ppsa"
        echo ""
    fi
fi
WELCOMEEOF
chmod 755 /etc/profile.d/ppsa-welcome.sh

# --- MOTD ---
# The first-boot progress UI runs on tty1 during install. After install
# completes, the welcome shows the connection details. This MOTD is the
# fallback for SSH logins (profile.d handles login display).
cat > /etc/motd <<MOTDEOF
╔══════════════════════════════════════════════════╗
║     PPSA - Palworld Server Appliance             ║
║     This message is the SSH/console fallback.    ║
║     The tty1 first-boot screen will show          ║
║     progress during install.                     ║
╚══════════════════════════════════════════════════╝
MOTDEOF

echo "Chroot setup complete."
CHROOTEOF

chmod +x "$ROOTFS_DIR/tmp/setup.sh"

# The chroot setup installs PPSA systemd units that live in /opt/ppsa/scripts.
# Stage the scripts before running it; the full repo is copied again after the
# chroot so cached rootfs builds still pick up every source change.
mkdir -p "$ROOTFS_DIR/opt/ppsa"
cp -a "$PPSA_SRC/scripts" "$ROOTFS_DIR/opt/ppsa/"
chmod +x "$ROOTFS_DIR/opt/ppsa/scripts/"*.sh 2>/dev/null || true

chroot "$ROOTFS_DIR" /bin/bash /tmp/setup.sh
rm "$ROOTFS_DIR/tmp/setup.sh"

# --- Clean up mounts ---
echo -e "${GREEN}Cleaning up chroot mounts...${NC}"
umount "$ROOTFS_DIR/dev/pts" 2>/dev/null || true
umount "$ROOTFS_DIR/dev" 2>/dev/null || true
umount "$ROOTFS_DIR/proc" 2>/dev/null || true
umount "$ROOTFS_DIR/sys" 2>/dev/null || true

fi  # end of PPSA_SKIP_BOOTSTRAP conditional

# Re-write /etc/ppsa/wireguard.json OUTSIDE the chroot after the cache
# restore. The chroot setup (lines 367-410 above) writes the same
# file but is skipped when PPSA_SKIP_BOOTSTRAP is set (= CI cache
# hit). Without this re-write, the cached wireguard.json (from the
# previous build) ends up in the image even when PPSA_WG_* env vars
# have changed. Same logic as the in-chroot write, just running
# against $ROOTFS_DIR directly.
mkdir -p "$ROOTFS_DIR/etc/ppsa"
chmod 755 "$ROOTFS_DIR/etc/ppsa"
if [ -n "${PPSA_WG_API_URL:-}" ] && [ -n "${PPSA_WG_API_USER:-}" ] && [ -n "${PPSA_WG_API_PASS:-}" ]; then
    # WG deprecated (NetBird primary): enabled defaults false, flip on with
    # PPSA_WG_ENABLED=true. Mirror of the in-chroot bake above.
    if [ "${PPSA_WG_ENABLED:-false}" = "true" ]; then WG_ENABLED_JSON=true; else WG_ENABLED_JSON=false; fi
    # Single write with every field (empty string when unset), matching the
    # in-chroot bake. Earlier this had two branches that omitted lan_endpoint
    # and public_endpoint entirely, so a cache-hit rebuild (which runs this
    # outside-chroot path) silently dropped them from the baked config.
    cat > "$ROOTFS_DIR/etc/ppsa/wireguard.json" <<WGEOF
{
  "enabled": ${WG_ENABLED_JSON},
  "api_url": "${PPSA_WG_API_URL}",
  "api_user": "${PPSA_WG_API_USER}",
  "api_password": "${PPSA_WG_API_PASS}",
  "peer_name": "${PPSA_WG_PEER_NAME:-ppsa-server}",
  "preferred_ip": "${PPSA_WG_PREFERRED_IP:-}",
  "lan_endpoint": "${PPSA_WG_LAN_ENDPOINT:-}",
  "public_endpoint": "${PPSA_WG_PUBLIC_ENDPOINT:-}"
}
WGEOF
    chmod 600 "$ROOTFS_DIR/etc/ppsa/wireguard.json"
    echo "PPSA WireGuard config: re-baked (enabled=${WG_ENABLED_JSON} [deprecated; set PPSA_WG_ENABLED=true to activate], peer: ${PPSA_WG_PEER_NAME:-ppsa-server}, preferred_ip: '${PPSA_WG_PREFERRED_IP:-}', lan_endpoint: '${PPSA_WG_LAN_ENDPOINT:-}', public_endpoint: '${PPSA_WG_PUBLIC_ENDPOINT:-}')"
else
    # Don't overwrite the cached (or newly-built) file if we have no creds.
    # The cached version, if any, wins; otherwise install.sh's WebUI flow
    # will eventually fill this in.
    if [ ! -f "$ROOTFS_DIR/etc/ppsa/wireguard.json" ]; then
        cat > "$ROOTFS_DIR/etc/ppsa/wireguard.json" <<WGEOF
{
  "enabled": false,
  "api_url": "",
  "api_user": "",
  "api_password": "",
  "peer_name": "ppsa-server"
}
WGEOF
        chmod 600 "$ROOTFS_DIR/etc/ppsa/wireguard.json"
        echo "PPSA WireGuard config: not configured (set PPSA_WG_* env vars to bake in)"
    fi
fi

# Re-write the fallback config OUTSIDE the chroot too, same cache-hit
# reasoning as wireguard.json above.
if [ -n "${PPSA_WG_FALLBACK_CONF_B64:-}" ]; then
    mkdir -p "$ROOTFS_DIR/etc/ppsa"
    echo "${PPSA_WG_FALLBACK_CONF_B64}" | base64 -d > "$ROOTFS_DIR/etc/ppsa/wireguard-fallback.conf"
    chmod 600 "$ROOTFS_DIR/etc/ppsa/wireguard-fallback.conf"
    echo "PPSA WireGuard fallback config: re-baked"
fi

# Re-write /etc/ppsa/netbird.json OUTSIDE the chroot too (cache-hit path
# skips the in-chroot bake). SINGLE all-fields write, no branches that
# drop fields — the wireguard.json cache-drop bug must not repeat here.
# Local netbird.local.json parse for direct/WSL builds (CI presets env).
if [ -z "${PPSA_NB_MANAGEMENT_URL:-}" ] && [ -f "$PPSA_SRC/netbird.local.json" ]; then
    echo "PPSA NetBird: reading config from $PPSA_SRC/netbird.local.json (outside-chroot)"
    NB_VALS=$(NB_LOCAL_JSON="$PPSA_SRC/netbird.local.json" python3 - 2>/dev/null <<'NBPYEOF'
import json, os
with open(os.environ["NB_LOCAL_JSON"]) as f:
    cfg = json.load(f)
cfg.pop("_comment", None)
if cfg.get("enabled"):
    def emit(k, v):
        sv = str(v).replace("\\", "\\\\").replace('"', '\\"').replace('$', '\\$').replace('`', '\\`')
        print(f'export {k}="{sv}"')
    emit("PPSA_NB_MANAGEMENT_URL", cfg.get("management_url", ""))
    emit("PPSA_NB_SETUP_KEY",      cfg.get("setup_key", ""))
NBPYEOF
) || true
    if [ -n "$NB_VALS" ]; then eval "$NB_VALS"; fi
fi
mkdir -p "$ROOTFS_DIR/etc/ppsa"
if [ -n "${PPSA_NB_MANAGEMENT_URL:-}" ] && [ -n "${PPSA_NB_SETUP_KEY:-}" ]; then NB_ENABLED_JSON="true"; else NB_ENABLED_JSON="false"; fi
# Don't clobber a cached enabled config with a disabled one when env is
# simply absent AND a baked file already exists (mirror wireguard.json's
# no-creds behaviour).
if [ "$NB_ENABLED_JSON" = "true" ] || [ ! -f "$ROOTFS_DIR/etc/ppsa/netbird.json" ]; then
    cat > "$ROOTFS_DIR/etc/ppsa/netbird.json" <<NBEOF
{
  "enabled": ${NB_ENABLED_JSON},
  "management_url": "${PPSA_NB_MANAGEMENT_URL:-}",
  "setup_key": "${PPSA_NB_SETUP_KEY:-}"
}
NBEOF
    chmod 600 "$ROOTFS_DIR/etc/ppsa/netbird.json"
    echo "PPSA NetBird config: re-baked (enabled=${NB_ENABLED_JSON}, management: '${PPSA_NB_MANAGEMENT_URL:-}')"
fi

# Re-write network-policy.json OUTSIDE the chroot too (same cache-hit
# reasoning as wireguard.json above) — always reflects the current
# PPSA_EXPOSE_SSH_LAN env var, never a stale cached value.
if [ "${PPSA_EXPOSE_SSH_LAN:-false}" = "true" ]; then EXPOSE_SSH_LAN_JSON="true"; else EXPOSE_SSH_LAN_JSON="false"; fi
cat > "$ROOTFS_DIR/etc/ppsa/network-policy.json" <<POLEOF
{
  "expose_ssh_lan": ${EXPOSE_SSH_LAN_JSON}
}
POLEOF
chmod 644 "$ROOTFS_DIR/etc/ppsa/network-policy.json"
echo "PPSA network policy: expose_ssh_lan=${EXPOSE_SSH_LAN_JSON}"

# --- Copy PPSA files (always, even on cache hit — repo may have changed) ---
echo -e "${GREEN}[4/7] Copying PPSA files...${NC}"
mkdir -p "$ROOTFS_DIR/opt/ppsa"
cp -a "$PPSA_SRC/." "$ROOTFS_DIR/opt/ppsa/"
rm -rf "$ROOTFS_DIR/opt/ppsa/build" "$ROOTFS_DIR/opt/ppsa/.git" "$ROOTFS_DIR/opt/ppsa/preseed"
# Fix execute bits (Windows git doesn't track +x)
chmod +x "$ROOTFS_DIR/opt/ppsa/scripts/"*.sh 2>/dev/null || true
chmod +x "$ROOTFS_DIR/opt/ppsa/oracle/"*.sh 2>/dev/null || true
find "$ROOTFS_DIR/opt/ppsa" -type f -name "*.sh" -exec chmod +x {} \;

# Stamp the version into the image so /opt/ppsa/VERSION reflects the build.
# The CI workflow also tags releases, but this lets the running system
# self-report its version on first boot (tty1 splash) without depending
# on a git repo being present.
# Derive the version from the closest git tag; fall back to a date stamp.
PPSA_VERSION=$(cd "$PPSA_SRC" && git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || true)
if [ -z "$PPSA_VERSION" ]; then
    PPSA_VERSION="$(date -u +%Y.%m.%d)-dev"
fi
echo "$PPSA_VERSION" > "$ROOTFS_DIR/opt/ppsa/VERSION"
echo "Stamped PPSA version: $PPSA_VERSION"

# Create symlinks for PATH
mkdir -p "$ROOTFS_DIR/usr/local/bin"
ln -sf /opt/ppsa/scripts/install.sh "$ROOTFS_DIR/usr/local/bin/ppsa-install"
ln -sf /opt/ppsa/scripts/first-boot.sh "$ROOTFS_DIR/usr/local/bin/ppsa-setup"

# Save cache if requested (after bootstrap + PPSA copy, before disk image)
if [ -n "${PPSA_CACHE_FILE:-}" ] && [ -z "${PPSA_SKIP_BOOTSTRAP:-}" ] && [ ! -f "$PPSA_CACHE_FILE" ]; then
    echo "Saving rootfs cache to $PPSA_CACHE_FILE..."
    mkdir -p "$(dirname "$PPSA_CACHE_FILE")"
    tar -czf "$PPSA_CACHE_FILE" -C "$(dirname "$ROOTFS_DIR")" "$(basename "$ROOTFS_DIR")"
    echo "Rootfs cache saved."
fi

# =============================================================================
# Step 5: Create disk image
# =============================================================================
echo -e "${GREEN}[6/7] Creating disk image ($IMG_SIZE_MB MB)...${NC}"

# Create blank image
dd if=/dev/zero of="$OUTPUT_IMG" bs=1M count="$IMG_SIZE_MB" status=progress

# Partition: GPT with EFI System Partition + Linux root
parted -s "$OUTPUT_IMG" mklabel gpt
parted -s "$OUTPUT_IMG" mkpart primary fat32 1MiB "$((EFI_SIZE_MB + 1))MiB"
parted -s "$OUTPUT_IMG" set 1 esp on
parted -s "$OUTPUT_IMG" mkpart primary ext4 "$((EFI_SIZE_MB + 1))MiB" 100%

# Set up loop device
LOOP_DEV=$(losetup -f --show -P "$OUTPUT_IMG")
EFI_PART=$(ensure_loop_partition_node "$LOOP_DEV" 1)
ROOT_PART=$(ensure_loop_partition_node "$LOOP_DEV" 2)

# Format partitions
mkfs.fat -F 32 -n "PPSA_BOOT" "$EFI_PART"
mkfs.ext4 -F -L "PPSA_ROOT" "$ROOT_PART"

# Capture root partition UUID (used by Limine config to find kernel+initrd)
ROOT_UUID=$(blkid -s UUID -o value "$ROOT_PART")
echo "Root partition UUID: $ROOT_UUID"

# Mount and copy rootfs
MOUNT_DIR="$BUILD_DIR/mnt"
mkdir -p "$MOUNT_DIR"
mount "$ROOT_PART" "$MOUNT_DIR"
mkdir -p "$MOUNT_DIR/boot/efi"
mount "$EFI_PART" "$MOUNT_DIR/boot/efi"

echo "Copying root filesystem (this takes a while)..."
rsync -aHAX "$ROOTFS_DIR/" "$MOUNT_DIR/"

# Install GRUB bootloader (both UEFI and BIOS)
echo "Installing GRUB bootloader..."

# Mount kernel filesystems for grub-install to work (it probes devices)
mount --bind /dev "$MOUNT_DIR/dev"
mount --bind /proc "$MOUNT_DIR/proc"
mount --bind /sys "$MOUNT_DIR/sys"

# UEFI: install to the ESP with a portable, Secure-Boot-capable chain.
#
# The plain `grub-install --removable` flow embeds a device+path in the
# EFI binary's prefix. That prefix is correct for the build host, but
# breaks when the image is dd'd to a different disk (different controller,
# different controller order, or just a different geometry): GRUB drops
# to rescue shell because (hd0,gpt2)/boot/grub no longer exists.
#
# grub-install still runs first to populate /boot/grub (modules, fonts,
# grubenv) for non-Secure-Boot boots and on-device maintenance.
grub-install --target=x86_64-efi \
    --efi-directory="$MOUNT_DIR/boot/efi" \
    --boot-directory="$MOUNT_DIR/boot" \
    --recheck \
    --no-nvram 2>&1

# Secure Boot chain (primary): copy Debian's prebuilt signed binaries onto
# the ESP using the removable-media layout that Debian/Ubuntu live ISOs use:
#   EFI/BOOT/BOOTX64.EFI  = shim (Microsoft-signed; firmware trusts it)
#   EFI/BOOT/grubx64.efi  = Debian-signed monolithic GRUB (verified by shim)
#   EFI/BOOT/mmx64.efi    = MokManager (shim falls back to it on failure)
# fbx64.efi is deliberately NOT copied: with it present, shim tries to
# create NVRAM boot entries from BOOT.CSV, which is wrong for removable
# media and can reboot-loop. Without it, shim chainloads grubx64.efi.
#
# The signed GRUB core has prefix /EFI/debian baked in (verified via
# strings on trixie's grubx64.efi.signed), resolved relative to the device
# it booted from — so it reads EFI/debian/grub.cfg from OUR ESP no matter
# what disk the image was dd'd to. That file does the same search-by-UUID
# redirect the old standalone loader embedded, keeping full portability.
# GRUB configs are not signature-checked (only shim/GRUB/kernel binaries
# are), so the redirect works identically under Secure Boot.
SHIM_SIGNED="$MOUNT_DIR/usr/lib/shim/shimx64.efi.signed"
MM_SIGNED="$MOUNT_DIR/usr/lib/shim/mmx64.efi.signed"
GRUB_SIGNED="$MOUNT_DIR/usr/lib/grub/x86_64-efi-signed/grubx64.efi.signed"

mkdir -p "$MOUNT_DIR/boot/efi/EFI/BOOT"
if [ -f "$SHIM_SIGNED" ] && [ -f "$GRUB_SIGNED" ]; then
    cp "$SHIM_SIGNED" "$MOUNT_DIR/boot/efi/EFI/BOOT/BOOTX64.EFI"
    cp "$GRUB_SIGNED" "$MOUNT_DIR/boot/efi/EFI/BOOT/grubx64.efi"
    if [ -f "$MM_SIGNED" ]; then
        cp "$MM_SIGNED" "$MOUNT_DIR/boot/efi/EFI/BOOT/mmx64.efi"
    fi

    # Config at the signed GRUB's baked-in prefix. No insmod needed: the
    # signed core has search/part_gpt/ext2/linux etc. built in (and under
    # Secure Boot, loading .mod files from disk is blocked anyway -
    # everything the menu needs must be, and is, built in).
    #
    # The menu entries are embedded directly here rather than doing
    # search+set-prefix+configfile out to a second grub.cfg. That two-hop
    # redirect (needed only for the *unsigned* grub-mkstandalone fallback
    # below, which has no baked-in prefix of its own) causes GRUB's
    # shim_lock verification of the kernel to fail here ("bad shim
    # signature") even though shim/GRUB/kernel are all validly signed -
    # the live-installer ISO's own boot (proven to work under Secure
    # Boot) never does this indirection, it boots straight off one
    # grub.cfg. Keeping one file removes the only structural difference.
    mkdir -p "$MOUNT_DIR/boot/efi/EFI/debian"
    cat > "$MOUNT_DIR/boot/efi/EFI/debian/grub.cfg" <<LOADEREOF
set default=0
set timeout=3

menuentry "PPSA Linux" {
    search --no-floppy --fs-uuid --set=root ${ROOT_UUID}
    linux /vmlinuz root=UUID=${ROOT_UUID} ro quiet mitigations=off
    initrd /initrd.img
}

menuentry "PPSA Linux (recovery)" {
    search --no-floppy --fs-uuid --set=root ${ROOT_UUID}
    linux /vmlinuz root=UUID=${ROOT_UUID} ro single
    initrd /initrd.img
}
LOADEREOF
    sed -i 's/\r$//' "$MOUNT_DIR/boot/efi/EFI/debian/grub.cfg" 2>/dev/null || true

    # Also populate EFI/debian with the signed set. grub-install above put
    # an UNSIGNED locally-built core at EFI/debian/grubx64.efi; firmware
    # boot-menu entries (or stale "debian" NVRAM entries from an earlier
    # install) that point into EFI/debian would hit it and throw a Secure
    # Boot violation even though the EFI/BOOT fallback path is signed.
    # Standard Debian layout: shimx64.efi (entry point) + signed grubx64.
    cp "$SHIM_SIGNED" "$MOUNT_DIR/boot/efi/EFI/debian/shimx64.efi"
    cp "$GRUB_SIGNED" "$MOUNT_DIR/boot/efi/EFI/debian/grubx64.efi"
    if [ -f "$MM_SIGNED" ]; then
        cp "$MM_SIGNED" "$MOUNT_DIR/boot/efi/EFI/debian/mmx64.efi"
    fi
    echo "GRUB (UEFI) Secure Boot chain installed (shim + signed GRUB, portable)."
else
    # Fallback (signed packages unavailable): self-contained unsigned
    # grub-mkstandalone image. Boots fine with Secure Boot disabled.
    # Curated module list, space-separated - Debian trixie's
    # grub-mkstandalone doesn't split on commas in --install-modules,
    # and diskfilter must be explicit or (hd0,gptN) stays invisible.
    echo "WARNING: signed shim/GRUB not found in rootfs - building unsigned loader (Secure Boot must be disabled to boot this image)."
    GRUB_MODULES="linux normal search configfile ls echo cat test true regexp part_gpt part_msdos fat ext2 btrfs xfs all_video gfxterm font diskfilter ahci ata usb ohci ehci uhci gettext serial terminal linux16 reboot"

    cat > /tmp/grub-standalone.cfg <<LOADEREOF
# Point prefix at the embedded memdisk so insmod can find the modules.
# Then load part_gpt/part_msdos (so the disk's partition table is
# readable) and search (so we can find the root by UUID). Only THEN
# set the real prefix and load the main config.
set prefix=(memdisk)/boot/grub
insmod all_video
insmod part_gpt
insmod part_msdos
insmod search
insmod search_fs_uuid
insmod search_label
search --no-floppy --fs-uuid --set=root ${ROOT_UUID}
set prefix=(\$root)/boot/grub
configfile (\$root)/boot/grub/grub.cfg
LOADEREOF

    grub-mkstandalone \
        --directory=/usr/lib/grub/x86_64-efi \
        --output="$MOUNT_DIR/boot/efi/EFI/BOOT/BOOTX64.EFI" \
        --format=x86_64-efi \
        --compress=xz \
        --install-modules="$GRUB_MODULES" \
        "boot/grub/grub.cfg=/tmp/grub-standalone.cfg" 2>&1
    rm -f /tmp/grub-standalone.cfg
    echo "GRUB (UEFI) standalone EFI binary built (curated module list, portable)."
fi

# BIOS: optional - requires a bios_grub partition on GPT disks.
# Skip if not available; UEFI is the primary boot path.
if parted -s "$OUTPUT_IMG" print | grep -q bios_grub 2>/dev/null; then
    grub-install --target=i386-pc \
        --boot-directory="$MOUNT_DIR/boot" \
        "$LOOP_DEV" \
        --recheck 2>&1
    echo "GRUB (BIOS) installed."
else
    echo "GRUB (BIOS) skipped - no bios_grub partition (UEFI only)."
fi

# Write /boot/grub/grub.cfg
if [ -n "$ROOT_UUID" ]; then
    mkdir -p "$MOUNT_DIR/boot/grub"
    cat > "$MOUNT_DIR/boot/grub/grub.cfg" <<GRUBEOF
set default=0
set timeout=3

menuentry "PPSA Linux" {
    search --no-floppy --fs-uuid --set=root ${ROOT_UUID}
    linux /vmlinuz root=UUID=${ROOT_UUID} ro quiet mitigations=off
    initrd /initrd.img
}

menuentry "PPSA Linux (recovery)" {
    search --no-floppy --fs-uuid --set=root ${ROOT_UUID}
    linux /vmlinuz root=UUID=${ROOT_UUID} ro single
    initrd /initrd.img
}
GRUBEOF
    sed -i 's/\r$//' "$MOUNT_DIR/boot/grub/grub.cfg" 2>/dev/null || true
    echo "grub.cfg written (UUID=$ROOT_UUID)."
else
    echo "WARNING: ROOT_UUID not detected; grub.cfg not written."
fi

# Clean up chroot mounts
umount "$MOUNT_DIR/dev" 2>/dev/null || true
umount "$MOUNT_DIR/proc" 2>/dev/null || true
umount "$MOUNT_DIR/sys" 2>/dev/null || true

# Clean up mounts
umount "$MOUNT_DIR/dev/pts" 2>/dev/null || true
umount "$MOUNT_DIR/dev" 2>/dev/null || true
umount "$MOUNT_DIR/proc" 2>/dev/null || true
umount "$MOUNT_DIR/sys" 2>/dev/null || true
umount "$MOUNT_DIR/boot/efi" 2>/dev/null || true
umount "$MOUNT_DIR" 2>/dev/null || true

# Detach loop device
losetup -d "$LOOP_DEV"

# =============================================================================
# Cleanup
# =============================================================================
echo -e "${GREEN}[7/7] Cleaning up...${NC}"
rm -rf "$BUILD_DIR"

# --- Summary ---
IMG_SIZE=$(ls -lh "$OUTPUT_IMG" | awk '{print $5}')
echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}  PPSA USB Image Built Successfully!${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo "  Image: $OUTPUT_IMG"
echo "  Size:  $IMG_SIZE"
echo ""
echo "  Write to USB with Rufus (DD mode) or:"
echo "    dd if=$OUTPUT_IMG of=/dev/sdX bs=4M status=progress"
echo ""
echo "  Minimum USB: 64GB SSD recommended"
echo "  Boot:        BIOS or UEFI (both supported)"
echo "  Credentials: ppsa / ppsa (change on first boot)"
echo ""
