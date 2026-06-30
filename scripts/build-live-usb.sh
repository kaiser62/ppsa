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

# --- DNS: write a static resolv.conf pointing to public resolvers ---
# Avoids the systemd-resolved 127.0.0.53#53 connection-refused trap.
# On a server appliance, public DNS is more reliable than depending on
# systemd-resolved (which may not be enabled in minimal images) or
# DHCP-supplied DNS (which is empty until network comes up).
cat > /etc/resolv.conf <<'DNSEOF'
nameserver 8.8.8.8
nameserver 1.1.1.1
nameserver 9.9.9.9
options edns0 trust-ad
DNSEOF

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

# GRUB bootloader - install tools in image for maintenance
apt-get install -y -qq grub2-common

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
echo "ppsa ALL=(ALL) ALL" > /etc/sudoers.d/ppsa
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
dns=default
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
    systemctl enable ppsa-wifi-onboard.service
    echo "PPSA Wi-Fi onboarding: enabled"
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
    if [ -n "${PPSA_WG_PREFERRED_IP:-}" ]; then
        cat > /etc/ppsa/wireguard.json <<WGEOF
{
  "enabled": true,
  "api_url": "${PPSA_WG_API_URL}",
  "api_user": "${PPSA_WG_API_USER}",
  "api_password": "${PPSA_WG_API_PASS}",
  "peer_name": "${PPSA_WG_PEER_NAME:-ppsa-server}",
  "preferred_ip": "${PPSA_WG_PREFERRED_IP}"
}
WGEOF
        echo "PPSA WireGuard config: baked in (peer: ${PPSA_WG_PEER_NAME:-ppsa-server}, preferred_ip: ${PPSA_WG_PREFERRED_IP})"
    else
        cat > /etc/ppsa/wireguard.json <<WGEOF
{
  "enabled": true,
  "api_url": "${PPSA_WG_API_URL}",
  "api_user": "${PPSA_WG_API_USER}",
  "api_password": "${PPSA_WG_API_PASS}",
  "peer_name": "${PPSA_WG_PEER_NAME:-ppsa-server}"
}
WGEOF
        echo "PPSA WireGuard config: baked in (peer: ${PPSA_WG_PEER_NAME:-ppsa-server})"
    fi
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
# Stop the getty from competing for tty1 while we run.
Conflicts=getty@tty1.service

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

[Install]
WantedBy=multi-user.target
FIRSTBOOTEOF
systemctl enable ppsa-firstboot.service
echo "PPSA first-boot progress display: enabled"

# --- Autologin on tty1 (after firstboot releases it) ---
# Standard systemd pattern: drop an override for getty@tty1.service
# that adds --autologin ppsa and skips the login prompt. The firstboot
# service runs Before=getty@tty1 so this only kicks in after install
# has finished and the user has dismissed the progress screen.
mkdir -p /etc/systemd/system/getty@tty1.service.d
cat > /etc/systemd/system/getty@tty1.service.d/autologin.conf <<AUTOLOGINEOF
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin ppsa --noclear %I \$TERM
AUTOLOGINEOF
echo "Autologin on tty1: enabled (ppsa)"

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
chroot "$ROOTFS_DIR" /bin/bash /tmp/setup.sh
rm "$ROOTFS_DIR/tmp/setup.sh"

# --- Clean up mounts ---
echo -e "${GREEN}Cleaning up chroot mounts...${NC}"
umount "$ROOTFS_DIR/dev/pts" 2>/dev/null || true
umount "$ROOTFS_DIR/dev" 2>/dev/null || true
umount "$ROOTFS_DIR/proc" 2>/dev/null || true
umount "$ROOTFS_DIR/sys" 2>/dev/null || true

fi  # end of PPSA_SKIP_BOOTSTRAP conditional

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
EFI_PART="${LOOP_DEV}p1"
ROOT_PART="${LOOP_DEV}p2"

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

# UEFI: install to the ESP
grub-install --target=x86_64-efi \
    --efi-directory="$MOUNT_DIR/boot/efi" \
    --boot-directory="$MOUNT_DIR/boot" \
    --recheck \
    --no-nvram 2>&1
echo "GRUB (UEFI) installed."

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
