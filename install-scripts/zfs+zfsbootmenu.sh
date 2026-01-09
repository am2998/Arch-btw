#!/bin/bash

# Arch Linux + ZFS + ZFSBootMenu + KDE Plasma Installation Script
# Optimized and hardened version

set -euo pipefail  # Exit on error, undefined variables, and pipe failures

# --------------------------------------------------------------------------------------------------------------------------
# Helper Functions
# --------------------------------------------------------------------------------------------------------------------------

error_exit() {
    echo "ERROR: $1" >&2
    exit 1
}

validate_username() {
    local username=$1
    if [[ ! "$username" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
        error_exit "Invalid username. Use only lowercase letters, numbers, underscore and hyphen."
    fi
    if [ ${#username} -gt 32 ]; then
        error_exit "Username too long (max 32 characters)."
    fi
}

validate_hostname() {
    local hostname=$1
    if [[ ! "$hostname" =~ ^[a-z0-9-]+$ ]]; then
        error_exit "Invalid hostname. Use only lowercase letters, numbers and hyphen."
    fi
    if [ ${#hostname} -gt 63 ]; then
        error_exit "Hostname too long (max 63 characters)."
    fi
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
            eval "$2='$password_var'"
            break
        else
            echo "Passwords do not match. Please try again."
        fi
    done
}

echo -e "\n=== Arch Linux ZFS Installation ==="
echo -e "This script will ERASE all data on the selected disk!\n"

echo -n "Enter the username: "; read -r USER
validate_username "$USER"

get_password "Enter the password for user $USER" USERPASS
get_password "Enter the password for user root" ROOTPASS

echo -n "Enter the hostname: "; read -r HOSTNAME
validate_hostname "$HOSTNAME"

echo -e "\n\n# --------------------------------------------------------------------------------------------------------------------------"
echo -e "# Disk Detection"
echo -e "# --------------------------------------------------------------------------------------------------------------------------\n"

if lsblk | grep nvme &>/dev/null; then
    DISK="/dev/nvme0n1"
    PARTITION_1="p1"
    PARTITION_2="p2"
    echo "NVMe disk detected: $DISK"
elif lsblk | grep sda &>/dev/null; then
    DISK="/dev/sda"
    PARTITION_1="1"
    PARTITION_2="2"
    echo "SATA disk detected: $DISK"
else 
    error_exit "No NVMe or SATA drive found."
fi

echo -e "\nDisk information:"
lsblk $DISK

echo -e "\n⚠️  WARNING: All data on $DISK will be DESTROYED!"
echo -n "Type 'YES' to continue: "; read -r CONFIRM
if [ "$CONFIRM" != "YES" ]; then
    echo "Installation cancelled."
    exit 0
fi

echo -e "\n\n# --------------------------------------------------------------------------------------------------------------------------"
echo -e "# Partitioning $DISK"
echo -e "# --------------------------------------------------------------------------------------------------------------------------\n"

wipefs -a -f $DISK || error_exit "Failed to wipe disk"

parted $DISK --script mklabel gpt || error_exit "Failed to create GPT table"
parted $DISK --script mkpart ESP fat32 1MiB 1GiB || error_exit "Failed to create EFI partition"
parted $DISK --script set 1 esp on || error_exit "Failed to set ESP flag"
parted $DISK --script mkpart primary 1GiB 100% || error_exit "Failed to create root partition"

sleep 2  # Wait for kernel to recognize partitions

echo -e "\n\n# --------------------------------------------------------------------------------------------------------------------------"
echo -e "# Format and mount partitions"
echo -e "# --------------------------------------------------------------------------------------------------------------------------\n"

zpool create \
    -o ashift=12 \
    -O acltype=posixacl -O canmount=off -O compression=lz4 \
    -O dnodesize=auto -O normalization=formD -o autotrim=on \
    -O atime=off -O xattr=sa -O mountpoint=none \
    -R /mnt zroot ${DISK}${PARTITION_2} -f
echo "ZFS pool created successfully."

zfs create -o canmount=noauto -o mountpoint=/ zroot/rootfs
echo "ZFS dataset created successfully."

zpool set bootfs=zroot/rootfs zroot
echo "bootfs property set successfully."

zfs mount zroot/rootfs

mkdir -p  /mnt/etc/zfs
zpool set cachefile=/etc/zfs/zpool.cache zroot
cp /etc/zfs/zpool.cache /mnt/etc/zfs/zpool.cache

mkfs.fat -F32 ${DISK}${PARTITION_1}   
mkdir -p /mnt/efi && mount ${DISK}${PARTITION_1} /mnt/efi


echo -e "\n\n# --------------------------------------------------------------------------------------------------------------------------"
echo -e "# Install base system"
echo -e "# --------------------------------------------------------------------------------------------------------------------------\n"

pacstrap /mnt linux-lts linux-lts-headers base base-devel linux-firmware efibootmgr zram-generator reflector sudo networkmanager amd-ucode wget


echo -e "\n\n# --------------------------------------------------------------------------------------------------------------------------"
echo -e "# Generate fstab file"
echo -e "# --------------------------------------------------------------------------------------------------------------------------\n"

genfstab -U /mnt >> /mnt/etc/fstab


echo -e "\n\n# --------------------------------------------------------------------------------------------------------------------------"
echo -e "# Chroot into the system and configure"
echo -e "# --------------------------------------------------------------------------------------------------------------------------\n"

arch-chroot /mnt \
    /usr/bin/env DISK="$DISK" USER="$USER" USERPASS="$USERPASS" ROOTPASS="$ROOTPASS" HOSTNAME="$HOSTNAME" \
    /bin/bash --noprofile --norc -euo pipefail <<'EOF'

error_exit() {
    echo "ERROR: $1" >&2
    exit 1
}

# Safety: ensure we don't echo each input line (bash verbose mode)
set +o verbose || true
set +o xtrace || true


# --------------------------------------------------------------------------------------------------------------------------
# Configure mirrors and Enable Network Manager service
# --------------------------------------------------------------------------------------------------------------------------

reflector --country "Italy" --latest 10 --sort rate --protocol https --age 7 --save /etc/pacman.d/mirrorlist
systemctl enable NetworkManager
systemctl mask NetworkManager-wait-online.service


echo -e "\n\n# --------------------------------------------------------------------------------------------------------------------------"
echo -e "# Setup ZFS"
echo -e "# --------------------------------------------------------------------------------------------------------------------------\n"

echo -e '
[archzfs]
Server = https://github.com/archzfs/archzfs/releases/download/experimental' >> /etc/pacman.conf

# ArchZFS GPG keys (see https://wiki.archlinux.org/index.php/Unofficial_user_repositories#archzfs)
pacman-key -r DDF7DB817396A49B2A2723F7403BD972F75D9D76
pacman-key --lsign-key DDF7DB817396A49B2A2723F7403BD972F75D9D76

pacman -Sy --noconfirm zfs-dkms
systemctl enable zfs.target zfs-import-cache zfs-mount zfs-import.target


# --------------------------------------------------------------------------------------------------------------------------
# Install ZFSBootMenu
# --------------------------------------------------------------------------------------------------------------------------

mkdir -p /efi/EFI/zbm
wget https://get.zfsbootmenu.org/latest.EFI -O /efi/EFI/zbm/zfsbootmenu.EFI
efibootmgr --disk $DISK --part 1 --create --label "ZFSBootMenu" --loader '\EFI\zbm\zfsbootmenu.EFI' --unicode "spl_hostid=$(hostid) zbm.timeout=3 zbm.prefer=zroot zbm.import_policy=hostid" --verbose
zfs set org.zfsbootmenu:commandline="noresume init_on_alloc=0 rw spl.spl_hostid=$(hostid)" zroot/rootfs


# --------------------------------------------------------------------------------------------------------------------------
# Configure mkinitcpio
# --------------------------------------------------------------------------------------------------------------------------

sed -i 's/\(filesystems\) \(fsck\)/\1 zfs \2/' /etc/mkinitcpio.conf

mkinitcpio -p linux-lts


# --------------------------------------------------------------------------------------------------------------------------
# Configure ZRAM
# --------------------------------------------------------------------------------------------------------------------------

bash -c 'cat > /etc/systemd/zram-generator.conf <<EOF
[zram0]
zram-size = min(ram, 32768)
compression-algorithm = zstd
EOF'

echo "vm.swappiness = 180" >> /etc/sysctl.d/99-vm-zram-parameters.conf
echo "vm.watermark_boost_factor = 0" >> /etc/sysctl.d/99-vm-zram-parameters.conf
echo "vm.watermark_scale_factor = 125" >> /etc/sysctl.d/99-vm-zram-parameters.conf
echo "vm.page-cluster = 0" >> /etc/sysctl.d/99-vm-zram-parameters.conf

sysctl --system


# --------------------------------------------------------------------------------------------------------------------------
# Enable Multilib repository
# --------------------------------------------------------------------------------------------------------------------------

sed -i '/\[multilib\]/,/Include/ s/^#//' /etc/pacman.conf
pacman -Syy


# --------------------------------------------------------------------------------------------------------------------------
# System config
# --------------------------------------------------------------------------------------------------------------------------

echo "$HOSTNAME" > /etc/hostname

localectl set-keymap us && echo "KEYMAP=us" > /etc/vconsole.conf

ln -sf /usr/share/zoneinfo/Europe/Rome /etc/localtime

hwclock --systohc

timedatectl set-ntp true

sed -i '/^#en_US.UTF-8/s/^#//g' /etc/locale.gen && locale-gen

echo -e "127.0.0.1   localhost\n::1         localhost\n127.0.1.1   $HOSTNAME.localdomain   $HOSTNAME" > /etc/hosts


# --------------------------------------------------------------------------------------------------------------------------
# Install utilities and Enable services
# --------------------------------------------------------------------------------------------------------------------------

pacman -S --noconfirm net-tools flatpak git man nano


# --------------------------------------------------------------------------------------------------------------------------
# Install KDE desktop environment
# --------------------------------------------------------------------------------------------------------------------------

pacman -S --noconfirm plasma-meta kde-applications-meta sddm
systemctl enable sddm.service

# Configure SDDM with Breeze theme and Wayland
mkdir -p /etc/sddm.conf.d || error_exit "Failed to create sddm config directory"


bash -c 'cat > /etc/sddm.conf.d/theme.conf <<EOF
[Theme]
Current=breeze
CursorTheme=breeze_cursors

[General]
Numlock=on
DisplayServer=wayland
GreeterEnvironment=QT_WAYLAND_SHELL_INTEGRATION=layer-shell

[Wayland]
SessionDir=/usr/share/wayland-sessions
CompositorCommand=kwin_wayland --drm --no-lockscreen --no-global-shortcuts --locale1
EOF'


# --------------------------------------------------------------------------------------------------------------------------
# Install audio components
# --------------------------------------------------------------------------------------------------------------------------

pacman -S --noconfirm wireplumber pipewire-pulse pipewire-alsa pavucontrol-qt


# --------------------------------------------------------------------------------------------------------------------------
# Install NVIDIA drivers
# --------------------------------------------------------------------------------------------------------------------------

pacman -S --noconfirm nvidia-open-lts nvidia-settings nvidia-utils opencl-nvidia libxnvctrl egl-wayland


# --------------------------------------------------------------------------------------------------------------------------
# Create user and set passwords
# --------------------------------------------------------------------------------------------------------------------------

useradd -m -G wheel,audio,video,storage -s /bin/bash "$USER"

echo "$USER:$USERPASS" | chpasswd
echo "root:$ROOTPASS" | chpasswd


# --------------------------------------------------------------------------------------------------------------------------
# Configure sudoers file
# --------------------------------------------------------------------------------------------------------------------------

# Configure sudo using visudo-safe method
echo "%wheel ALL=(ALL:ALL) ALL" > /etc/sudoers.d/wheel
chmod 0440 /etc/sudoers.d/wheel

echo "Configuration completed successfully!"


EOF


# --------------------------------------------------------------------------------------------------------------------------
# Umount and reboot
# --------------------------------------------------------------------------------------------------------------------------

umount -R /mnt
zfs umount -a
zpool export -a
reboot