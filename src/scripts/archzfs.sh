#!/bin/bash

# Arch Linux + Encrypted ZFS + ZFSBootMenu + Dracut + Secure Boot

set -euo pipefail  # Exit on error, undefined variables, and pipe failures

# Ensure pacman keyring is initialized in fresh live environments.
pacman-key --init
pacman-key --populate

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
        echo -n "$prompt (min 8 chars): "; read -r -s password_var; echo
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
        printf "  %d. %s\n" "$((index + 1))" "${disks[$index]}"
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

    echo
    echo "Selected disk: $DISK"
}

cleanup() {
    local exit_code=${1:-$?}

    [ "${CLEANUP_DONE:-0}" -eq 1 ] && return
    CLEANUP_DONE=1

    rm -f /mnt/root/.arch-install-helpers.sh /mnt/root/.arch-rootpass /mnt/root/.arch-userpass
    umount -R /mnt 2>/dev/null || true
    zfs umount -a 2>/dev/null || true
    zpool export zroot 2>/dev/null || true

    if [ "$exit_code" -ne 0 ]; then
        echo "Cleanup completed after error."
    fi
}

echo -e "\n=== Arch Linux ZFS Installation ==="
echo -e "This script will ERASE all data on the selected disk!\n"

get_password "Enter the password for root user" ROOTPASS

echo -n "Enter the username: "; read -r USERNAME
get_password "Enter the password for user $USERNAME" USERPASS
get_password "Enter the ZFS encryption passphrase" ZFS_PASS
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

# Use a key file so dracut can auto-unlock after ZFSBootMenu unlock.
ZFS_KEYFILE="/tmp/arch-zfs.key"
PREV_UMASK="$(umask)"
umask 077
printf '%s' "$ZFS_PASS" > "$ZFS_KEYFILE"
zpool create \
    -o ashift=12 \
    -O acltype=posixacl -O canmount=off -O compression=lz4 \
    -O dnodesize=auto -O normalization=formD -o autotrim=on \
    -O atime=off -O xattr=sa -O mountpoint=none \
    -O encryption=aes-256-gcm -O keyformat=passphrase -O keylocation="file://$ZFS_KEYFILE" \
    -R /mnt zroot ${DISK}${PARTITION_2} -f  
rm -f "$ZFS_KEYFILE"
umask "$PREV_UMASK"
echo "ZFS pool created successfully."

# Dataset layout
#zfs create -o mountpoint=none zroot/data  
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
PREV_UMASK="$(umask)"
umask 077
printf '%s' "$ZFS_PASS" > /mnt/etc/zfs/zroot.key
umask "$PREV_UMASK"
unset ZFS_PASS

mkfs.fat -F32 "${DISK}${PARTITION_1}"  
mkdir -p /mnt/efi  
mount "${DISK}${PARTITION_1}" /mnt/efi  

# --------------------------------------------------------------------------------------------------------------------------
# BASE SYSTEM
# --------------------------------------------------------------------------------------------------------------------------

print_header "Install base system"

pacstrap /mnt linux-lts linux-lts-headers base base-devel linux-firmware efibootmgr dracut sbctl zram-generator sudo networkmanager amd-ucode wget reflector nano

# --------------------------------------------------------------------------------------------------------------------------
# FSTAB
# --------------------------------------------------------------------------------------------------------------------------

print_header "Generate fstab file"

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
USERPASS_FILE="/mnt/root/.arch-userpass"
umask 077
printf 'root:%s\n' "$ROOTPASS" > "$ROOTPASS_FILE"
printf '%s:%s\n' "$USERNAME" "$USERPASS" > "$USERPASS_FILE"
unset ROOTPASS
unset USERPASS

if ! arch-chroot /mnt \
    /usr/bin/env DISK="$DISK" PARTITION_1="$PARTITION_1" HOSTNAME="$HOSTNAME" USERNAME="$USERNAME" ROOTPASS_FILE="/root/.arch-rootpass" USERPASS_FILE="/root/.arch-userpass" \
    /bin/bash --noprofile --norc -euo pipefail <<'EOF'

source /root/.arch-install-helpers.sh

