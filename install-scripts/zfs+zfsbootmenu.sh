#!/bin/bash

# Arch Linux + ZFS + ZFSBootMenu + KDE Plasma Installation Script
# Optimized and hardened version

set -euo pipefail  # Exit on error, undefined variables, and pipe failures

# --------------------------------------------------------------------------------------------------------------------------
# Helper Functions
# --------------------------------------------------------------------------------------------------------------------------

print_header() {
    local title="$1"
    local line="--------------------------------------------------------------------------------------------------------------------------"
    echo -e "\n\n# ${line}"
    echo -e "# ${title}"
    echo -e "# ${line}\n"
}

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

print_header "Disk Detection"

if lsblk | grep nvme &>/dev/null; then
    DISK="/dev/nvme0n1"
    PARTITION_1="p1"
    PARTITION_2="p2"
    echo "NVMe disk detected: $DISK"
else 
    error_exit "No NVMe drive found."
fi

echo -e "\nDisk information:"
lsblk $DISK

print_header "Verify UEFI boot mode (required for efibootmgr / EFI boot entries)"

if [ ! -d /sys/firmware/efi/efivars ]; then
    error_exit "System is not booted in UEFI mode. Reboot the installer in UEFI mode (not Legacy/CSM) and rerun this script."
fi

echo -e "\n⚠️  WARNING: All data on $DISK will be DESTROYED!"
echo -n "Type 'YES' to continue: "; read -r CONFIRM
if [ "$CONFIRM" != "YES" ]; then
    echo "Installation cancelled."
    exit 0
fi

print_header "Partitioning $DISK"

wipefs -a -f $DISK || error_exit "Failed to wipe disk"

parted $DISK --script mklabel gpt || error_exit "Failed to create GPT table"
parted $DISK --script mkpart ESP fat32 1MiB 1GiB || error_exit "Failed to create EFI partition"
parted $DISK --script set 1 esp on || error_exit "Failed to set ESP flag"
parted $DISK --script mkpart primary 1GiB 100% || error_exit "Failed to create root partition"

sleep 2  # Wait for kernel to recognize partitions

print_header "Format and mount partitions"

zpool create \
    -o ashift=12 \
    -O acltype=posixacl -O canmount=off -O compression=lz4 \
    -O dnodesize=auto -O normalization=formD -o autotrim=on \
    -O atime=off -O xattr=sa -O mountpoint=none \
    -R /mnt zroot ${DISK}${PARTITION_2} -f || error_exit "Failed to create ZFS pool"
echo "ZFS pool created successfully."

# Dataset layout
# - zroot/ROOT is a container
# - zroot/ROOT/default is the boot environment mounted at /
# - separate datasets for /home and /var improve manageability and snapshots
zfs create -o canmount=off -o mountpoint=none zroot/ROOT || error_exit "Failed to create zroot/ROOT container"
zfs create -o canmount=noauto -o mountpoint=/ zroot/ROOT/default || error_exit "Failed to create zroot/ROOT/default"
zfs create -o mountpoint=/home zroot/home || error_exit "Failed to create /home dataset"
zfs create -o canmount=off -o mountpoint=/var zroot/var || error_exit "Failed to create /var dataset"

zpool set bootfs=zroot/ROOT/default zroot || error_exit "Failed to set bootfs property"
echo "bootfs property set successfully."

zfs mount zroot/ROOT/default || error_exit "Failed to mount root dataset"
zfs mount -a || error_exit "Failed to mount ZFS datasets"

mkdir -p /mnt/etc/zfs || error_exit "Failed to create /mnt/etc/zfs"
zpool set cachefile=/etc/zfs/zpool.cache zroot || error_exit "Failed to set ZFS cachefile"
cp /etc/zfs/zpool.cache /mnt/etc/zfs/zpool.cache || error_exit "Failed to copy zpool.cache"

mkfs.fat -F32 ${DISK}${PARTITION_1} || error_exit "Failed to format EFI partition"
mkdir -p /mnt/efi || error_exit "Failed to create /mnt/efi"
mount ${DISK}${PARTITION_1} /mnt/efi || error_exit "Failed to mount EFI partition"


print_header "Install base system"

pacstrap /mnt linux-lts linux-lts-headers base base-devel linux-firmware efibootmgr zram-generator reflector sudo networkmanager amd-ucode wget || error_exit "Failed to install base system (pacstrap)"


print_header "Generate fstab file"

genfstab -U /mnt >> /mnt/etc/fstab || error_exit "Failed to generate fstab"
echo "fstab generated successfully."

print_header "Chroot into the system and configure"

echo "Entering chroot to configure the system..."

# Make header helper available inside chroot
declare -f print_header > /mnt/root/.arch-install-helpers.sh

arch-chroot /mnt \
    /usr/bin/env DISK="$DISK" PARTITION_1="$PARTITION_1" USER="$USER" USERPASS="$USERPASS" ROOTPASS="$ROOTPASS" HOSTNAME="$HOSTNAME" \
    /bin/bash --noprofile --norc -euo pipefail <<'EOF'

source /root/.arch-install-helpers.sh

error_exit() {
    echo "ERROR: $1" >&2
    exit 1
}

# Safety: ensure we don't echo each input line (bash verbose mode)
set +o verbose || true
set +o xtrace || true

echo "Inside chroot!"

print_header "Configure mirrors and Enable Network Manager service"

reflector --country "Italy" --latest 10 --sort rate --protocol https --age 7 --save /etc/pacman.d/mirrorlist
systemctl enable NetworkManager
systemctl mask NetworkManager-wait-online.service


print_header "Configure locale"

localectl set-keymap us
echo "KEYMAP=us" > /etc/vconsole.conf
echo "Locale and keymap configured."


