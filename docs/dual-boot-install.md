# PPSA Dual-Boot Install (Spare Drive / Partition)

This guide shows how to install PPSA onto a spare drive or partition
on a Windows machine **without modifying the Windows system**.

The flow:

1. Download the **PPSA Installer** ISO from a PPSA GitHub release.
2. Write the ISO to a USB drive with Rufus (or `dd` on Linux).
3. Boot the machine from the USB via the firmware boot menu (F12 on
   most desktops, F2/F8/F10 on laptops).
4. The installer TUI appears automatically. Pick a target drive or
   partition. Confirm. The installer writes PPSA.
5. Reboot, press F12 again, and select the disk that now holds PPSA.

PPSA boots independently of Windows Boot Manager. The Windows install
is never touched.

---

## 1. Get the installer ISO

Releases live at <https://github.com/kaiser62/ppsa/releases>. The
installer assets are named:

- `ppsa-installer-vX.Y.Z.iso.zst`  (~1.2 GB, includes the bundled PPSA image)
- `ppsa-installer-vX.Y.Z.iso.zst.sha256`

The installer bundles a compact PPSA seed image for fully offline use.
No network is required at install time. The installed PPSA root partition
is expanded to the selected disk or partition during install and again on
first boot if needed.

## 2. Write the ISO to a USB

### Windows — Rufus

1. Download Rufus from <https://rufus.ie/> (portable version is fine).
2. Decompress the installer first:
   `zstd -d ppsa-installer-vX.Y.Z.iso.zst -o ppsa-installer-vX.Y.Z.iso`
3. Open Rufus.
4. **Device**: select your USB drive (8 GB or larger is enough).
5. **Boot selection**: click **SELECT** and pick the
   `ppsa-installer-vX.Y.Z.iso` file.
6. **Partition scheme**: **GPT**.
7. **Target system**: **UEFI (non CSM)**.
8. Click **Start**. If Rufus asks, choose **DD image mode**, not ISO image mode.

The write takes about 1-2 minutes on a USB 3.0 drive.

### Linux / WSL — `dd`

```bash
# Find your USB (e.g. /dev/sdb) - double-check with lsblk
lsblk -dno NAME,SIZE,MODEL
# Decompress and write
zstd -d ppsa-installer-vX.Y.Z.iso.zst -o /tmp/ppsa-installer.iso
sudo dd if=/tmp/ppsa-installer.iso of=/dev/sdX bs=4M status=progress oflag=direct
sync
```

Replace `/dev/sdX` with your USB device. **Be very careful** — picking
the wrong device erases that disk.

## 3. Boot from the USB

1. Plug the USB into the target machine.
2. Reboot.
3. At POST, press the firmware boot-menu key. Common keys:
   - Desktop: **F12** (Dell, Lenovo, HP, ASUS)
   - Laptop: **F12** or **F2**
   - Custom: check your motherboard manual
4. In the boot menu, select the USB by vendor/model.

The installer boots into a small Debian Live environment. The TUI
launches on tty1 within ~10 seconds.

## 4. Run the installer

The TUI shows a list of candidate drives and partitions. The disk
that runs the live USB is excluded automatically.

### Pick a whole disk

The TUI shows entries like `[1] /dev/sdb  64 GB  SanDisk Ultra`.

- Whole-disk install **fully erases** the disk and writes PPSA.
- You must type `YES` **three times** in a row to confirm.

### Pick a partition

The TUI shows entries like `[2] /dev/sda3  24 GB  NTFS  (J: Recovery)`.

- Partition install deletes the partition and creates two new
  partitions in its place: a 512 MB ESP (FAT32) and a root (ext4)
  that fills the rest.
- You must type `YES` once to confirm.
- The disk's other partitions are not touched. The Windows
  partition on the same disk keeps working.

### After the install

The installer reports:

```
PPSA installation complete!
Installed to:   /dev/sda3
Parent disk:    /dev/sda (WDC WDS240G2G0A, 240 GB)
Log file:       /var/log/ppsa-installer.log
```

## 5. Reboot into PPSA

1. Press Enter to return to the shell.
2. Type `reboot` and press Enter.
3. At POST, press **F12** again.
4. In the boot menu, select the disk that now holds PPSA
   (look for the model name shown in step 4).
5. PPSA boots from `/EFI/BOOT/BOOTX64.EFI` on the new ESP. You do
   not need to enable anything in UEFI Setup.

PPSA's first boot runs `install.sh` and pulls Docker images. This
takes **2-5 minutes** depending on network speed. After that:

- WebUI:     `http://<ppsa-ip>:8080`  (login `admin` / `admin`)
- SSH:       `ssh ppsa@<ppsa-ip>`     (password `ppsa`)
- WireGuard: `http://<ppsa-ip>:10086` (after configuring wg-easy)

The PPSA IP is shown on the first-boot splash screen. You can also
find it from your router's DHCP leases.

## 6. Back to Windows

PPSA and Windows are independent. To switch:

- Reboot, press F12, pick the disk you want.

To uninstall PPSA:

- Delete the PPSA partitions in Windows Disk Management
  (or with `parted` / `gdisk` from the PPSA Installer USB).
- Optionally reclaim the space into the Windows partition by
  extending the Windows volume in Disk Management.

## 7. Troubleshooting

### F12 doesn't show the USB
- Some firmwares hide USB boot in "Secure Boot" settings. Try
  disabling Secure Boot, or enable "Legacy Boot" / "CSM".
- Make sure the USB is plugged in before POST, not after.

### Installer shows no candidate drives
- Plug in your target drive after the installer boots. Press `r`
  in the menu to refresh.
- Drives smaller than 5 GB are filtered out.

### "Partition too small" error
- The partition needs at least 5 GB. PPSA itself is ~3 GB but
  Docker images add another 20+ GB over time.

### PPSA doesn't boot after install
- Verify the ESP has `/EFI/BOOT/BOOTX64.EFI`:
  - Boot the installer USB again
  - From the shell, mount the ESP: `mount /dev/sdXn /mnt`
  - `ls /mnt/EFI/BOOT/` - should contain `BOOTX64.EFI`
- If the file is missing, the install was done on a non-EFI
  system. Re-run `grub-install` from the PPSA chroot.

### Windows Boot Manager is unchanged
- This is by design. PPSA uses the firmware boot menu, not
  Windows Boot Manager. PPSA and Windows never see each other.

## Notes

- The installer uses `--removable` for GRUB, so the ESP always
  has `/EFI/BOOT/BOOTX64.EFI` — the F12 fallback path. No UEFI
  NVRAM entries are written.
- The bundled PPSA image is the same one used for the main
  PPSA VDI/IMG releases. No custom build, no surprises.
- The installer ISO is rebuilt only on `workflow_dispatch`. It
  carries the same version number as the PPSA image it bundles.