error_exit() {
    echo "ERROR: $1" >&2
    exit 1
}

# Safety: ensure we don't echo each input line (bash verbose mode)
set +o verbose || true
set +o xtrace || true

echo "Chrooted successfully!"

# --------------------------------------------------------------------------------------------------------------------------
# MIRRORS
# --------------------------------------------------------------------------------------------------------------------------

print_header "Configure pacman mirrors"

cp /etc/pacman.d/mirrorlist /etc/pacman.d/mirrorlist.backup

reflector --country "Italy,Germany,France,Netherlands,Switzerland,Austria" --latest 20 --sort rate --protocol https --age 7 --save /etc/pacman.d/mirrorlist

# Verify reflector actually produced a valid mirrorlist
if ! grep -q '^Server' /etc/pacman.d/mirrorlist; then
    echo "WARNING: reflector produced no mirrors, restoring backup"
    cp /etc/pacman.d/mirrorlist.backup /etc/pacman.d/mirrorlist
fi

echo "Active mirrors:"
grep '^Server' /etc/pacman.d/mirrorlist

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
# ZFS
# --------------------------------------------------------------------------------------------------------------------------

print_header "Setup ZFS"

if ! grep -q '^\[archzfs\]' /etc/pacman.conf; then
    echo -e '
[archzfs]
SigLevel = TrustAll Optional
Server = https://github.com/archzfs/archzfs/releases/download/experimental' >> /etc/pacman.conf
fi

# ArchZFS GPG keys (see https://wiki.archlinux.org/index.php/Unofficial_user_repositories#archzfs)
pacman-key -r DDF7DB817396A49B2A2723F7403BD972F75D9D76
pacman-key --lsign-key DDF7DB817396A49B2A2723F7403BD972F75D9D76

pacman -Syu --noconfirm --needed zfs-dkms
systemctl enable zfs.target zfs-import-cache zfs-mount zfs-import.target
zfs set keylocation=file:///etc/zfs/zroot.key zroot

if command -v zgenhostid >/dev/null 2>&1; then
    zgenhostid -f
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
    --unicode "spl_hostid=$(hostid) zbm.timeout=3 zbm.prefer=zroot zbm.import_policy=hostid" \
    --verbose >/dev/null

# Set ZFS properties for boot
zfs set org.zfsbootmenu:commandline="noresume rw init_on_alloc=0 spl.spl_hostid=$(hostid) rd.systemd.gpt_auto=0" zroot/ROOT/default  

# --------------------------------------------------------------------------------------------------------------------------
# SECURE BOOT
# --------------------------------------------------------------------------------------------------------------------------

print_header "Configure Secure Boot"

# Create local PK/KEK/db keys once, then enroll when firmware is in Setup Mode.
if [ ! -f /usr/share/secureboot/keys/db/db.key ]; then
    sbctl create-keys
fi

if sbctl status | grep -q '^Setup Mode:[[:space:]]*✓'; then
    sbctl enroll-keys -m
else
    echo "Setup Mode is disabled; skipping key enrollment."
fi

# Sign the EFI binary so it can boot with Secure Boot enabled.
sbctl sign -s /efi/EFI/zbm/zfsbootmenu.EFI
echo "ZFSBootMenu EFI signed"

# --------------------------------------------------------------------------------------------------------------------------
# DRACUT
# --------------------------------------------------------------------------------------------------------------------------

print_header "Configure dracut"

# Configure dracut with ZFS module.
bash -c 'cat > /etc/dracut.conf.d/99-zfs.conf <<EOFDRACUT
hostonly="yes"
uefi="no"
hostonly_cmdline="no"
add_dracutmodules+=" zfs "
i18n_vars+=" KEYMAP "
install_items+=" /etc/zfs/zroot.key "
compress="zstd"
EOFDRACUT'

# Find kernel version
KERNEL_VERSION=$(ls /usr/lib/modules/ | grep lts | head -n1)

# Generate traditional initramfs
dracut --force --hostonly --kver "$KERNEL_VERSION" /boot/initramfs-linux-lts.img
echo "Dracut configuration completed (kernel: $KERNEL_VERSION)."

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
echo "KEYMAP=us" > /etc/vconsole.conf
echo "LANG=en_US.UTF-8" > /etc/locale.conf

