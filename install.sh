#!/bin/bash

# --- Arch Linux Dev Machine Optimized Installation Script ---
# This script is designed for laptop installations with LUKS2, LVM, and Hyprland.

set -e

# Hardcoded Defaults
USERNAME="serkan"
FULL_NAME="Serkan Aksoy"
USER_EMAIL="serkanaksy@pm.me"
HOSTNAME="wldn-nb"
DOMAIN="woldan.me"
TIMEZONE="Europe/Istanbul"
LOCALE="en_US.UTF-8"
BOOT_SIZE="512M"
DISK_NAME="nvme0n1"
SWAP_SIZE="24G"

# Package Categorization
CORE_PACKAGES="base linux linux-firmware lvm2 iwd power-profiles-daemon sudo zsh zsh-completions fastfetch curl wget"
WM_PACKAGES="hyprland alacritty waybar"
DEV_PACKAGES="base-devel git neovim gcc clang cmake make"

# GPU: Always NVIDIA (DKMS)
GPU_PACKAGES="nvidia-dkms nvidia-utils nvidia-settings linux-headers"

ALL_PACKAGES="$CORE_PACKAGES $WM_PACKAGES $DEV_PACKAGES $CPU_TYPE $GPU_PACKAGES"

# Colors for output
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m' # No Color

echo -e "${GREEN}--- Arch Linux Installation System ---${NC}"

# Check for UEFI
if [ ! -d "/sys/firmware/efi" ]; then
    echo -e "${RED}Error: System is not booted in UEFI mode.${NC}"
    exit 1
fi

# Check for internet
if ! ping -c 1 google.com &> /dev/null; then
    echo -e "${RED}Error: No internet connection.${NC}"
    exit 1
fi

# Disk Selection
DISK="/dev/$DISK_NAME"

if [ ! -b "$DISK" ]; then
    echo -e "${RED}Error: Disk $DISK not found.${NC}"
    exit 1
fi

echo -e "${RED}WARNING: ALL DATA ON $DISK WILL BE DESTROYED!${NC}"
read -p "Are you sure you want to proceed? (y/N): " CONFIRM
if [[ $CONFIRM != "y" ]]; then
    exit 1
fi

read -s -p "Enter Master System Password (LUKS/Root/User): " PASSWORD
echo ""

# CPU: Always Intel
CPU_TYPE="intel-ucode"

# 2. Disk Preparation
echo "Partitioning $DISK..."
sgdisk --zap-all "$DISK"
sgdisk -n 1:0:+"$BOOT_SIZE" -t 1:ef00 "$DISK"
sgdisk -n 2:0:0 -t 2:8309 "$DISK"

# Handle NVMe vs SATA naming
if [[ $DISK == *"nvme"* ]]; then
    PART_BOOT="${DISK}p1"
    PART_LUKS="${DISK}p2"
else
    PART_BOOT="${DISK}1"
    PART_LUKS="${DISK}2"
fi

# 3. Encryption & LVM
echo -n "$PASSWORD" | cryptsetup luksFormat --type luks2 "$PART_LUKS" -
echo -n "$PASSWORD" | cryptsetup open "$PART_LUKS" cryptlvm -

pvcreate /dev/mapper/cryptlvm
vgcreate vg0 /dev/mapper/cryptlvm

lvcreate -L "$SWAP_SIZE" vg0 -n swap
lvcreate -l 60%FREE vg0 -n root
lvcreate -l 100%FREE vg0 -n home

mkfs.fat -F 32 "$PART_BOOT"
mkfs.ext4 /dev/mapper/vg0-root
mkfs.ext4 /dev/mapper/vg0-home
mkswap /dev/mapper/vg0-swap

# 4. Mount
mount /dev/mapper/vg0-root /mnt
mount --mkdir -o fmask=0077,dmask=0077 "$PART_BOOT" /mnt/boot
mount --mkdir -o nodev,nosuid,noatime /dev/mapper/vg0-home /mnt/home
swapon /dev/mapper/vg0-swap

# 5. Enable Parallel Downloads, ILoveCandy & CheckSpace in Host
sed -i 's/^#ParallelDownloads = 5/ParallelDownloads = 10/' /etc/pacman.conf
sed -i '/^#Color/a ILoveCandy' /etc/pacman.conf
sed -i 's/^#CheckSpace/CheckSpace/' /etc/pacman.conf

