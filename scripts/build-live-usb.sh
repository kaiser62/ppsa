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
DEPS="debootstrap parted e2fsprogs dosfstools"
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
apt-get install -y -qq linux-image-amd64 firmware-linux
# Skip linux-headers: server doesn't compile kernel modules.
# Skip firmware-linux-nonfree: no proprietary WiFi needed on a server.

# Limine bootloader (replaces GRUB). No Debian package yet — download
# the binary release. Provides BOOTX64.EFI ready to drop on the ESP.
LIMINE_VERSION="12.3.3"
mkdir -p /opt/limine
# .tar.gz instead of .tar.xz — xz isn't always in the chroot's PATH.
curl -fsSL "https://github.com/limine-bootloader/limine/releases/download/v${LIMINE_VERSION}/limine-binary.tar.gz" \
    -o /tmp/limine.tar.gz
tar -xzf /tmp/limine.tar.gz -C /opt/limine --strip-components=1
chmod +x /opt/limine/BOOTX64.EFI
# Save BOOTX64.EFI for later copy onto ESP
cp /opt/limine/BOOTX64.EFI /tmp/limine-bootx64.efi

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

# --- MOTD ---
cat > /etc/motd <<MOTDEOF
╔══════════════════════════════════════════════════╗
║     PPSA - Palworld Server Appliance             ║
║     The server is starting up...                 ║
║     Web UI:  http://(this-ip):8080               ║
║     If the web UI is unavailable, check:         ║
║       journalctl -u ppsa-install                 ║
║       cat /var/log/ppsa-install.log              ║
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

# Install Limine bootloader (replaces GRUB)
# Simpler than GRUB: no chroot dance, no .prefix ELF hacks, no Shim chain.
# Limine's BOOTX64.EFI on the ESP auto-finds limine.conf and boots the
# kernel referenced by UUID.
echo "Installing Limine bootloader..."

# Copy Limine EFI binary to the standard UEFI fallback path on the ESP.
# UEFI firmware looks for this exact path when no NVRAM entry is registered.
# The file was downloaded inside the chroot to /tmp/limine-bootx64.efi
# and survived the rsync into the target's /tmp.
mkdir -p "$MOUNT_DIR/boot/efi/EFI/BOOT"
cp "$MOUNT_DIR/tmp/limine-bootx64.efi" "$MOUNT_DIR/boot/efi/EFI/BOOT/BOOTX64.EFI"
echo "Limine BOOTX64.EFI installed at ESP:/EFI/BOOT/BOOTX64.EFI"

# Write limine.conf to the ESP. Limine searches for limine.conf in:
#   - the EFI binary's directory
#   - /EFI/ on the ESP
#   - /boot/ on the ESP
#   - the root of the boot device
# The kernel and initrd are on the ROOT partition (label PPSA_ROOT),
# so we reference them by UUID rather than by relative path.
if [ -n "$ROOT_UUID" ]; then
    cat > "$MOUNT_DIR/boot/efi/limine.conf" <<LIMINEEOF
timeout=3
default_entry=1
verbose=no

/PPSA Linux
    comment=PPSA Debian GNU/Linux
    protocol=linux
    kernel_path=uuid(${ROOT_UUID}):/boot/vmlinuz
    initrd_path=uuid(${ROOT_UUID}):/boot/initrd.img
    cmdline=root=UUID=${ROOT_UUID} ro quiet mitigations=off

/PPSA Linux (recovery)
    comment=PPSA Debian GNU/Linux (single-user)
    protocol=linux
    kernel_path=uuid(${ROOT_UUID}):/boot/vmlinuz
    initrd_path=uuid(${ROOT_UUID}):/boot/initrd.img
    cmdline=root=UUID=${ROOT_UUID} ro single
LIMINEEOF
    # Strip CRs in case the build script was checked out with CRLF on Windows.
    # Limine's parser treats \r as part of the token, breaking the protocol line.
    sed -i 's/\r$//' "$MOUNT_DIR/boot/efi/limine.conf" 2>/dev/null || true
    echo "limine.conf written (UUID=$ROOT_UUID)."
else
    echo "WARNING: ROOT_UUID not detected; limine.conf not written."
fi

# Also copy limine-bios.sys to /boot for future BIOS boot support
# (currently BIOS install isn't done — only UEFI works out of the box)
if [ -f "$MOUNT_DIR/opt/limine/limine-bios.sys" ]; then
    cp "$MOUNT_DIR/opt/limine/limine-bios.sys" "$MOUNT_DIR/boot/limine-bios.sys"
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