# --------------------------------------------------------------------------------------------------------------------------
# USER
# --------------------------------------------------------------------------------------------------------------------------

print_header "Create user account"

useradd -m -G wheel -s /bin/bash "$USERNAME"
chpasswd < "$USERPASS_FILE"
shred -u "$USERPASS_FILE" || rm -f "$USERPASS_FILE"

cat > /etc/sudoers.d/10-wheel <<'EOFSUDOERS'
%wheel ALL=(ALL:ALL) ALL
EOFSUDOERS
chmod 0440 /etc/sudoers.d/10-wheel
echo "User account '$USERNAME' created and sudo access configured."

# --------------------------------------------------------------------------------------------------------------------------
# ROOT PASSWORD
# --------------------------------------------------------------------------------------------------------------------------

print_header "Set root user password"

chpasswd < "$ROOTPASS_FILE"
shred -u "$ROOTPASS_FILE" || rm -f "$ROOTPASS_FILE"

echo "Root password set."

echo "Configuration completed successfully!"

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
# YAY
# --------------------------------------------------------------------------------------------------------------------------

print_header "Install yay"

pacman -S --needed --noconfirm git go
su - "$USERNAME" -c 'rm -rf /tmp/yay && git clone https://aur.archlinux.org/yay.git /tmp/yay && cd /tmp/yay && makepkg -s --noconfirm --needed'

shopt -s nullglob
yay_pkgs=(/tmp/yay/yay-*.pkg.tar.*)
if [ "${#yay_pkgs[@]}" -eq 0 ]; then
    error_exit "yay package build failed"
fi
pacman -U --noconfirm "${yay_pkgs[0]}"

# --------------------------------------------------------------------------------------------------------------------------
# SNAPSHOTS
# --------------------------------------------------------------------------------------------------------------------------

print_header "Create ZFS snapshot before installing desktop environment"

SNAPSHOT_TAG="base"
zfs snapshot "zroot/ROOT/default@${SNAPSHOT_TAG}"
echo "Created snapshot: zroot/ROOT/default@${SNAPSHOT_TAG}"

# --------------------------------------------------------------------------------------------------------------------------
# COSMIC
# --------------------------------------------------------------------------------------------------------------------------

print_header "Install COSMIC desktop"

pacman -S --needed --noconfirm cosmic-session
systemctl enable cosmic-greeter.service

# --------------------------------------------------------------------------------------------------------------------------
# APPLICATIONS
# --------------------------------------------------------------------------------------------------------------------------

print_header "Install additional applications"

pacman -S --needed --noconfirm ghostty spotify-launcher steam flatpak fzf eza zsh
echo "Additional applications installed: ghostty spotify-launcher steam flatpak fzf eza zsh"

# --------------------------------------------------------------------------------------------------------------------------
# INSTALLATION COMPLETED
# --------------------------------------------------------------------------------------------------------------------------

EOF
then
    echo
    echo "Chroot configuration failed."
    echo "Opening an interactive rescue shell inside chroot (/mnt)."
    arch-chroot /mnt /bin/bash -i || true
    echo "Rescue shell closed. Installation will now stop and cleanup will run."
    exit 1
fi

print_header "Unmount and prepare for reboot"

echo "Unmounting filesystems..."
cleanup 0
trap - EXIT

while read -r -t 0; do read -r  true; done

read -r -p "Type R/r to reboot: " REBOOT_CONFIRM
if [ "$REBOOT_CONFIRM" = "R" ] || [ "$REBOOT_CONFIRM" = "r" ]; then
    reboot
else
    echo "Reboot skipped. You can reboot manually when ready."
fi

exit 0

: <<'MANUAL_INSTALLATION_GUIDE'
##########################################################################################################################
##########################################################################################################################
##                                                                                                                      ##
##                                    MANUAL - COMMANDS FOR MANUAL INSTALLATION                                        ##
##                                                                                                                      ##
##########################################################################################################################
##########################################################################################################################