# 6. Core Package Installation
echo "Installing base system and categorized packages..."
pacstrap -K /mnt $ALL_PACKAGES

# 7. System Configuration
genfstab -U /mnt >> /mnt/etc/fstab

# User Management and Post-Install
arch-chroot /mnt /bin/bash <<EOF
# Helper function to run commands as the user
run_as_user() {
    sudo -u "$USERNAME" "\$@"
}

# Enable Parallel Downloads, ILoveCandy & CheckSpace in Chroot
sed -i 's/^#ParallelDownloads = 5/ParallelDownloads = 10/' /etc/pacman.conf
sed -i '/^#Color/a ILoveCandy' /etc/pacman.conf
sed -i 's/^#CheckSpace/CheckSpace/' /etc/pacman.conf

# Timezone and Locale
ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime
hwclock --systohc
echo "$LOCALE UTF-8" >> /etc/locale.gen
locale-gen
echo "LANG=$LOCALE" > /etc/locale.conf

# Hostname
echo "$HOSTNAME" > /etc/hostname
cat <<EOT > /etc/hosts
127.0.0.1   localhost
::1         localhost
127.0.1.1   $HOSTNAME.$DOMAIN $HOSTNAME
EOT

# User Management
echo "root:$PASSWORD" | chpasswd
useradd -m -G wheel -s /bin/zsh -c "$FULL_NAME" "$USERNAME"
echo "$USERNAME:$PASSWORD" | chpasswd
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

# Install Oh My Zsh for the user
run_as_user sh -c "\$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended

# SSH Setup for GitHub
run_as_user mkdir -p /home/"$USERNAME"/.ssh
run_as_user ssh-keygen -t ed25519 -f /home/"$USERNAME"/.ssh/woldann_github -C "$USER_EMAIL" -N "" -q

# Git Configuration
run_as_user git config --global user.email "$USER_EMAIL"
run_as_user git config --global user.name "$FULL_NAME"
run_as_user git config --global init.defaultBranch main

run_as_user tee /home/"$USERNAME"/.ssh/config <<EOT
Host github.com
    HostName github.com
    User git
    IdentityFile ~/.ssh/woldann_github
    IdentitiesOnly yes
EOT

run_as_user chmod 700 /home/"$USERNAME"/.ssh
run_as_user chmod 600 /home/"$USERNAME"/.ssh/config /home/"$USERNAME"/.ssh/woldann_github

# Systemd Services
systemctl enable systemd-networkd systemd-resolved iwd power-profiles-daemon

# Blacklist Zram
echo "blacklist zram" > /etc/modprobe.d/zram.conf

# Configure systemd-resolved (Cloudflare DoT)
sed -i 's/^#DNS=/DNS=1.1.1.1#cloudflare-dns.com 1.0.0.1#cloudflare-dns.com/' /etc/systemd/resolved.conf
sed -i 's/^#DNSOverTLS=no/DNSOverTLS=yes/' /etc/systemd/resolved.conf

# Mkinitcpio
sed -i 's/^MODULES=.*/MODULES=(nvidia nvidia_modeset nvidia_uvm nvidia_drm)/' /etc/mkinitcpio.conf
sed -i 's/^HOOKS=.*/HOOKS=(base systemd autodetect modconf kms keyboard sd-vconsole sd-encrypt sd-lvm2 filesystems resume fsck)/' /etc/mkinitcpio.conf
mkinitcpio -P

# Bootloader
bootctl install
DISK_UUID=\$(blkid -s UUID -o value $PART_LUKS)
cat <<EOT > /boot/loader/entries/arch.conf
title   Arch Linux ($HOSTNAME)
linux   /vmlinuz-linux
initrd  /initrd-linux.img
options rd.luks.name=\$DISK_UUID=cryptlvm rd.lvm.vg=vg0 root=/dev/mapper/vg0-root resume=/dev/mapper/vg0-swap nvidia-drm.modeset=1 nvidia-drm.fbdev=1 intel.max_cstate=1 zswap.enabled=0 quiet splash rw
EOT
echo "default arch.conf" > /boot/loader/loader.conf

# DNS
ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
EOF

echo -e "${GREEN}Installation complete! Please reboot.${NC}"