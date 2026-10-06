#!/usr/bin/env bash
# Fedora the Arch way installer. Functions are added per task, then arranged later.
set -euo pipefail

configure_dnf() {
  local conf=/etc/dnf/dnf.conf
  mkdir -p /etc/dnf
  if [[ ! -f "$conf" ]] || ! grep -q '^\[main\]' "$conf"; then
    printf '%s\n' '[main]' > "$conf"
  fi
  set_dnf_opt() {
    local key="$1" val="$2"
    if grep -q "^${key}=" "$conf"; then
      sed -i "s/^${key}=.*/${key}=${val}/" "$conf"
    else
      sed -i "/^\[main\]/a ${key}=${val}" "$conf"
    fi
  }
  set_dnf_opt max_parallel_downloads 10
  set_dnf_opt fastestmirror True
  dnf install -y arch-install-scripts gdisk
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
    sgdisk -n 2:0:0 -t 2:8304 -c 2:Linux "$DISK"
  else
    sgdisk -n "2:0:+${root_size}" -t 2:8304 -c 2:Linux "$DISK"
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
  command -v cryptsetup >/dev/null || dnf install -y cryptsetup
  sgdisk -t 2:8309 "$DISK"

  local sector_size
  sector_size=$(blockdev --getpbsz "$LINUX_PART")
  if (( sector_size < 4096 )); then
    sector_size=4096
  fi

  cryptsetup luksFormat \
    --type luks2 \
    --cipher aes-xts-plain64 \
    --key-size 512 \
    --hash sha512 \
    --pbkdf argon2id \
    --iter-time 5000 \
    --use-urandom \
    --sector-size "$sector_size" \
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
  command -v pvcreate >/dev/null || dnf install -y lvm2
  pvcreate --dataalignment 1m /dev/mapper/system
  vgcreate fedora /dev/mapper/system

  echo
  read -r -p "root LV size (e.g. 40G, or 100% for remaining): " lv_root_size
  read -r -p "swap LV size (e.g. 8G, or 100% for remaining): " lv_swap_size
  read -r -p "home LV size (e.g. 100G, or 100% for remaining): " lv_home_size

  create_lv() {
    local name="$1" size="$2"
    if [[ "$size" == "100%" || "$size" == "100%FREE" ]]; then
      lvcreate -y -l 100%FREE -n "$name" fedora
    else
      lvcreate -y -L "$size" -n "$name" fedora
    fi
  }

  create_lv root "$lv_root_size"
  create_lv swap "$lv_swap_size"
  create_lv home "$lv_home_size"
}

format_filesystems() {
  command -v mkfs.vfat >/dev/null || dnf install -y dosfstools e2fsprogs
  mkfs.vfat -F 32 -n BOOT "$EFI_PART"
  mkfs.ext4 -L Root /dev/fedora/root
  mkfs.ext4 -L Home /dev/fedora/home
  mkswap -L Swap /dev/fedora/swap
}

mount_filesystems() {
  MNT=/mnt
  mount /dev/fedora/root "$MNT"
  mkdir -p "$MNT/home" "$MNT/boot/efi"
  mount /dev/fedora/home "$MNT/home"
  mount "$EFI_PART" "$MNT/boot/efi"
  swapon /dev/fedora/swap
}

mount_api_filesystems() {
  MNT="${MNT:-/mnt}"
  mkdir -p "$MNT"/{dev,proc,sys,run}
  mount --rbind /dev "$MNT/dev"
  mount --make-rslave "$MNT/dev"
  mount --rbind /proc "$MNT/proc"
  mount --make-rslave "$MNT/proc"
  mount --rbind /sys "$MNT/sys"
  mount --make-rslave "$MNT/sys"
  mount --rbind /run "$MNT/run"
  mount --make-rslave "$MNT/run"
}

bootstrap() {
  MNT="${MNT:-/mnt}"
  dnf --installroot="$MNT" \
    --use-host-config \
    --releasever=44 \
    --setopt=install_weak_deps=False \
    -y \
    install \
      audit \
      bash \
      coreutils \
      curl \
      dnf5 \
      e2fsprogs \
      filesystem \
      glibc \
      hostname \
      iproute \
      iputils \
      kbd \
      less \
      man-db \
      ncurses \
      openssh-clients \
      parted \
      policycoreutils \
      procps-ng \
      rootfiles \
      rpm \
      selinux-policy-targeted \
      setup \
      shadow-utils \
      sssd-common \
      sssd-kcm \
      sudo \
      systemd \
      util-linux \
      dnf5-plugins \
      firewalld \
      fwupd \
      NetworkManager \
      prefixdevname systemd-pam dracut lvm2 cryptsetup systemd-boot zstd systemd-ukify neovim fzf zsh zoxide
}

configure_chroot() {
  genfstab -U /mnt > /mnt/etc/fstab
  arch-chroot -S /mnt
}
main() {
  configure_dnf
  partition_disk
  encrypt_linux
  setup_lvm
  format_filesystems
  mount_filesystems
  mount_api_filesystems
  bootstrap
}

main "$@"
