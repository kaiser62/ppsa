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

# Send script output to BOTH the log file and the journal/console.
# Use a FIFO to avoid exec-replacing fd 1, which would starve the journal.
# ponytail: simple `tee` pipeline, one-time setup
rm -f "$LOG_FILE"
mkfifo "$LOG_FILE.pipe" 2>/dev/null || true
if [ -p "$LOG_FILE.pipe" ]; then
    tee -a "$LOG_FILE" < "$LOG_FILE.pipe" &
    exec > "$LOG_FILE.pipe" 2>&1
    trap 'rm -f "$LOG_FILE.pipe"' EXIT
else
    # Fallback: just write to log (journal may be silent in this case)
    exec > "$LOG_FILE" 2>&1
fi
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
echo "[0/6] Resizing root partition to fill USB drive..."
ROOT_DEV=$(findmnt -n -o SOURCE / 2>/dev/null || echo "")
if [ -n "$ROOT_DEV" ]; then
    # Parse disk and partition number (e.g., /dev/sda2 → /dev/sda, 2)
    DISK=$(echo "$ROOT_DEV" | sed 's/[0-9]*$//')
    PART_NUM="${ROOT_DEV#"$DISK"}"
    if [ -n "$DISK" ] && [ -n "$PART_NUM" ]; then
        # Check if resize is needed (partition < 90% of disk size)
        DISK_SECTORS=$(blockdev --getsz "$DISK" 2>/dev/null || echo 0)
        PART_END=$(parted "$DISK" unit s print 2>/dev/null | awk -v p="$PART_NUM" '$1 == p {print $3}' | tr -d 's')
        if [ -n "$PART_END" ] && [ -n "$DISK_SECTORS" ] && [ "$DISK_SECTORS" -gt 0 ] 2>/dev/null; then
            THRESHOLD=$((DISK_SECTORS * 90 / 100))
            if [ "${PART_END:-0}" -lt "$THRESHOLD" ] 2>/dev/null; then
                growpart "$DISK" "$PART_NUM" 2>/dev/null || true
                resize2fs "$ROOT_DEV" 2>/dev/null || true
                echo "  Root partition resized."
            else
                echo "  Already at full size, skipping."
            fi
        else
            echo "  Skipping resize (non-standard device or disk info unavailable)."
        fi
    else
        echo "  Skipping resize (could not parse root device: $ROOT_DEV)."
    fi
else
    echo "  Skipping resize (no root device found)."
fi

# --- Step 0b: Register UEFI boot entry (VirtualBox workaround) ---
# VirtualBox's auto-created Boot0001 does not load \EFI\BOOT\BOOTx64.EFI from ESP,
# so we register a proper NVRAM entry pointing to our Shim on the ESP.
if [ -d /sys/firmware/efi/efivars ] && command -v efibootmgr &>/dev/null; then
    # Derive the boot disk + ESP partition from the actual root device
    # (works for /dev/sda2, /dev/vda2, /dev/nvme0n1p2)
    ROOT_DEV=$(findmnt -n -o SOURCE / 2>/dev/null || true)
    if [ -n "$ROOT_DEV" ]; then
        BOOT_DISK=$(lsblk -ndo PKNAME "$ROOT_DEV" 2>/dev/null || true)
        ESP_PART=$(cat "/sys/class/block/$(basename "$ROOT_DEV")/partition" 2>/dev/null || true)
        if [ -n "$BOOT_DISK" ] && [ -n "$ESP_PART" ]; then
            BOOT_DISK="/dev/$BOOT_DISK"
            # Remove any stale PPSA entry, then create a fresh one
            efibootmgr --bootnum 1>/dev/null 2>&1 | grep -i ppsa | \
                awk '{print $1}' | sed 's/Boot//' | sed 's/\*//' | while read -r n; do
                    [ -n "$n" ] && efibootmgr --bootnum "$n" --delete-bootnum >/dev/null 2>&1 || true
                done
            efibootmgr --create \
                --disk "$BOOT_DISK" --part "$ESP_PART" \
                --loader '\EFI\PPSA\shimx64.efi' --label 'PPSA' \
                >/dev/null 2>&1 && \
                echo "  Registered UEFI boot entry: PPSA -> $BOOT_DISK part $ESP_PART" || \
                echo "  efibootmgr create failed (non-fatal; UEFI may still boot via ESP fallback)."
        else
            echo "  Skipping UEFI registration (could not derive boot disk/ESP from $ROOT_DEV)."
        fi
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
