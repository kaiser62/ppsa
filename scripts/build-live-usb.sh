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
#   debootstrap, parted, losetup, mkfs.ext4, mkfs.fat, grub-install
# =============================================================================

set -euo pipefail

# --- Configuration ---
OUTPUT_IMG=""
DEBIAN_VERSION="trixie"
DEBIAN_MIRROR="http://deb.debian.org/debian"
IMG_SIZE_MB=${PPSA_IMG_SIZE_MB:-8192}        # 8GB default (fills 32GB+ USB after resize2fs)
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
DEPS="debootstrap parted e2fsprogs dosfstools grub-pc-bin grub-efi-amd64-bin"
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

# --- Locale ---
locale-gen en_US.UTF-8
echo "LANG=en_US.UTF-8" > /etc/default/locale

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
apt-get install -y -qq linux-image-amd64 linux-headers-amd64 firmware-linux firmware-linux-nonfree
# GRUB (UEFI + BIOS) needed for grub-install when building disk image
# Use -bin packages to avoid Conflicts between grub-pc and grub-efi-amd64
apt-get install -y -qq grub-pc-bin grub-efi-amd64-bin grub2-common

# Docker (compose v2 included in docker.io in Trixie)
apt-get install -y -qq docker.io containerd

# Networking + VPN
apt-get install -y -qq wireguard wireguard-tools openresolv

# System tools (cloud-guest-utils provides growpart for first-boot resize)
apt-get install -y -qq \
    ufw fail2ban htop iotop net-tools \
    openssh-server nftables rsync \
    python3 python3-pip python3-venv \
    sudo curl wget vim-tiny lsof \
    cloud-guest-utils

# Clean up
apt-get clean
rm -rf /var/lib/apt/lists/*

# --- Users ---
useradd -m -s /bin/bash -G sudo,docker ppsa
echo "ppsa ALL=(ALL) ALL" > /etc/sudoers.d/ppsa
chmod 440 /etc/sudoers.d/ppsa
echo "ppsa:ppsa" | chpasswd
passwd -d root 2>/dev/null || true  # no root password, use sudo

# --- SSH: allow password auth for first setup ---
sed -i 's/#PasswordAuthentication yes/PasswordAuthentication yes/' /etc/ssh/sshd_config

# --- Enable services ---
systemctl enable docker
systemctl enable ssh
systemctl enable systemd-networkd

# --- Network: DHCP on first Ethernet interface ---
cat > /etc/systemd/network/20-wired.network <<NETEOF
[Match]
Name=en*

[Network]
DHCP=ipv4
NETEOF

# --- GRUB config (create default, -bin packages don't ship it) ---
cat > /etc/default/grub <<'GRUBEOF'
GRUB_DEFAULT=0
GRUB_TIMEOUT=5
GRUB_CMDLINE_LINUX=""
GRUB_CMDLINE_LINUX_DEFAULT="quiet"
GRUB_TERMINAL=console
GRUB_DISABLE_RECOVERY=true
GRUB_DISABLE_OS_PROBER=true
GRUBEOF
sed -i 's/GRUB_TIMEOUT=5/GRUB_TIMEOUT=2/' /etc/default/grub
sed -i 's/GRUB_CMDLINE_LINUX=""/GRUB_CMDLINE_LINUX="quiet mitigations=off"/' /etc/default/grub

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

# --- MOTD ---
cat > /etc/motd <<MOTDEOF
╔══════════════════════════════════════════════════╗
║     PPSA - Palworld Server Appliance             ║
║     The server is starting up...                 ║
║     Web UI:  http://(this-ip):8080               ║
╚══════════════════════════════════════════════════╝
MOTDEOF

echo "Chroot setup complete."
CHROOTEOF

chmod +x "$ROOTFS_DIR/tmp/setup.sh"
chroot "$ROOTFS_DIR" /bin/bash /tmp/setup.sh
rm "$ROOTFS_DIR/tmp/setup.sh"

# --- Copy PPSA files ---
echo -e "${GREEN}[4/7] Copying PPSA files...${NC}"
mkdir -p "$ROOTFS_DIR/opt/ppsa"
cp -a "$PPSA_SRC/." "$ROOTFS_DIR/opt/ppsa/"
# Remove build artifacts
rm -rf "$ROOTFS_DIR/opt/ppsa/build" "$ROOTFS_DIR/opt/ppsa/.git" "$ROOTFS_DIR/opt/ppsa/preseed"

# Create symlinks for PATH
mkdir -p "$ROOTFS_DIR/usr/local/bin"
ln -sf /opt/ppsa/scripts/install.sh "$ROOTFS_DIR/usr/local/bin/ppsa-install"
ln -sf /opt/ppsa/scripts/first-boot.sh "$ROOTFS_DIR/usr/local/bin/ppsa-setup"

# --- Clean up mounts ---
echo -e "${GREEN}[5/7] Cleaning up chroot mounts...${NC}"
umount "$ROOTFS_DIR/dev/pts" 2>/dev/null || true
umount "$ROOTFS_DIR/dev" 2>/dev/null || true
umount "$ROOTFS_DIR/proc" 2>/dev/null || true
umount "$ROOTFS_DIR/sys" 2>/dev/null || true

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

# Mount and copy rootfs
MOUNT_DIR="$BUILD_DIR/mnt"
mkdir -p "$MOUNT_DIR"
mount "$ROOT_PART" "$MOUNT_DIR"
mkdir -p "$MOUNT_DIR/boot/efi"
mount "$EFI_PART" "$MOUNT_DIR/boot/efi"

echo "Copying root filesystem (this takes a while)..."
rsync -aHAX "$ROOTFS_DIR/" "$MOUNT_DIR/"

# Install GRUB for both BIOS and UEFI
echo "Installing GRUB..."
mount --bind /dev "$MOUNT_DIR/dev"
mount --bind /proc "$MOUNT_DIR/proc"
mount --bind /sys "$MOUNT_DIR/sys"

chroot "$MOUNT_DIR" /bin/bash <<GRUBEOF
grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=PPSA --recheck
grub-install --target=i386-pc "$LOOP_DEV" --recheck
update-grub
GRUBEOF

# Copy the GRUB EFI binary to the standard fallback path
if [ -f "$MOUNT_DIR/boot/efi/EFI/PPSA/grubx64.efi" ]; then
    mkdir -p "$MOUNT_DIR/boot/efi/EFI/BOOT"
    cp "$MOUNT_DIR/boot/efi/EFI/PPSA/grubx64.efi" "$MOUNT_DIR/boot/efi/EFI/BOOT/BOOTx64.EFI"
fi

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