This section contains all commands to manually install Arch Linux with ZFS and ZFSBootMenu.
Replace variables inside <...> with your values.

--------------------------------------------------------------------------------------------------------------------------
VARIABLES TO SET
--------------------------------------------------------------------------------------------------------------------------

DISK="/dev/sdX"                    # Target disk (e.g., /dev/sda, /dev/nvme0n1)
PARTITION_1="1"                    # For SATA: "1", for NVMe: "p1"
PARTITION_2="2"                    # For SATA: "2", for NVMe: "p2"
HOSTNAME="archlinux"               # Hostname
USERNAME="archuser"                # Username
ZFS_PASS="password"                # ZFS encryption passphrase

--------------------------------------------------------------------------------------------------------------------------
1. DISK PARTITIONING
--------------------------------------------------------------------------------------------------------------------------

wipefs -a -f "$DISK"
parted "$DISK" --script mklabel gpt
parted "$DISK" --script mkpart ESP fat32 1MiB 1GiB
parted "$DISK" --script set 1 esp on
parted "$DISK" --script mkpart primary 1GiB 100%

--------------------------------------------------------------------------------------------------------------------------
2. ZPOOL AND DATASET CREATION
--------------------------------------------------------------------------------------------------------------------------

# Create a temporary key file
ZFS_KEYFILE="/tmp/arch-zfs.key"
umask 077
printf '%s' "$ZFS_PASS" > "$ZFS_KEYFILE"

# Create encrypted zpool
zpool create \
    -o ashift=12 \
    -O acltype=posixacl -O canmount=off -O compression=lz4 \
    -O dnodesize=auto -O normalization=formD -o autotrim=on \
    -O atime=off -O xattr=sa -O mountpoint=none \
    -O encryption=aes-256-gcm -O keyformat=passphrase -O keylocation="file://$ZFS_KEYFILE" \
    -R /mnt zroot ${DISK}${PARTITION_2} -f

rm -f "$ZFS_KEYFILE"

# Create datasets
zfs create -o mountpoint=none zroot/ROOT
zfs create -o mountpoint=/ -o canmount=noauto zroot/ROOT/default

# Set bootfs
zpool set bootfs=zroot/ROOT/default zroot

# Mount datasets
zfs mount zroot/ROOT/default
zfs mount -a

# Configure cache
mkdir -p /mnt/etc/zfs
zpool set cachefile=/etc/zfs/zpool.cache zroot
cp /etc/zfs/zpool.cache /mnt/etc/zfs/zpool.cache

# Store key for auto-unlock
umask 077
printf '%s' "$ZFS_PASS" > /mnt/etc/zfs/zroot.key

# Format and mount EFI partition
mkfs.fat -F32 "${DISK}${PARTITION_1}"
mkdir -p /mnt/efi
mount "${DISK}${PARTITION_1}" /mnt/efi

--------------------------------------------------------------------------------------------------------------------------
3. BASE SYSTEM INSTALLATION
--------------------------------------------------------------------------------------------------------------------------

pacstrap /mnt linux-lts linux-lts-headers base base-devel linux-firmware efibootmgr dracut sbctl zram-generator sudo networkmanager amd-ucode wget reflector nano

--------------------------------------------------------------------------------------------------------------------------
4. FSTAB GENERATION
--------------------------------------------------------------------------------------------------------------------------

genfstab -U /mnt | grep -v zfs >> /mnt/etc/fstab

# Get EFI partition UUID
EFI_UUID=$(blkid -s UUID -o value "${DISK}${PARTITION_1}")

# Make EFI mount optional
sed -i "/\/efi.*vfat/c\\UUID=${EFI_UUID}  /efi  vfat  noauto,nofail,x-systemd.device-timeout=1  0  0" /mnt/etc/fstab

--------------------------------------------------------------------------------------------------------------------------
5. CHROOT INTO THE SYSTEM
--------------------------------------------------------------------------------------------------------------------------

arch-chroot /mnt

--------------------------------------------------------------------------------------------------------------------------
6. MIRROR CONFIGURATION (inside chroot)
--------------------------------------------------------------------------------------------------------------------------

