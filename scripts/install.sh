#!/usr/bin/env bash
# =============================================================================
# PPSA - First Boot Setup
# =============================================================================
# Runs automatically on first boot via ppsa-install systemd service.
# Deploys the Docker stack and configures the system.
#
# After this runs, the web UI is available at http://<ip>:8080
# =============================================================================

set -euo pipefail

PPSA_DIR="/opt/ppsa"
DATA_DIR="$PPSA_DIR/data"
LOG_FILE="/var/log/ppsa-install.log"
FLAG_FILE="$PPSA_DIR/.installed"

# Send script output to the log file. The systemd journal sees the script's
# exit status separately; capturing stdout in a file is the only way to
# inspect what happened on first boot. Keep it simple: no FIFO, no tee race.
# ponytail: direct redirect — robust, no background processes to leak
rm -f "$LOG_FILE"
exec > "$LOG_FILE" 2>&1
chmod 644 "$LOG_FILE" 2>/dev/null || true

# Only run once
if [ -f "$FLAG_FILE" ] && [ "${1:-}" != "--force" ]; then
    echo "PPSA already installed. Run with --force to reinstall."
    exit 0
fi

echo "=== PPSA First Boot Setup ==="
echo "Date: $(date)"
echo "Repo: $PPSA_DIR"

# --- Step 0: Auto-resize root partition to fill USB drive ---
# Runs in a subshell with set -e and pipefail DISABLED. parted/growpart can
# block indefinitely on VDI/fixed virtual disks. The whole step is bounded
# by an outer 'timeout 30' so it cannot stall the rest of install.sh.
echo "[0/6] Resizing root partition to fill USB drive..."
RESIZE_START=$(date +%s)
# Hard outer bound: if anything below hangs beyond 35s, kill it.
# The subshell disables set -e and pipefail so any single failure is non-fatal.
timeout 35 bash <<'RESIZE_EOF' 2>/dev/null
set +e
set +o pipefail

ROOT_DEV=$(findmnt -n -o SOURCE / 2>/dev/null)
if [ -z "$ROOT_DEV" ]; then
    echo "  Skipping (no root device)."
    exit 0
fi

# Detect small/fixed disks (< 4GB) → no point trying to grow, VBox/VDI.
PARENT_DISK="${ROOT_DEV%[0-9]*}"
DISK_SECTORS=$(timeout 5 blockdev --getsz "$PARENT_DISK" 2>/dev/null || echo 0)
if [ "${DISK_SECTORS:-0}" -lt 8388608 ] 2>/dev/null; then  # 4 GB
    echo "  Skipping (disk < 4GB or sector query failed; resize not needed)."
    exit 0
fi

DISK="$PARENT_DISK"
PART_NUM="${ROOT_DEV#"$DISK"}"
if [ -z "$DISK" ] || [ -z "$PART_NUM" ]; then
    echo "  Skipping (parse fail: $ROOT_DEV)."
    exit 0
fi

PART_END=$( { timeout 5 parted "$DISK" unit s print 2>/dev/null || true; } | \
            awk -v p="$PART_NUM" '$1 == p {print $3}' | tr -d 's')
if [ -z "$PART_END" ]; then
    echo "  Skipping (parted could not read partition table)."
    exit 0
fi

THRESHOLD=$((DISK_SECTORS * 90 / 100))
if [ "${PART_END:-0}" -lt "$THRESHOLD" ] 2>/dev/null; then
    timeout 10 growpart "$DISK" "$PART_NUM" 2>/dev/null
    timeout 30 resize2fs "$ROOT_DEV" 2>/dev/null
    echo "  Root partition resized."
else
    echo "  Already at full size, skipping."
fi
RESIZE_EOF
RESIZE_RC=$?
ELAPSED=$(( $(date +%s) - RESIZE_START ))
if [ "$RESIZE_RC" -eq 124 ]; then
    echo "  (resize step killed at 35s outer timeout)"
else
    echo "  (resize step took ${ELAPSED}s)"
fi

