#!/bin/bash

# Arch Linux + ZFS + ZFSBootMenu

set -euo pipefail  # Exit on error, undefined variables, and pipe failures

# --------------------------------------------------------------------------------------------------------------------------
# HELPER FUNCTIONS
# --------------------------------------------------------------------------------------------------------------------------

print_header() {
    local title="$1"
    local line="--------------------------------------------------------------------------------------------------------------------------"
    echo -e "\n\n# ${line}"
    echo -e "# ${title}"
    echo -e "# ${line}\n"
}

get_password() {
    local prompt=$1
    local password_var
    local password_recheck_var

    while true; do
        echo -n "$prompt: "; read -r -s password_var; echo
        if [ ${#password_var} -lt 8 ]; then
            echo "Password must be at least 8 characters long."
            continue
        fi
        echo -n "Re-enter password: "; read -r -s password_recheck_var; echo
        if [ "$password_var" = "$password_recheck_var" ]; then
            printf -v "$2" '%s' "$password_var"
            break
        else
            echo "Passwords do not match. Please try again."
        fi
    done
}

select_install_disk() {
    local -a disks
    local index
    local selection
    local confirm_disk

    mapfile -t disks < <(lsblk -dpno NAME,TYPE | awk '$2 == "disk" {print $1}')
    [ "${#disks[@]}" -gt 0 ]  

    echo "Available disks:"
    for index in "${!disks[@]}"; do
        printf "  [%d] %s\n" "$((index + 1))" "${disks[$index]}"
    done

    read -r -p "Select target disk number: " selection
    [[ "$selection" =~ ^[0-9]+$ ]]  
    [ "$selection" -ge 1 ] && [ "$selection" -le "${#disks[@]}" ]  

    DISK="${disks[$((selection - 1))]}"
    if [[ "$DISK" =~ (nvme|mmcblk) ]]; then
        PARTITION_1="p1"
        PARTITION_2="p2"
    else
        PARTITION_1="1"
        PARTITION_2="2"
    fi

    echo "Selected disk: $DISK"
}

cleanup() {
    local exit_code=${1:-$?}

    [ "${CLEANUP_DONE:-0}" -eq 1 ] && return
    CLEANUP_DONE=1

    rm -f /mnt/root/.arch-install-helpers.sh /mnt/root/.arch-rootpass
    umount -R /mnt 2>/dev/null  true
    zfs umount -a 2>/dev/null  true
    zpool export zroot 2>/dev/null  true

    if [ "$exit_code" -ne 0 ]; then
        echo "Cleanup completed after error."
    fi
}

echo -e "\n=== Arch Linux ZFS Installation ==="
echo -e "This script will ERASE all data on the selected disk!\n"

get_password "Enter the password for root user" ROOTPASS

echo -n "Enter the hostname: "; read -r HOSTNAME


# --------------------------------------------------------------------------------------------------------------------------
# DISK PARTITIONING
# --------------------------------------------------------------------------------------------------------------------------

print_header "Disk Detection"

select_install_disk
trap 'cleanup $?' EXIT

print_header "Partitioning $DISK"

wipefs -a -f "$DISK"  

parted "$DISK" --script mklabel gpt  
parted "$DISK" --script mkpart ESP fat32 1MiB 1GiB  
parted "$DISK" --script set 1 esp on  
parted "$DISK" --script mkpart primary 1GiB 100%  

echo "Partitions created successfully."

sleep 2  # Wait for kernel to recognize partitions

# --------------------------------------------------------------------------------------------------------------------------
# ZPOOL AND DATASET
# --------------------------------------------------------------------------------------------------------------------------

print_header "zpool and dataset creation"

zpool create \
    -o ashift=12 \
    -O acltype=posixacl -O canmount=off -O compression=lz4 \
    -O dnodesize=auto -O normalization=formD -o autotrim=on \
    -O atime=off -O xattr=sa -O mountpoint=none \
    -R /mnt zroot ${DISK}${PARTITION_2} -f  
echo "ZFS pool created successfully."

# Dataset layout
zfs create -o mountpoint=none zroot/data  
zfs create -o mountpoint=none zroot/ROOT  
zfs create -o mountpoint=/ -o canmount=noauto zroot/ROOT/default  
#zfs create -o mountpoint=/home zroot/data/home  

zpool set bootfs=zroot/ROOT/default zroot  
echo "bootfs property set successfully."

zfs mount zroot/ROOT/default  
zfs mount -a  

mkdir -p /mnt/etc/zfs  
zpool set cachefile=/etc/zfs/zpool.cache zroot  
cp /etc/zfs/zpool.cache /mnt/etc/zfs/zpool.cache  

mkfs.fat -F32 "${DISK}${PARTITION_1}"  
mkdir -p /mnt/efi  
mount "${DISK}${PARTITION_1}" /mnt/efi  

# --------------------------------------------------------------------------------------------------------------------------
# BASE SYSTEM
# --------------------------------------------------------------------------------------------------------------------------

print_header "Install base system"

pacstrap /mnt linux-lts linux-lts-headers base base-devel linux-firmware efibootmgr zram-generator sudo networkmanager amd-ucode wget  


print_header "Generate fstab file"

# --------------------------------------------------------------------------------------------------------------------------
# FSTAB
# --------------------------------------------------------------------------------------------------------------------------

# Exclude ZFS entries - ZFS handles its own mounting via zfs-mount.service
genfstab -U /mnt | grep -v zfs >> /mnt/etc/fstab  

# Get the actual UUID of the EFI partition
EFI_UUID=$(blkid -s UUID -o value "${DISK}${PARTITION_1}")

# Make EFI partition optional - only needed when updating bootloader
[ -n "$EFI_UUID" ]  
sed -i "/\/efi.*vfat/c\\UUID=${EFI_UUID}  /efi  vfat  noauto,nofail,x-systemd.device-timeout=1  0  0" /mnt/etc/fstab

echo "fstab generated successfully."

# --------------------------------------------------------------------------------------------------------------------------
# CHROOT
# --------------------------------------------------------------------------------------------------------------------------

print_header "Chroot into the system and configure"

echo "Entering chroot to configure the system..."

# Make header helper available inside chroot
declare -f print_header > /mnt/root/.arch-install-helpers.sh
ROOTPASS_FILE="/mnt/root/.arch-rootpass"
umask 077
printf 'root:%s\n' "$ROOTPASS" > "$ROOTPASS_FILE"
unset ROOTPASS

arch-chroot /mnt \
    /usr/bin/env DISK="$DISK" PARTITION_1="$PARTITION_1" HOSTNAME="$HOSTNAME" ROOTPASS_FILE="/root/.arch-rootpass" \
    /bin/bash --noprofile --norc -euo pipefail <<EOF

source /root/.arch-install-helpers.sh

error_exit() {
    echo "ERROR: $1" >&2
    exit 1
}

# Safety: ensure we don't echo each input line (bash verbose mode)
set +o verbose  true
set +o xtrace  true

echo "Chrooted successfully!"

# --------------------------------------------------------------------------------------------------------------------------
# SERVICES
# --------------------------------------------------------------------------------------------------------------------------

print_header "Manage Services"

systemctl enable NetworkManager
systemctl mask NetworkManager-wait-online.service
systemctl mask ldconfig.service
systemctl mask geoclue

echo "Services configured."

# --------------------------------------------------------------------------------------------------------------------------
# LOCALE
# --------------------------------------------------------------------------------------------------------------------------

print_header "Configure locale"

localectl set-keymap us
echo "KEYMAP=us" > /etc/vconsole.conf
echo "Locale and keymap configured."

# --------------------------------------------------------------------------------------------------------------------------
# ZFS
# --------------------------------------------------------------------------------------------------------------------------

print_header "Setup ZFS"

if ! grep -q '^\[archzfs\]' /etc/pacman.conf; then
    echo -e '
[archzfs]
Server = https://github.com/archzfs/archzfs/releases/download/experimental' >> /etc/pacman.conf
fi

# ArchZFS GPG keys (see https://wiki.archlinux.org/index.php/Unofficial_user_repositories#archzfs)
pacman-key -r DDF7DB817396A49B2A2723F7403BD972F75D9D76
pacman-key --lsign-key DDF7DB817396A49B2A2723F7403BD972F75D9D76

pacman -Syu --noconfirm --needed zfs-dkms
systemctl enable zfs.target zfs-import-cache zfs-mount zfs-import.target

if command -v zgenhostid >/dev/null 2>&1; then
    zgenhostid -f "\$(hostid)"
fi

# --------------------------------------------------------------------------------------------------------------------------
# ZFSBOOTMENU
# --------------------------------------------------------------------------------------------------------------------------

print_header "Install ZFSBootMenu"

mkdir -p /efi/EFI/zbm
wget https://get.zfsbootmenu.org/latest.EFI -O /efi/EFI/zbm/zfsbootmenu.EFI  

# Create the boot entry
efibootmgr --disk "$DISK" --part 1 --create --label "ZFSBootMenu" \
    --loader '\EFI\zbm\zfsbootmenu.EFI' \
    --unicode "spl_hostid=\$(hostid) zbm.timeout=3 zbm.prefer=zroot zbm.import_policy=hostid" \
    --verbose >/dev/null

# Set ZFS properties for boot
zfs set org.zfsbootmenu:commandline="noresume rw init_on_alloc=0 spl.spl_hostid=\$(hostid)" zroot/ROOT/default  

# --------------------------------------------------------------------------------------------------------------------------
# MKINITCPIO
# --------------------------------------------------------------------------------------------------------------------------

print_header "Configure mkinitcpio"

# Configure mkinitcpio with ZFS hooks
sed -i 's/^HOOKS=.*/HOOKS=(base udev autodetect microcode modconf kms keyboard keymap consolefont block zfs filesystems)/' /etc/mkinitcpio.conf

mkinitcpio -p linux-lts

# --------------------------------------------------------------------------------------------------------------------------
# ZRAM
# --------------------------------------------------------------------------------------------------------------------------

print_header "Configure ZRAM"

bash -c 'cat > /etc/systemd/zram-generator.conf <<EOFZRAM
[zram0]
zram-size = min(ram, 32768)
compression-algorithm = zstd
EOFZRAM'

echo "vm.swappiness = 180" >> /etc/sysctl.d/99-vm-zram-parameters.conf
echo "vm.watermark_boost_factor = 0" >> /etc/sysctl.d/99-vm-zram-parameters.conf
echo "vm.watermark_scale_factor = 125" >> /etc/sysctl.d/99-vm-zram-parameters.conf
echo "vm.page-cluster = 0" >> /etc/sysctl.d/99-vm-zram-parameters.conf

sysctl --system

# --------------------------------------------------------------------------------------------------------------------------
# MULTILIB REPO
# --------------------------------------------------------------------------------------------------------------------------

print_header "Enable Multilib repository"

sed -i '/\[multilib\]/,/Include/ s/^#//' /etc/pacman.conf
pacman -Syy

# --------------------------------------------------------------------------------------------------------------------------
# SYSTEM CONFIG
# --------------------------------------------------------------------------------------------------------------------------

print_header "System config"

echo "$HOSTNAME" > /etc/hostname

ln -sf /usr/share/zoneinfo/Europe/Rome /etc/localtime

hwclock --systohc

timedatectl set-ntp true

sed -i '/^#en_US.UTF-8/s/^#//g' /etc/locale.gen && locale-gen

echo -e "127.0.0.1   localhost\n::1         localhost\n127.0.1.1   $HOSTNAME.localdomain   $HOSTNAME" > /etc/hosts

# --------------------------------------------------------------------------------------------------------------------------
# AUDIO
# --------------------------------------------------------------------------------------------------------------------------

print_header "Install audio components"

pacman -S --needed --noconfirm wireplumber pipewire-pulse pipewire-alsa pavucontrol-qt alsa-utils

# --------------------------------------------------------------------------------------------------------------------------
# NVIDIA DRIVERS
# --------------------------------------------------------------------------------------------------------------------------

print_header "Install NVIDIA drivers"

pacman -S --needed --noconfirm nvidia-open-lts nvidia-settings nvidia-utils opencl-nvidia libxnvctrl egl-wayland

# --------------------------------------------------------------------------------------------------------------------------
# ROOT PASSWORD
# --------------------------------------------------------------------------------------------------------------------------

print_header "Set root user password"

chpasswd < "\$ROOTPASS_FILE"
shred -u "\$ROOTPASS_FILE"  rm -f "\$ROOTPASS_FILE"

echo "Root password set."

echo "Configuration completed successfully!"

# --------------------------------------------------------------------------------------------------------------------------
# INSTALLATION COMPLETED
# --------------------------------------------------------------------------------------------------------------------------

EOF

print_header "Unmount and prepare for reboot"

echo "Unmounting filesystems..."
cleanup 0
trap - EXIT

while read -r -t 0; do read -r  true; done

read -r -p "Type R/r to reboot: " REBOOT_CONFIRM
if [ "$REBOOT_CONFIRM" = "R" ]  [ "$REBOOT_CONFIRM" = "r" ]; then
    reboot
else
    echo "Reboot skipped. You can reboot manually when ready."
fi