cp /etc/pacman.d/mirrorlist /etc/pacman.d/mirrorlist.backup
reflector --country "Italy,Germany,France,Netherlands,Switzerland,Austria" --latest 20 --sort rate --protocol https --age 7 --save /etc/pacman.d/mirrorlist

--------------------------------------------------------------------------------------------------------------------------
7. ENABLE SERVICES (inside chroot)
--------------------------------------------------------------------------------------------------------------------------

systemctl enable NetworkManager
systemctl mask NetworkManager-wait-online.service
systemctl mask ldconfig.service
systemctl mask geoclue

--------------------------------------------------------------------------------------------------------------------------
8. INSTALL ZFS (inside chroot)
--------------------------------------------------------------------------------------------------------------------------

# Add archzfs repository
echo -e '
[archzfs]
SigLevel = TrustAll Optional
Server = https://github.com/archzfs/archzfs/releases/download/experimental' >> /etc/pacman.conf

# Import GPG keys
pacman-key -r DDF7DB817396A49B2A2723F7403BD972F75D9D76
pacman-key --lsign-key DDF7DB817396A49B2A2723F7403BD972F75D9D76

# Install ZFS
pacman -Syu --noconfirm --needed zfs-dkms

# Enable ZFS services
systemctl enable zfs.target zfs-import-cache zfs-mount zfs-import.target

# Configure keylocation
zfs set keylocation=file:///etc/zfs/zroot.key zroot

# Generate hostid
zgenhostid -f

--------------------------------------------------------------------------------------------------------------------------
9. INSTALL ZFSBOOTMENU (inside chroot)
--------------------------------------------------------------------------------------------------------------------------

mkdir -p /efi/EFI/zbm
wget https://get.zfsbootmenu.org/latest.EFI -O /efi/EFI/zbm/zfsbootmenu.EFI

# Create EFI entry
efibootmgr --disk "$DISK" --part 1 --create --label "ZFSBootMenu" \
    --loader '\EFI\zbm\zfsbootmenu.EFI' \
    --unicode "spl_hostid=$(hostid) zbm.timeout=3 zbm.prefer=zroot zbm.import_policy=hostid" \
    --verbose

# Set ZFS properties for boot
zfs set org.zfsbootmenu:commandline="noresume rw init_on_alloc=0 spl.spl_hostid=$(hostid) rd.systemd.gpt_auto=0" zroot/ROOT/default

--------------------------------------------------------------------------------------------------------------------------
10. SECURE BOOT SETUP (inside chroot)
--------------------------------------------------------------------------------------------------------------------------

# Create Secure Boot keys
sbctl create-keys

# If in Setup Mode, enroll keys
sbctl status
sbctl enroll-keys -m 

# Sign EFI binary
sbctl sign -s /efi/EFI/zbm/zfsbootmenu.EFI

--------------------------------------------------------------------------------------------------------------------------
11. DRACUT CONFIGURATION (inside chroot)
--------------------------------------------------------------------------------------------------------------------------

cat > /etc/dracut.conf.d/99-zfs.conf <<EOF
hostonly="yes"
uefi="no"
hostonly_cmdline="no"
add_dracutmodules+=" zfs "
i18n_vars+=" KEYMAP "
install_items+=" /etc/zfs/zroot.key "
compress="zstd"
EOF

# Find kernel version
KERNEL_VERSION=$(ls /usr/lib/modules/ | grep lts | head -n1)

# Generate initramfs
dracut --force --hostonly --kver "$KERNEL_VERSION" /boot/initramfs-linux-lts.img

--------------------------------------------------------------------------------------------------------------------------
12. ZRAM CONFIGURATION (inside chroot)
--------------------------------------------------------------------------------------------------------------------------

cat > /etc/systemd/zram-generator.conf <<EOF
[zram0]
zram-size = min(ram, 32768)
compression-algorithm = zstd
EOF

echo "vm.swappiness = 180" >> /etc/sysctl.d/99-vm-zram-parameters.conf
echo "vm.watermark_boost_factor = 0" >> /etc/sysctl.d/99-vm-zram-parameters.conf
echo "vm.watermark_scale_factor = 125" >> /etc/sysctl.d/99-vm-zram-parameters.conf
echo "vm.page-cluster = 0" >> /etc/sysctl.d/99-vm-zram-parameters.conf

