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

ask_desktop_installation() {
    local choice

    while true; do
        if ! read -r -p "Install COSMIC desktop environment and desktop packages? [Y/n]: " choice </dev/tty; then
            echo "WARNING: Unable to read from terminal. Defaulting to desktop installation (yes)."
            choice="y"
        fi
        case "$choice" in
            ""|y|Y|yes|YES)
                INSTALL_DESKTOP="yes"
                break
                ;;
            n|N|no|NO)
                INSTALL_DESKTOP="no"
                break
                ;;
            *)
                echo "Invalid choice. Please answer Y or N."
                ;;
        esac
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
    local -a zroot_mounted=()
    local i

    [ "${CLEANUP_DONE:-0}" -eq 1 ] && return
    CLEANUP_DONE=1

    rm -f /mnt/root/.arch-install-helpers.sh /mnt/root/.arch-rootpass /mnt/root/.arch-userpass
    umount -R /mnt 2>/dev/null || true

    # Unmount only datasets from the install pool to avoid affecting other host pools.
    mapfile -t zroot_mounted < <(zfs mount -H 2>/dev/null | awk '$1 ~ /^zroot($|\/)/ {print $1}')
    for ((i=${#zroot_mounted[@]} - 1; i>=0; i--)); do
        zfs umount "${zroot_mounted[$i]}" 2>/dev/null || true
    done

    zpool export zroot 2>/dev/null || true

    if [ "$exit_code" -ne 0 ]; then
        echo "Cleanup completed after error."
    fi
}

remove_efi_entries_by_label() {
    local label="$1"
    local -a entries=()
    local entry

    mapfile -t entries < <(efibootmgr | awk -v label="$label" '$1 ~ /^Boot[0-9A-Fa-f]{4}\*?$/ && $2 == label {print substr($1,5,4)}')
    [ "${#entries[@]}" -gt 0 ] || return 0

    for entry in "${entries[@]}"; do
        if efibootmgr --bootnum "$entry" --delete-bootnum >/dev/null 2>&1; then
            echo "Removed existing EFI boot entry Boot${entry} (${label})."
        else
            echo "WARNING: Failed to remove existing EFI boot entry Boot${entry} (${label})."
        fi
    done
}

run_yay_noninteractive() {
    local user="$1"
    shift
    local -a pkgs=("$@")
    local sudoers_file="/etc/sudoers.d/90-${user}-yay-nopasswd"
    local -a yay_cmd=(yay -S --needed --noconfirm --sudoflags -n)
    local pkg
    local yay_cmd_str

    [ "${#pkgs[@]}" -gt 0 ] || return 0

    for pkg in "${pkgs[@]}"; do
        yay_cmd+=("$pkg")
    done

    printf '%s ALL=(ALL:ALL) NOPASSWD: ALL\n' "$user" > "$sudoers_file"
    chmod 0440 "$sudoers_file"

    printf -v yay_cmd_str '%q ' "${yay_cmd[@]}"
    if ! su - "$user" -c "$yay_cmd_str"; then
        rm -f "$sudoers_file"
        return 1
    fi

    rm -f "$sudoers_file"
}

# --------------------------------------------------------------------------------------------------------------------------
# START INSTALLATION
# --------------------------------------------------------------------------------------------------------------------------

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
genfstab -U /mnt | grep -v zfs > /mnt/etc/fstab  

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

# Make helper functions available inside chroot
{
    declare -f print_header
    declare -f ask_desktop_installation
    declare -f remove_efi_entries_by_label
    declare -f run_yay_noninteractive
} > /mnt/root/.arch-install-helpers.sh
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

pacman -S --needed --noconfirm signify

mkdir -p /efi/EFI/zbm

ZBM_WORKDIR=$(mktemp -d /tmp/zbm-release.XXXXXX)
ZBM_RELEASE_JSON=$(curl -fsSL https://api.github.com/repos/zbm-dev/zfsbootmenu/releases/latest)

ZBM_TAG=$(printf '%s\n' "$ZBM_RELEASE_JSON" | sed -n 's/.*"tag_name":[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)
ZBM_EFI_URL=$(printf '%s\n' "$ZBM_RELEASE_JSON" | grep -oE '"browser_download_url":[[:space:]]*"[^"]*zfsbootmenu-release-x86_64-[^"]*\.EFI"' | head -n1 | sed -E 's/.*"([^"]*)"/\1/')
ZBM_SIG_URL=$(printf '%s\n' "$ZBM_RELEASE_JSON" | grep -oE '"browser_download_url":[[:space:]]*"[^"]*/sha256\.sig"' | head -n1 | sed -E 's/.*"([^"]*)"/\1/')

[ -n "$ZBM_TAG" ]
[ -n "$ZBM_EFI_URL" ]
[ -n "$ZBM_SIG_URL" ]

ZBM_EFI_FILE="$ZBM_WORKDIR/$(basename "$ZBM_EFI_URL")"
ZBM_SIG_FILE="$ZBM_WORKDIR/sha256.sig"
ZBM_PUBKEY_FILE="$ZBM_WORKDIR/zfsbootmenu.pub"

curl -fL "$ZBM_EFI_URL" -o "$ZBM_EFI_FILE"
curl -fL "$ZBM_SIG_URL" -o "$ZBM_SIG_FILE"

if ! curl -fL "https://raw.githubusercontent.com/zbm-dev/zfsbootmenu/${ZBM_TAG}/releng/keys/zfsbootmenu.pub" -o "$ZBM_PUBKEY_FILE"; then
    curl -fL "https://raw.githubusercontent.com/zbm-dev/zfsbootmenu/master/releng/keys/zfsbootmenu.pub" -o "$ZBM_PUBKEY_FILE"
fi

(
    cd "$ZBM_WORKDIR" || exit 1
    signify -C -p "$ZBM_PUBKEY_FILE" -x "$ZBM_SIG_FILE" "$(basename "$ZBM_EFI_FILE")"
)

install -m 0644 "$ZBM_EFI_FILE" /efi/EFI/zbm/zfsbootmenu.EFI
rm -rf "$ZBM_WORKDIR"
echo "Verified and installed ZFSBootMenu EFI: $(basename "$ZBM_EFI_FILE")"

# Create the boot entry
remove_efi_entries_by_label "ZFSBootMenu"
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
    if ! sbctl enroll-keys -m; then
        echo "Key enrollment failed; continuing without enrolling keys."
    fi
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

# Ensure dracut runtime dependency is present
if ! command -v cpio >/dev/null 2>&1; then
    pacman -S --needed --noconfirm cpio
fi

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
# ZFS SNAPSHOT
# --------------------------------------------------------------------------------------------------------------------------

print_header "Create ZFS snapshot"

SNAPSHOT_TAG="base"
zfs snapshot "zroot/ROOT/default@${SNAPSHOT_TAG}"
echo "Created snapshot: zroot/ROOT/default@${SNAPSHOT_TAG}"

# ----------------------------------------------------------------------------------------------------------------------
# AUDIO
# ----------------------------------------------------------------------------------------------------------------------

print_header "Install audio components"

pacman -S --needed --noconfirm wireplumber pipewire-pulse pipewire-alsa pavucontrol-qt alsa-utils

# ----------------------------------------------------------------------------------------------------------------------
# NVIDIA DRIVERS
# ----------------------------------------------------------------------------------------------------------------------

print_header "Install NVIDIA drivers"

pacman -S --needed --noconfirm nvidia-open-lts nvidia-settings nvidia-utils opencl-nvidia libxnvctrl egl-wayland

# ----------------------------------------------------------------------------------------------------------------------
# YAY
# ----------------------------------------------------------------------------------------------------------------------

print_header "Install yay"

pacman -S --needed --noconfirm git go
su - "$USERNAME" -c 'rm -rf /tmp/yay && git clone https://aur.archlinux.org/yay.git /tmp/yay && cd /tmp/yay && makepkg -s --noconfirm --needed'

shopt -s nullglob
yay_pkgs=(/tmp/yay/yay-*.pkg.tar.*)
[ "${#yay_pkgs[@]}" -gt 0 ]
pacman -U --noconfirm "${yay_pkgs[0]}"

# ----------------------------------------------------------------------------------------------------------------------
# DESKTOP ENVIRONMENT
# ----------------------------------------------------------------------------------------------------------------------

ask_desktop_installation
echo "Desktop installation option: $INSTALL_DESKTOP"

if [ "$INSTALL_DESKTOP" = "yes" ]; then

    # ----------------------------------------------------------------------------------------------------------------------
    # COSMIC
    # ----------------------------------------------------------------------------------------------------------------------

    print_header "Install COSMIC desktop"

    pacman -S --needed --noconfirm cosmic-session
    systemctl enable cosmic-greeter.service

    # ----------------------------------------------------------------------------------------------------------------------
    # APPLICATIONS
    # ----------------------------------------------------------------------------------------------------------------------

    print_header "Install additional applications"

    pacman -S --needed --noconfirm ghostty spotify-launcher steam firefox flatpak fzf eza zsh
    echo "Additional applications installed"

    # ----------------------------------------------------------------------------------------------------------------------
    # EXTRA PACKAGES
    # ----------------------------------------------------------------------------------------------------------------------

    print_header "Install extra packages"

    pacman -S --needed --noconfirm pacman-contrib smartmontools task
    run_yay_noninteractive "$USERNAME" downgrade informant
    echo "Extra packages installed"

else
    print_header "Desktop installation skipped"
    echo "Base system selected: stopping after base ZFS snapshot."
fi

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