# --- Step 0b: Register UEFI boot entry (VirtualBox workaround) ---
# VirtualBox's auto-created Boot0001 does not load \EFI\BOOT\BOOTx64.EFI from ESP,
# so we register a proper NVRAM entry pointing to our Shim on the ESP.
if [ -d /sys/firmware/efi/efivars ] && command -v efibootmgr &>/dev/null; then
    # IMPORTANT: derive BOOT_DISK and ESP_PART from the ESP (/boot/efi),
    # NOT from the root device. The ESP is partition 1, root is partition 2.
    # Using root's partition number for ESP would point efibootmgr at the wrong
    # partition and the NVRAM entry would be invalid.
    ESP_DEV=$(findmnt -n -o SOURCE /boot/efi 2>/dev/null || true)
    if [ -z "$ESP_DEV" ]; then
        # Fallback: walk partitions to find the one flagged as ESP
        ROOT_DEV=$(findmnt -n -o SOURCE / 2>/dev/null || true)
        BOOT_DISK=$(lsblk -ndo PKNAME "$ROOT_DEV" 2>/dev/null || true)
        if [ -n "$BOOT_DISK" ]; then
            BOOT_DISK="/dev/$BOOT_DISK"
            for n in $(seq 1 8); do
                if sfdisk -l "$BOOT_DISK" 2>/dev/null | grep -q "${BOOT_DISK}${n}.*EFI"; then
                    ESP_DEV="${BOOT_DISK}${n}"
                    break
                fi
            done
        fi
    fi
    if [ -n "$ESP_DEV" ]; then
        BOOT_DISK="/dev/$(lsblk -ndo PKNAME "$ESP_DEV" 2>/dev/null || true)"
        ESP_PART=$(cat "/sys/class/block/$(basename "$ESP_DEV")/partition" 2>/dev/null || true)
        if [ -n "$BOOT_DISK" ] && [ -n "$ESP_PART" ]; then
            # Remove any stale PPSA entry, then create a fresh one
            efibootmgr 2>/dev/null | grep -i ppsa | \
                awk '{print $1}' | sed 's/Boot//;s/\*//' | while read -r n; do
                    [ -n "$n" ] && efibootmgr --bootnum "$n" --delete-bootnum >/dev/null 2>&1 || true
                done
            efibootmgr --create \
                --disk "$BOOT_DISK" --part "$ESP_PART" \
                --loader '\EFI\PPSA\shimx64.efi' --label 'PPSA' \
                >/dev/null 2>&1 && \
                echo "  Registered UEFI boot entry: PPSA -> $BOOT_DISK part $ESP_PART" || \
                echo "  efibootmgr create failed (non-fatal; UEFI may still boot via ESP fallback)."
        else
            echo "  Skipping UEFI registration (could not derive boot disk/ESP from $ESP_DEV)."
        fi
    else
        echo "  Skipping UEFI registration (no ESP found)."
    fi
else
    echo "  Skipping UEFI registration (no efivars or no efibootmgr)."
fi

# --- Step 1: Ensure Docker is running ---
echo "[1/6] Starting Docker..."
systemctl start docker || true

# --- Step 2: Set up environment ---
echo "[2/6] Configuring environment..."
cd "$PPSA_DIR"
if [ ! -f .env ]; then
    if [ -f .env.example ]; then
        cp .env.example .env
        echo "Created default .env from .env.example"
    fi
fi

# --- Step 3: Deploy Docker stack ---
echo "[3/6] Deploying Docker stack..."
docker compose -f compose/docker-compose.yml pull
docker compose -f compose/docker-compose.yml up -d --build || {
    echo "WARNING: Docker stack failed to start fully."
    echo "Check logs: docker compose -f $PPSA_DIR/compose/docker-compose.yml logs"
}

# --- Step 4: Firewall ---
echo "[4/6] Configuring firewall..."
ufw --force enable 2>/dev/null || true
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp     # SSH
ufw allow 8211/udp   # Palworld game
ufw allow 8080/tcp   # Web UI
ufw allow 10086/tcp  # WireGuard Dashboard
ufw allow 51820/udp  # WireGuard tunnel
ufw allow 27015/udp  # Steam query
ufw allow 8212/tcp   # Palworld REST API

# --- Step 5: Mark complete ---
echo "[5/6] Marking installation complete..."
date > "$FLAG_FILE"

# Get IP for summary
IP=$(ip -4 addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v '127.0.0.1' | head -1)

echo ""
echo "=== PPSA Setup Complete ==="
echo ""
echo "  Web UI:       http://$IP:8080"
echo "  WireGuard UI: http://$IP:10086"
echo "  SSH:          ssh ppsa@$IP  (password: ppsa)"
echo ""
echo "  Open the Web UI to complete first-boot configuration."
echo "  Log in with: admin / admin"
echo ""