sysctl --system

--------------------------------------------------------------------------------------------------------------------------
13. ENABLE MULTILIB (inside chroot)
--------------------------------------------------------------------------------------------------------------------------

sed -i '/\[multilib\]/,/Include/ s/^#//' /etc/pacman.conf
pacman -Syy

--------------------------------------------------------------------------------------------------------------------------
14. SYSTEM CONFIGURATION (inside chroot)
--------------------------------------------------------------------------------------------------------------------------

echo "$HOSTNAME" > /etc/hostname
ln -sf /usr/share/zoneinfo/Europe/Rome /etc/localtime
hwclock --systohc
timedatectl set-ntp true
sed -i '/^#en_US.UTF-8/s/^#//g' /etc/locale.gen && locale-gen
echo -e "127.0.0.1   localhost\n::1         localhost\n127.0.1.1   $HOSTNAME.localdomain   $HOSTNAME" > /etc/hosts
echo "KEYMAP=us" > /etc/vconsole.conf
echo "LANG=en_US.UTF-8" > /etc/locale.conf

--------------------------------------------------------------------------------------------------------------------------
15. CREATE USER (inside chroot)
--------------------------------------------------------------------------------------------------------------------------

useradd -m -G wheel -s /bin/bash "$USERNAME"
passwd "$USERNAME"

cat > /etc/sudoers.d/10-wheel <<EOF
%wheel ALL=(ALL:ALL) ALL
EOF
chmod 0440 /etc/sudoers.d/10-wheel

--------------------------------------------------------------------------------------------------------------------------
16. ROOT PASSWORD (inside chroot)
--------------------------------------------------------------------------------------------------------------------------

passwd root

--------------------------------------------------------------------------------------------------------------------------
17. AUDIO (inside chroot)
--------------------------------------------------------------------------------------------------------------------------

pacman -S --needed --noconfirm wireplumber pipewire-pulse pipewire-alsa pavucontrol-qt alsa-utils

--------------------------------------------------------------------------------------------------------------------------
18. NVIDIA DRIVERS (inside chroot) - Optional
--------------------------------------------------------------------------------------------------------------------------

pacman -S --needed --noconfirm nvidia-open-lts nvidia-settings nvidia-utils opencl-nvidia libxnvctrl egl-wayland

--------------------------------------------------------------------------------------------------------------------------
19. INSTALL YAY (inside chroot)
--------------------------------------------------------------------------------------------------------------------------

pacman -S --needed --noconfirm git go
su - "$USERNAME" -c 'rm -rf /tmp/yay && git clone https://aur.archlinux.org/yay.git /tmp/yay && cd /tmp/yay && makepkg -s --noconfirm --needed'
pacman -U --noconfirm /tmp/yay/yay-*.pkg.tar.*

--------------------------------------------------------------------------------------------------------------------------
20. PRE-DESKTOP SNAPSHOT (inside chroot)
--------------------------------------------------------------------------------------------------------------------------

zfs snapshot "zroot/ROOT/default@base"

--------------------------------------------------------------------------------------------------------------------------
21. INSTALL COSMIC DESKTOP (inside chroot)
--------------------------------------------------------------------------------------------------------------------------

pacman -S --needed --noconfirm cosmic-session
systemctl enable cosmic-greeter.service

--------------------------------------------------------------------------------------------------------------------------
22. INSTALL APPLICATIONS (inside chroot)
--------------------------------------------------------------------------------------------------------------------------

pacman -S --needed --noconfirm ghostty spotify-launcher steam flatpak fzf eza zsh

--------------------------------------------------------------------------------------------------------------------------
23. EXIT CHROOT AND CLEANUP
--------------------------------------------------------------------------------------------------------------------------

exit  # Exit chroot

umount -R /mnt
zfs umount -a
zpool export zroot

--------------------------------------------------------------------------------------------------------------------------
24. RIAVVIO
--------------------------------------------------------------------------------------------------------------------------

reboot

MANUAL_INSTALLATION_GUIDE
