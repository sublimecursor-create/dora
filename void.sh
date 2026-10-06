#!/usr/bin/env bash
# Void Linux FDE installer (LUKS + LVM + UEFI/GPT).
set -euo pipefail

# ---------------------------------------------------------------------------
MNT="${MNT:-/mnt}"
VOID_REPO="${VOID_REPO:-https://repo-default.voidlinux.org/current}"
# ---------------------------------------------------------------------------

configure_xbps() {
  # Sync repos and install host-side tools needed by later steps
  xbps-install -Syu
  xbps-install -y gdisk cryptsetup lvm2 dosfstools e2fsprogs xtools
}

partition_disk() {
  echo
  lsblk -dpno NAME,SIZE,MODEL
  echo
  read -r -p "Target disk (e.g. /dev/sda or /dev/nvme0n1): " DISK
  read -r -p "EFI partition size (e.g. 512MiB): " efi_size
  read -r -p "Root partition size (e.g. 50GiB, or 100% for the rest of the disk): " root_size

  echo
  echo "This will wipe ${DISK}: EFI=${efi_size}, Linux=${root_size}"
  read -r -p "Type YES to continue: " ans
  [[ "$ans" == "YES" ]] || { echo "Aborted."; exit 1; }

  wipefs -a "$DISK"
  sgdisk --zap-all "$DISK"
  sgdisk --clear "$DISK"
  sgdisk -n "1:0:+${efi_size}" -t 1:ef00 -c 1:EFI "$DISK"
  if [[ "$root_size" == "100%" ]]; then
    sgdisk -n 2:0:0 -t 2:8309 -c 2:Linux "$DISK"
  else
    sgdisk -n "2:0:+${root_size}" -t 2:8309 -c 2:Linux "$DISK"
  fi
  partprobe "$DISK"
  udevadm settle

  if [[ "$DISK" =~ (nvme|mmcblk|loop|nbd) ]]; then
    EFI_PART="${DISK}p1"
    LINUX_PART="${DISK}p2"
  else
    EFI_PART="${DISK}1"
    LINUX_PART="${DISK}2"
  fi
}

encrypt_linux() {
  # NOTE: If using GRUB with encrypted /boot, LUKS2 requires '--pbkdf pbkdf2'
  # because GRUB cannot decrypt Argon2id.
  cryptsetup luksFormat \
    --type luks2 \
    --key-size 512 \
    --hash sha512 \
    --use-urandom \
    --label OS \
    --force-password \
    "$LINUX_PART"

  cryptsetup open \
    --persistent \
    --allow-discards \
    --perf-no_read_workqueue \
    --perf-no_write_workqueue \
    "$LINUX_PART" \
    system
}

setup_lvm() {
  pvcreate --dataalignment 1m /dev/mapper/system
  vgcreate voidvm /dev/mapper/system

  echo
  read -r -p "root LV size (e.g. 40G, or 100% for remaining): " lv_root_size
  read -r -p "swap LV size (e.g. 8G, or 100% for remaining): " lv_swap_size
  read -r -p "home LV size (e.g. 100G, or 100% for remaining): " lv_home_size

  create_lv() {
    local name="$1" size="$2"
    if [[ "$size" == "100%" || "$size" == "100%FREE" ]]; then
      lvcreate -y -l 100%FREE -n "$name" voidvm
    else
      lvcreate -y -L "$size" -n "$name" voidvm
    fi
  }

  create_lv root "$lv_root_size"
  create_lv swap "$lv_swap_size"
  create_lv home "$lv_home_size"
}

format_filesystems() {
  mkfs.vfat -F 32 -n BOOT "$EFI_PART"
  mkfs.ext4 -L Root /dev/voidvm/root
  mkfs.ext4 -L Home /dev/voidvm/home
  mkswap -L Swap /dev/voidvm/swap
  swapon /dev/voidvm/swap
}

mount_filesystems() {
  mount /dev/voidvm/root "$MNT"
  mkdir -p "$MNT/home" "$MNT/boot/efi"
  mount /dev/voidvm/home "$MNT/home"
  mount -o umask=0077 "$EFI_PART" "$MNT/boot/efi"
}

bootstrap() {
  # Copy xbps RSA repo keys so target xbps can verify package signatures
  mkdir -p "$MNT/var/db/xbps/keys"
  cp -a /var/db/xbps/keys/* "$MNT/var/db/xbps/keys/"

  # Install base packages, CPU microcode, and UEFI bootloader
  xbps-install -Sy -R "$VOID_REPO" -r "$MNT" base-system lvm2 cryptsetup intel-ucode systemd-boot-efistub 

  # Generate fstab using UUIDs (from xtools)
  mkdir -p "$MNT/etc"
  xgenfstab -U "$MNT" > "$MNT/etc/fstab"
}

configure_chroot() {
  # Configure glibc locales
  echo "LANG=en_US.UTF-8" > "$MNT/etc/locale.conf"
  if ! grep -q '^en_US.UTF-8 UTF-8' "$MNT/etc/default/libc-locales" 2>/dev/null; then
    echo "en_US.UTF-8 UTF-8" >> "$MNT/etc/default/libc-locales"
  fi
  xchroot "$MNT" xbps-reconfigure -f glibc-locales

  echo
  echo "Base install and locale configuration complete."
  echo "Entering chroot environment ($MNT) to finalize setup (passwd, hostname, GRUB, initramfs)..."
  xchroot "$MNT"
}

main() {
  configure_xbps
  partition_disk
  encrypt_linux
  setup_lvm
  format_filesystems
  mount_filesystems
  bootstrap
  configure_chroot
}

main "$@"