print_header "Setup ZFS"

echo -e '
[archzfs]
Server = https://github.com/archzfs/archzfs/releases/download/experimental' >> /etc/pacman.conf

# ArchZFS GPG keys (see https://wiki.archlinux.org/index.php/Unofficial_user_repositories#archzfs)
pacman-key -r DDF7DB817396A49B2A2723F7403BD972F75D9D76
pacman-key --lsign-key DDF7DB817396A49B2A2723F7403BD972F75D9D76

pacman -Sy --noconfirm zfs-dkms
systemctl enable zfs.target zfs-import-cache zfs-mount zfs-import.target


print_header "Install ZFSBootMenu"

mkdir -p /efi/EFI/zbm
wget https://get.zfsbootmenu.org/latest.EFI -O /efi/EFI/zbm/zfsbootmenu.EFI || error_exit "Failed to download ZFSBootMenu"

# Remove any existing ZFSBootMenu entries to avoid duplicates
for bootnum in $(efibootmgr | awk -F'[* ]+' '/ZFSBootMenu/ {sub(/^Boot/, "", $1); print $1}'); do
    efibootmgr -b "$bootnum" -B
done

# Create the boot entry
efibootmgr --disk "$DISK" --part 1 --create --label "ZFSBootMenu" \
    --loader '\EFI\zbm\zfsbootmenu.EFI' \
    --unicode "spl_hostid=$(hostid) zbm.timeout=3 zbm.prefer=zroot zbm.import_policy=hostid" \
    --verbose >/dev/null

# Determine the created entry by label (safe because we removed duplicates above).
BOOT_ENTRY=$(efibootmgr | awk -F'[* ]+' '/ZFSBootMenu/ {sub(/^Boot/, "", $1); print $1; exit}')

if [ -z "$BOOT_ENTRY" ]; then
    error_exit "Failed to create boot entry"
fi

echo "Boot entry created: Boot$BOOT_ENTRY"

# Set ZFSBootMenu as the first boot option
OTHER_BOOT_ENTRIES=$(efibootmgr | awk -v boot="$BOOT_ENTRY" '/^Boot[0-9A-F]{4}/ {id=substr($1,5,4); if (id != boot) ids=(ids==""?id:ids","id)} END{print ids}')
efibootmgr --bootorder "$BOOT_ENTRY${OTHER_BOOT_ENTRIES:+,$OTHER_BOOT_ENTRIES}"

# Set ZFS properties for boot
zfs set org.zfsbootmenu:commandline="noresume init_on_alloc=0 rw spl.spl_hostid=$(hostid)" zroot/ROOT/default || error_exit "Failed to set ZFSBootMenu commandline property"

print_header "Configure mkinitcpio"

# Ensure ZFS hook is present (for ZFS root). Prefer placing it before filesystems.
if ! grep -qE '^HOOKS=.*\<zfs\>' /etc/mkinitcpio.conf; then
    sed -i '/^HOOKS=/ s/\<filesystems\>/zfs filesystems/' /etc/mkinitcpio.conf
fi

mkinitcpio -p linux-lts


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


print_header "Enable Multilib repository"

sed -i '/\[multilib\]/,/Include/ s/^#//' /etc/pacman.conf
pacman -Syy


print_header "System config"

echo "$HOSTNAME" > /etc/hostname

ln -sf /usr/share/zoneinfo/Europe/Rome /etc/localtime

hwclock --systohc

timedatectl set-ntp true

sed -i '/^#en_US.UTF-8/s/^#//g' /etc/locale.gen && locale-gen

echo -e "127.0.0.1   localhost\n::1         localhost\n127.0.1.1   $HOSTNAME.localdomain   $HOSTNAME" > /etc/hosts


print_header "Install utilities and Enable services"
pacman -S --noconfirm net-tools flatpak git man nano


print_header "Install KDE desktop environment"

pacman -S --noconfirm plasma-meta kde-applications-meta sddm
systemctl enable sddm.service

# Configure SDDM with Breeze theme and Wayland
mkdir -p /etc/sddm.conf.d || error_exit "Failed to create sddm config directory"


bash -c 'cat > /etc/sddm.conf.d/theme.conf <<EOFSDDM
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
EOFSDDM'


print_header "Install audio components"

pacman -S --noconfirm wireplumber pipewire-pulse pipewire-alsa pavucontrol-qt


print_header "Install NVIDIA drivers"

pacman -S --noconfirm nvidia-open-lts nvidia-settings nvidia-utils opencl-nvidia libxnvctrl egl-wayland


print_header "Create user and set passwords"

useradd -m -G wheel,audio,video,storage -s /bin/bash "$USER"

echo "$USER:$USERPASS" | chpasswd
echo "root:$ROOTPASS" | chpasswd


print_header "Configure sudoers file"

# Configure sudo using visudo-safe method
echo "%wheel ALL=(ALL:ALL) ALL" > /etc/sudoers.d/wheel
chmod 0440 /etc/sudoers.d/wheel

echo "Configuration completed successfully!"

EOF

# Cleanup temporary helper copied into the installed system
rm -f /mnt/root/.arch-install-helpers.sh

print_header "Unmount and prepare for reboot"

echo "Syncing filesystems..."
sync

echo "Unmounting filesystems..."
umount -R /mnt || true
zfs umount -a || true
zpool export zroot || true

echo ""
echo "=========================================="
echo "Installation completed successfully!"
echo "=========================================="
echo ""
echo "IMPORTANT: Before rebooting:"
echo "1. Remove the installation media"
echo "2. Press Enter to reboot now, or Ctrl+C to stay in live environment"
echo ""
read -p "Press Enter to reboot..."

reboot