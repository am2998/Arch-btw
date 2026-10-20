#!/bin/bash

# Arch Linux + Encrypted ZFS + ZFSBootMenu + Dracut + Secure Boot + KDE Plasma

set -euo pipefail  # Exit on error, undefined variables, and pipe failures

# --------------------------------------------------------------------------------------------------------------------------
# GLOBAL CONFIGURATION
# --------------------------------------------------------------------------------------------------------------------------

readonly ZFS_POOL="zroot"
readonly ZFS_BOOTFS="${ZFS_POOL}/ROOT/default"
# Restrict the pool to the feature set understood by the bundled ZFSBootMenu
# release image. The file must exist in /usr/share/zfs/compatibility.d/.
readonly ZFS_COMPAT="openzfs-2.3"
# ZFSBootMenu releases ship one EFI per bundled kernel. ZBM runs its own kernel,
# so this does not have to match the target kernel; it only has to boot the host.
readonly ZBM_KERNEL_VARIANT="${ZBM_KERNEL_VARIANT:-linux6.12}"
readonly INSTALL_LOG="/var/log/archzfs-install.log"

# Mirror output to a log file when possible. Prompts still go to the terminal.
if [ -w /var/log ] || [ -w "$INSTALL_LOG" ]; then
    exec > >(tee -a "$INSTALL_LOG") 2>&1
fi

# --------------------------------------------------------------------------------------------------------------------------
# HELPER FUNCTIONS
# --------------------------------------------------------------------------------------------------------------------------

die() {
    echo "ERROR: $*" >&2
    exit 1
}

warn() {
    echo "WARNING: $*" >&2
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

print_header() {
    local title="$1"
    local line="--------------------------------------------------------------------------------------------------------------------------"
    echo -e "\n\n# ${line}"
    echo -e "# ${title}"
    echo -e "# ${line}\n"
}

get_password() {
    local prompt=$1
    local target=$2
    local password
    local password_recheck

    while true; do
        if ! read -r -s -p "$prompt (min 8 chars): " password; then
            die "Unable to read password (input closed)."
        fi
        echo
        if [ "${#password}" -lt 8 ]; then
            echo "Password must be at least 8 characters long."
            continue
        fi
        if ! read -r -s -p "Re-enter password: " password_recheck; then
            die "Unable to read password (input closed)."
        fi
        echo
        if [ "$password" = "$password_recheck" ]; then
            printf -v "$target" '%s' "$password"
            return 0
        fi
        echo "Passwords do not match. Please try again."
    done
}

prompt_validated() {
    local prompt=$1
    local target=$2
    local regex=$3
    local error_message=$4
    local value

    while true; do
        if ! read -r -p "$prompt" value; then
            die "Input aborted while reading: $prompt"
        fi
        if [[ "$value" =~ $regex ]]; then
            printf -v "$target" '%s' "$value"
            return 0
        fi
        echo "$error_message"
    done
}

# shellcheck disable=SC2034  # INSTALL_DESKTOP is consumed by the chroot script
ask_desktop_installation() {
    local choice

    while true; do
        if ! read -r -p "Install KDE Plasma desktop environment and desktop packages? [Y/n]: " choice </dev/tty; then
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
    local selection_index
    local live_disk

    # Skip zram/loop devices (lsblk classifies them as "disk") and, when it can
    # be identified, the disk hosting the running live ISO (usually the USB
    # installation medium). Detection failures degrade to no exclusion.
    live_disk="$(findmnt -n -o SOURCE /run/archiso/bootmnt 2>/dev/null || true)"
    if [ -n "$live_disk" ]; then
        live_disk="/dev/$(lsblk -dno PKNAME "$live_disk" 2>/dev/null || true)"
    fi
    mapfile -t disks < <(lsblk -dpno NAME,TYPE | awk -v live="$live_disk" '
        $2 == "disk" && $1 != live && $1 !~ /^\/dev\/(zram|loop)/ {print $1}')
    [ "${#disks[@]}" -gt 0 ] || \
        die "No suitable disks found (after excluding zram/loop and, if detectable, the live medium)."

    echo "Available disks:"
    for index in "${!disks[@]}"; do
        printf "  %d. %s\n" "$((index + 1))" "$(lsblk -dno NAME,SIZE,MODEL "${disks[$index]}" 2>/dev/null || printf '%s' "${disks[$index]}")"
    done

    if ! read -r -p "Select target disk number: " selection; then
        die "Disk selection aborted."
    fi
    [[ "$selection" =~ ^[0-9]+$ ]] || die "Invalid selection: '$selection' (expected a number)."
    selection_index=$((10#$selection))
    [ "$selection_index" -ge 1 ] && [ "$selection_index" -le "${#disks[@]}" ] || die "Selection out of range: $selection."

    DISK="${disks[$((selection_index - 1))]}"
    if [[ "$DISK" =~ (nvme|mmcblk) ]]; then
        PARTITION_1="p1"
        PARTITION_2="p2"
    else
        PARTITION_1="1"
        PARTITION_2="2"
    fi

    if lsblk -no MOUNTPOINT "$DISK" | grep '[^[:space:]]' >/dev/null; then
        die "Disk $DISK has mounted partitions. Unmount them or choose another disk."
    fi

    echo
    echo "Selected disk: $DISK"
}

confirm_erase() {
    local confirmation

    echo
    echo "Target disk: $DISK"
    lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINT,MODEL "$DISK" || true
    echo
    echo "ALL DATA ON $DISK WILL BE DESTROYED."
    if ! read -r -p "Type the full device path to confirm ($DISK): " confirmation; then
        die "Confirmation aborted."
    fi
    [ "$confirmation" = "$DISK" ] || die "Confirmation mismatch ('$confirmation' != '$DISK'). Aborting."
}

wait_for_partition() {
    local partition=$1
    local attempt

    for ((attempt = 1; attempt <= 20; attempt++)); do
        [ -b "$partition" ] && return 0
        sleep 0.5
    done
    die "Partition device $partition did not appear after partitioning."
}

preflight_checks() {
    [ "$(id -u)" -eq 0 ] || die "This installer must be run as root (from the Arch live environment)."
    [ -d /sys/firmware/efi ] || die "UEFI firmware is required (this installer creates an EFI boot entry)."

    require_command pacstrap
    require_command arch-chroot
    require_command parted
    require_command wipefs
    require_command mkfs.fat
    require_command blkid
    require_command zpool
    require_command zfs
    require_command efibootmgr
    require_command curl

    [ -f "/usr/share/zfs/compatibility.d/${ZFS_COMPAT}" ] || \
        die "ZFS feature set '${ZFS_COMPAT}' is not available. Install a recent OpenZFS (>= 2.3)."

    if ! curl -fsS --max-time 10 -o /dev/null https://archlinux.org/; then
        die "No network connectivity to archlinux.org. Connect to the internet and retry."
    fi

    if zpool list -H -o name "$ZFS_POOL" >/dev/null 2>&1; then
        die "A pool named '$ZFS_POOL' is already imported. Export it before retrying."
    fi
}

cleanup() {
    local exit_code=${1:-0}
    local -a zroot_mounted=()
    local i

    [ "${CLEANUP_DONE:-0}" -eq 1 ] && return
    CLEANUP_DONE=1

    rm -f /mnt/root/.arch-install-helpers.sh /mnt/root/.arch-rootpass /mnt/root/.arch-userpass || true
    rm -f /tmp/arch-zfs.key /tmp/arch-zfs-key.* || true
    rm -f /mnt/boot/arch-linux-lts.efi /mnt/boot/arch-linux-lts.efi.tmp || true
    rm -f /mnt/efi/EFI/Linux/arch-linux-lts.efi.new || true
    umount -R /mnt 2>/dev/null || true

    # Unmount only datasets from the install pool to avoid affecting other host pools.
    mapfile -t zroot_mounted < <(zfs mount -H 2>/dev/null | awk -v pool="$ZFS_POOL" '$1 == pool || index($1, pool "/") == 1 {print $1}')
    for ((i=${#zroot_mounted[@]} - 1; i>=0; i--)); do
        zfs umount "${zroot_mounted[$i]}" 2>/dev/null || true
    done

    zpool export "$ZFS_POOL" 2>/dev/null || true

    if [ "$exit_code" -ne 0 ]; then
        echo "Cleanup completed after error."
    fi
}

remove_efi_entries_by_label() {
    local label=$1
    local -a entries=()
    local entry

    mapfile -t entries < <(efibootmgr | awk -v label="$label" '
        $1 ~ /^Boot[0-9A-Fa-f]{4}\*?$/ {
            entry = substr($1, 5, 4)
            sub(/\*$/, "", entry)
            line = $0
            sub(/^[^[:space:]]+[[:space:]]+/, "", line)
            # efibootmgr prints the label, a tab, then the device path.
            tab = index(line, "\t")
            if (tab > 0) {
                line = substr(line, 1, tab - 1)
            }
            if (line == label) {
                print entry
            }
        }
    ')
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
    local user=$1
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

ROOTPASS=""
USERPASS=""
ZFS_PASS=""
TARGET_USER=""
TARGET_HOSTNAME=""
DISK=""
PARTITION_1=""
PARTITION_2=""

echo -e "\n=== Arch Linux ZFS Installation ==="
echo -e "This script will ERASE all data on the selected disk!\n"

preflight_checks

# Ensure pacman keyring is initialized in fresh live environments.
pacman-key --init
pacman-key --populate

get_password "Enter the password for root user" ROOTPASS
prompt_validated "Enter the username: " TARGET_USER '^[a-z_][a-z0-9_-]{0,31}$' \
    "Invalid username: use lowercase letters, digits, '_' or '-', starting with a letter or '_' (max 32 characters)."
get_password "Enter the password for user $TARGET_USER" USERPASS
get_password "Enter the ZFS encryption passphrase" ZFS_PASS
prompt_validated "Enter the hostname: " TARGET_HOSTNAME '^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$' \
    "Invalid hostname: use letters, digits and '-' only (max 63 characters, no leading or trailing '-')."

# --------------------------------------------------------------------------------------------------------------------------
# DISK PARTITIONING
# --------------------------------------------------------------------------------------------------------------------------

print_header "Disk Detection"

select_install_disk
trap 'cleanup $?' EXIT

print_header "Partitioning $DISK"

confirm_erase

wipefs -a -f "$DISK"
parted "$DISK" --script mklabel gpt
parted "$DISK" --script mkpart ESP fat32 1MiB 1GiB
parted "$DISK" --script set 1 esp on
parted "$DISK" --script mkpart primary 1GiB 100%

if command -v partprobe >/dev/null 2>&1; then
    partprobe "$DISK" 2>/dev/null || true
fi
wait_for_partition "${DISK}${PARTITION_1}"
wait_for_partition "${DISK}${PARTITION_2}"

echo "Partitions created successfully."

# --------------------------------------------------------------------------------------------------------------------------
# ZPOOL AND DATASET
# --------------------------------------------------------------------------------------------------------------------------

print_header "zpool and dataset creation"

# A temporary key file is used only for non-interactive pool creation. The
# persistent keylocation is set to "prompt" later: the UKI lives on the
# unencrypted ESP and must never contain the pool passphrase.
ZFS_KEYFILE="$(mktemp /tmp/arch-zfs-key.XXXXXX)"
printf '%s' "$ZFS_PASS" > "$ZFS_KEYFILE"
zpool create \
    -f \
    -o ashift=12 \
    -o autotrim=on \
    -o compatibility="$ZFS_COMPAT" \
    -O acltype=posixacl -O canmount=off -O compression=lz4 \
    -O dnodesize=auto -O normalization=formD \
    -O atime=off -O xattr=sa -O mountpoint=none \
    -O encryption=aes-256-gcm -O keyformat=passphrase -O keylocation="file://$ZFS_KEYFILE" \
    -R /mnt "$ZFS_POOL" "${DISK}${PARTITION_2}"

# Switch to an interactive passphrase immediately. The UKI lives on the
# unencrypted ESP, so no persistent key file may be referenced. Doing this
# before removing the temporary file avoids leaving the pool pointing at a
# deleted key if the installation is interrupted.
zfs set keylocation=prompt "$ZFS_POOL"
rm -f "$ZFS_KEYFILE"

ZFS_COMPAT_ACTUAL="$(zpool get -H -o value compatibility "$ZFS_POOL")"
case "$ZFS_COMPAT_ACTUAL" in
    "$ZFS_COMPAT"|*/"$ZFS_COMPAT") ;;
    *) die "Pool compatibility is '$ZFS_COMPAT_ACTUAL', expected '$ZFS_COMPAT'." ;;
esac

echo "ZFS pool created successfully (compatibility: $ZFS_COMPAT)."

# Dataset layout
zfs create -o mountpoint=none "${ZFS_POOL}/ROOT"
zfs create -o mountpoint=/ -o canmount=noauto "$ZFS_BOOTFS"

zpool set bootfs="$ZFS_BOOTFS" "$ZFS_POOL"
echo "bootfs property set successfully."

zfs mount "$ZFS_BOOTFS"

mkdir -p /mnt/etc/zfs /etc/zfs
zpool set cachefile=/etc/zfs/zpool.cache "$ZFS_POOL"
cp /etc/zfs/zpool.cache /mnt/etc/zfs/zpool.cache
unset ZFS_PASS

mkfs.fat -F32 "${DISK}${PARTITION_1}"
mkdir -p /mnt/efi
mount "${DISK}${PARTITION_1}" /mnt/efi

# --------------------------------------------------------------------------------------------------------------------------
# BASE SYSTEM
# --------------------------------------------------------------------------------------------------------------------------

print_header "Install base system"

UCODE_PACKAGE=""
case "$(awk -F: '/^vendor_id/ {gsub(/[ \t]/, "", $2); print $2; exit}' /proc/cpuinfo)" in
    GenuineIntel)
        UCODE_PACKAGE="intel-ucode"
        ;;
    AuthenticAMD)
        UCODE_PACKAGE="amd-ucode"
        ;;
    *)
        warn "Unknown CPU vendor: no microcode package will be installed."
        ;;
esac

base_packages=(
    base base-devel linux-lts linux-lts-headers linux-firmware
    efibootmgr dracut sbctl zram-generator sudo networkmanager
    wget reflector nano pacman-contrib
)
if [ -n "$UCODE_PACKAGE" ]; then
    base_packages+=("$UCODE_PACKAGE")
fi

pacstrap /mnt "${base_packages[@]}"

# --------------------------------------------------------------------------------------------------------------------------
# FSTAB
# --------------------------------------------------------------------------------------------------------------------------

print_header "Generate fstab file"

EFI_UUID="$(blkid -s UUID -o value "${DISK}${PARTITION_1}")"
[ -n "$EFI_UUID" ] || die "Unable to read the UUID of ${DISK}${PARTITION_1}."

# Exclude ZFS entries (ZFS handles its own mounting via zfs-mount.service) and
# write the ESP entry explicitly. The ESP is needed at boot by systemd-boot's
# random-seed service and by update hooks; it contains no secrets (UKI/ZBM only).
genfstab -U /mnt | awk '$3 != "zfs" && $2 != "/efi"' > /mnt/etc/fstab
printf 'UUID=%s  /efi  vfat  fmask=0137,dmask=0027,nofail,x-systemd.device-timeout=1  0  0\n' "$EFI_UUID" >> /mnt/etc/fstab

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

# Reuse the archzfs keyring shipped with the live ISO (when available) so the
# chroot does not depend on keyserver availability.
for keyring_file in archzfs.gpg archzfs-trusted; do
    if [ -f "/usr/share/pacman/keyrings/$keyring_file" ]; then
        install -Dm644 "/usr/share/pacman/keyrings/$keyring_file" "/mnt/usr/share/pacman/keyrings/$keyring_file"
    fi
done

ROOTPASS_FILE="/mnt/root/.arch-rootpass"
USERPASS_FILE="/mnt/root/.arch-userpass"
(umask 077 && printf 'root:%s\n' "$ROOTPASS" > "$ROOTPASS_FILE")
(umask 077 && printf '%s:%s\n' "$TARGET_USER" "$USERPASS" > "$USERPASS_FILE")
unset ROOTPASS
unset USERPASS

if ! arch-chroot /mnt \
    /usr/bin/env DISK="$DISK" PARTITION_1="$PARTITION_1" \
    TARGET_USER="$TARGET_USER" TARGET_HOSTNAME="$TARGET_HOSTNAME" \
    ROOTPASS_FILE="/root/.arch-rootpass" USERPASS_FILE="/root/.arch-userpass" \
    ZFS_POOL="$ZFS_POOL" ZFS_BOOTFS="$ZFS_BOOTFS" ZFS_COMPAT="$ZFS_COMPAT" \
    ZBM_KERNEL_VARIANT="$ZBM_KERNEL_VARIANT" \
    /bin/bash --noprofile --norc -euo pipefail <<'EOF'

source /root/.arch-install-helpers.sh

# Safety: ensure we don't echo each input line (bash verbose mode)
set +o verbose || true
set +o xtrace || true

die() {
    echo "ERROR: $*" >&2
    exit 1
}

warn() {
    echo "WARNING: $*" >&2
}

# --------------------------------------------------------------------------------------------------------------------------
# MIRRORS
# --------------------------------------------------------------------------------------------------------------------------

print_header "Configure pacman mirrors"

cp /etc/pacman.d/mirrorlist /etc/pacman.d/mirrorlist.backup

if ! reflector --country "Italy,Germany,France,Netherlands,Switzerland,Austria" --latest 20 --sort rate --protocol https --age 7 --save /etc/pacman.d/mirrorlist; then
    echo "WARNING: reflector failed, restoring the shipped mirrorlist."
    cp /etc/pacman.d/mirrorlist.backup /etc/pacman.d/mirrorlist
fi

if ! grep -q '^Server' /etc/pacman.d/mirrorlist; then
    echo "WARNING: no mirrors found, restoring the shipped mirrorlist."
    cp /etc/pacman.d/mirrorlist.backup /etc/pacman.d/mirrorlist
fi

echo "Active mirrors:"
grep '^Server' /etc/pacman.d/mirrorlist || true

# --------------------------------------------------------------------------------------------------------------------------
# BASE PACKAGE VERIFICATION
# --------------------------------------------------------------------------------------------------------------------------

print_header "Verify base packages"

pacman -Q pacman-contrib >/dev/null 2>&1 || die "pacman-contrib is not installed."

# --------------------------------------------------------------------------------------------------------------------------
# SERVICES
# --------------------------------------------------------------------------------------------------------------------------

print_header "Manage Services"

systemctl enable NetworkManager
systemctl mask NetworkManager-wait-online.service
systemctl mask ldconfig.service
systemctl mask geoclue
# NTP is enabled through the unit file: timedatectl requires a running systemd instance.
systemctl enable systemd-timesyncd.service

echo "Services configured."

# --------------------------------------------------------------------------------------------------------------------------
# ZFS
# --------------------------------------------------------------------------------------------------------------------------

print_header "Setup ZFS"

PACMAN_CONF_BACKUP="/etc/pacman.conf.archzfs-backup"
cp /etc/pacman.conf "$PACMAN_CONF_BACKUP"

# Replace any pre-existing [archzfs] section (for example inherited from the ISO)
# with the canonical configuration, so signature policy is always explicit.
awk '
    /^\[archzfs\]/ { skip = 1; next }
    skip && /^\[/   { skip = 0 }
    !skip           { print }
' /etc/pacman.conf > /etc/pacman.conf.new
cat >> /etc/pacman.conf.new <<'EOFARCHZFS'
[archzfs]
SigLevel = Required
Server = https://github.com/archzfs/archzfs/releases/download/experimental
EOFARCHZFS
mv /etc/pacman.conf.new /etc/pacman.conf

# ArchZFS release key (see https://github.com/archzfs/archzfs/releases/tag/experimental)
pacman-key --init
pacman-key --populate archlinux
if [ -f /usr/share/pacman/keyrings/archzfs.gpg ]; then
    pacman-key --populate archzfs || warn "Could not populate the archzfs keyring from local files."
fi
if ! pacman-key --finger 3A9917BF0DED5C13F69AC68FABEC0A1208037BE9 >/dev/null 2>&1; then
    pacman-key --recv-keys 3A9917BF0DED5C13F69AC68FABEC0A1208037BE9
fi
pacman-key --lsign-key 3A9917BF0DED5C13F69AC68FABEC0A1208037BE9

pacman -Syu --noconfirm --needed zfs-dkms

# Detect the kernel version *after* the full upgrade, because pacman -Syu may
# install a newer linux-lts than the one pulled in by pacstrap.
KERNEL_VERSION=""
if kernel_pkgver="$(pacman -Q linux-lts 2>/dev/null | awk '{print $2}' || true)" && [ -n "$kernel_pkgver" ]; then
    KERNEL_VERSION="${kernel_pkgver}-lts"
fi
if [ -z "$KERNEL_VERSION" ] || [ ! -d "/usr/lib/modules/$KERNEL_VERSION" ]; then
    KERNEL_VERSION="$(find /usr/lib/modules -mindepth 1 -maxdepth 1 -type d -name '*-lts' -printf '%f\n' 2>/dev/null | sort -V | tail -n1)"
fi
[ -n "$KERNEL_VERSION" ] && [ -d "/usr/lib/modules/$KERNEL_VERSION" ] || \
    die "Cannot determine the installed linux-lts kernel version."
echo "Detected kernel: $KERNEL_VERSION"

if ! modinfo -k "$KERNEL_VERSION" zfs >/dev/null 2>&1; then
    die "The ZFS kernel module is missing for $KERNEL_VERSION after installing zfs-dkms."
fi

systemctl enable zfs.target zfs-import-cache zfs-mount zfs-import.target
# No persistent key file: the passphrase is entered at boot by the initramfs
# (and by ZFSBootMenu when the recovery entry is used).
if [ "$(zfs get -H -o value keylocation "$ZFS_POOL")" != "prompt" ]; then
    zfs set keylocation=prompt "$ZFS_POOL"
fi

command -v zgenhostid >/dev/null 2>&1 || \
    die "zgenhostid (zfs-utils) is required to set a stable ZFS hostid."
zgenhostid -f || die "Failed to generate a ZFS hostid."

# --------------------------------------------------------------------------------------------------------------------------
# ZFSBOOTMENU
# --------------------------------------------------------------------------------------------------------------------------

print_header "Install ZFSBootMenu"

pacman -S --needed --noconfirm signify

mkdir -p /efi/EFI/zbm

ZBM_WORKDIR="$(mktemp -d /tmp/zbm-release.XXXXXX)"
ZBM_RELEASE_JSON="$(curl -fsSL https://api.github.com/repos/zbm-dev/zfsbootmenu/releases/latest)"

ZBM_TAG="$(printf '%s\n' "$ZBM_RELEASE_JSON" | sed -n 's/.*"tag_name":[[:space:]]*"\([^"]*\)".*/\1/p' | sed -n '1p')"
[ -n "$ZBM_TAG" ] || die "Could not determine the latest ZFSBootMenu release tag."

ZBM_EFI_URL="$(printf '%s\n' "$ZBM_RELEASE_JSON" \
    | grep -oE '"browser_download_url":[[:space:]]*"[^"]*zfsbootmenu-release-x86_64-[^"]*-'"$ZBM_KERNEL_VARIANT"'\.EFI"' \
    | sed -n '1p' | sed -E 's/.*"([^"]*)"/\1/')"
if [ -z "$ZBM_EFI_URL" ]; then
    echo "WARNING: no ZFSBootMenu asset for '$ZBM_KERNEL_VARIANT', falling back to the first release EFI."
    ZBM_EFI_URL="$(printf '%s\n' "$ZBM_RELEASE_JSON" \
        | grep -oE '"browser_download_url":[[:space:]]*"[^"]*zfsbootmenu-release-x86_64-[^"]*\.EFI"' \
        | sed -n '1p' | sed -E 's/.*"([^"]*)"/\1/')"
fi
ZBM_SIG_URL="$(printf '%s\n' "$ZBM_RELEASE_JSON" | grep -oE '"browser_download_url":[[:space:]]*"[^"]*/sha256\.sig"' | sed -n '1p' | sed -E 's/.*"([^"]*)"/\1/')"

[ -n "$ZBM_EFI_URL" ] || die "Could not find a ZFSBootMenu EFI asset in the latest release."
[ -n "$ZBM_SIG_URL" ] || die "Could not find the ZFSBootMenu sha256.sig asset in the latest release."

ZBM_EFI_FILE="$ZBM_WORKDIR/$(basename "$ZBM_EFI_URL")"
ZBM_SIG_FILE="$ZBM_WORKDIR/sha256.sig"
ZBM_PUBKEY_FILE="$ZBM_WORKDIR/zfsbootmenu.pub"

curl -fL --retry 3 "$ZBM_EFI_URL" -o "$ZBM_EFI_FILE"
curl -fL --retry 3 "$ZBM_SIG_URL" -o "$ZBM_SIG_FILE"

if ! curl -fL --retry 3 "https://raw.githubusercontent.com/zbm-dev/zfsbootmenu/${ZBM_TAG}/releng/keys/zfsbootmenu.pub" -o "$ZBM_PUBKEY_FILE"; then
    curl -fL --retry 3 "https://raw.githubusercontent.com/zbm-dev/zfsbootmenu/master/releng/keys/zfsbootmenu.pub" -o "$ZBM_PUBKEY_FILE"
fi

(
    cd "$ZBM_WORKDIR" || exit 1
    signify -C -p "$ZBM_PUBKEY_FILE" -x "$ZBM_SIG_FILE" "$(basename "$ZBM_EFI_FILE")"
)

install -m 0644 "$ZBM_EFI_FILE" /efi/EFI/zbm/zfsbootmenu.EFI
rm -rf "$ZBM_WORKDIR"
echo "Verified and installed ZFSBootMenu EFI: $(basename "$ZBM_EFI_FILE")"

# Embed the ZFSBootMenu command line in the EFI image. This is required when
# the image is chainloaded by systemd-boot under Secure Boot: the signed stub
# ignores external LoadOptions and only uses the embedded .cmdline section.
command -v objcopy >/dev/null 2>&1 || die "objcopy (binutils) is required to build the UKI."

set_efi_cmdline() {
    local efi cmdline tmp size cmd_vma_hex cmd_vma_dec gap
    local -a sections

    efi="$1"
    cmdline="$2"
    tmp="$(mktemp)"
    printf ' %s\0' "$cmdline" > "$tmp"
    size="$(stat -c %s "$tmp")"

    mapfile -t sections < <(objdump -h -w "$efi" | awk '$1 ~ /^[0-9]+$/ {print $2, $4}')
    cmd_vma_hex=""
    for line in "${sections[@]}"; do
        # shellcheck disable=SC2086
        set -- $line
        if [ "$1" = ".cmdline" ]; then
            cmd_vma_hex="$2"
        fi
    done
    [ -n "$cmd_vma_hex" ] || die "The ZFSBootMenu EFI has no .cmdline section."

    cmd_vma_dec=$((0x$cmd_vma_hex))
    gap=""
    for line in "${sections[@]}"; do
        # shellcheck disable=SC2086
        set -- $line
        local vma_dec=$((0x$2))
        if [ "$vma_dec" -gt "$cmd_vma_dec" ]; then
            local candidate=$((vma_dec - cmd_vma_dec))
            if [ -z "$gap" ] || [ "$candidate" -lt "$gap" ]; then
                gap="$candidate"
            fi
        fi
    done
    [ -n "$gap" ] || die "Unable to determine the .cmdline gap in the ZFSBootMenu EFI."
    [ "$size" -le "$gap" ] || die "The ZFSBootMenu command line is too large ($size > $gap bytes)."

    objcopy --remove-section .cmdline "$efi"
    objcopy --add-section ".cmdline=$tmp" --change-section-vma ".cmdline=0x$cmd_vma_hex" "$efi"
    rm -f "$tmp"
    echo "Embedded ZFSBootMenu command line: $cmdline"
}

ZBM_BOOT_CMDLINE="spl_hostid=$(hostid) zbm.timeout=3 zbm.prefer=$ZFS_POOL zbm.import_policy=hostid quiet loglevel=0 nomodeset"
set_efi_cmdline /efi/EFI/zbm/zfsbootmenu.EFI "$ZBM_BOOT_CMDLINE"

# --------------------------------------------------------------------------------------------------------------------------
# SYSTEMD-BOOT + UKI
# --------------------------------------------------------------------------------------------------------------------------

print_header "Install systemd-boot and UKI directory layout"

mkdir -p /efi/EFI/Linux /efi/loader/entries

# --variables=no keeps bootctl from touching EFI variables; the boot entries
# are created explicitly below so their order is deterministic.
if ! bootctl --esp-path=/efi --variables=no install; then
    warn "bootctl install failed; installing systemd-boot files manually."
fi

if [ ! -f /efi/EFI/systemd/systemd-bootx64.efi ] || [ ! -f /efi/EFI/BOOT/BOOTX64.EFI ]; then
    install -Dm644 /usr/lib/systemd/boot/efi/systemd-bootx64.efi /efi/EFI/systemd/systemd-bootx64.efi
    install -Dm644 /usr/lib/systemd/boot/efi/systemd-bootx64.efi /efi/EFI/BOOT/BOOTX64.EFI
fi

# Automatic bootloader updates are not signed. The pacman hook installed below
# reinstalls and re-signs systemd-boot after systemd package updates instead.
systemctl disable systemd-boot-update.service 2>/dev/null || true

cat > /efi/loader/loader.conf <<'EOFLOADER'
default arch-linux-lts.efi
timeout 3
editor no
EOFLOADER

# Keep ZFSBootMenu in the systemd-boot menu as a snapshot/recovery fallback.
cat > /efi/loader/entries/zfsbootmenu.conf <<'EOFZBMENU'
title ZFSBootMenu (snapshots/recovery)
efi /EFI/zbm/zfsbootmenu.EFI
EOFZBMENU

efi_entry_number() {
    local label="$1"
    efibootmgr | awk -v label="$label" '
        $1 ~ /^Boot[0-9A-Fa-f]{4}\*?$/ {
            entry = substr($1, 5, 4)
            sub(/\*$/, "", entry)
            line = $0
            sub(/^[^[:space:]]+[[:space:]]+/, "", line)
            # efibootmgr prints the label, a tab, then the device path.
            tab = index(line, "\t")
            if (tab > 0) {
                line = substr(line, 1, tab - 1)
            }
            if (line == label) {
                print entry
                exit
            }
        }
    '
}

# systemd-boot is the default boot path; ZFSBootMenu remains a second firmware
# entry for recovery.
remove_efi_entries_by_label "Linux Boot Manager"
efibootmgr --disk "$DISK" --part 1 --create --label "Linux Boot Manager" \
    --loader '\EFI\systemd\systemd-bootx64.efi' --verbose >/dev/null

remove_efi_entries_by_label "ZFSBootMenu"
efibootmgr --disk "$DISK" --part 1 --create --label "ZFSBootMenu" \
    --loader '\EFI\zbm\zfsbootmenu.EFI' --verbose >/dev/null

SYSTEMD_BOOT_ENTRY="$(efi_entry_number "Linux Boot Manager")"
ZBM_BOOT_ENTRY="$(efi_entry_number "ZFSBootMenu")"
if [ -n "$SYSTEMD_BOOT_ENTRY" ] && [ -n "$ZBM_BOOT_ENTRY" ]; then
    if ! efibootmgr --bootorder "${SYSTEMD_BOOT_ENTRY},${ZBM_BOOT_ENTRY}" >/dev/null; then
        warn "Could not set the EFI boot order; check it in the firmware setup."
    fi
else
    warn "Could not determine the EFI boot entry numbers; check the boot order."
fi

# Set ZFS properties for boot
zfs set org.zfsbootmenu:commandline="noresume rw init_on_alloc=0 spl_hostid=$(hostid) rd.systemd.gpt_auto=0" "$ZFS_BOOTFS"

# --------------------------------------------------------------------------------------------------------------------------
# DRACUT
# --------------------------------------------------------------------------------------------------------------------------

print_header "Configure dracut and Unified Kernel Image"

# Configure dracut with the ZFS module. The initramfs must NOT contain the ZFS
# passphrase: the UKI is stored on the unencrypted ESP. ZFS prompts at boot.
cat > /etc/dracut.conf.d/99-zfs.conf <<'EOFDRACUT'
hostonly="yes"
hostonly_cmdline="no"
add_dracutmodules+=" zfs "
i18n_vars+=" KEYMAP "
compress="zstd"
EOFDRACUT

# Ensure dracut runtime dependency is present
if ! command -v cpio >/dev/null 2>&1; then
    pacman -S --needed --noconfirm cpio
fi

# Kernel command line embedded in the UKI. This is what makes the UKI
# self-contained: it does not rely on systemd-boot or ZFSBootMenu to add
# root= or the ZFS hostid.
UKI_PATH="/efi/EFI/Linux/arch-linux-lts.efi"
# Build on the encrypted ZFS root first. The unencrypted ESP must never hold a
# UKI that has not passed the keyfile and cmdline checks below.
UKI_BUILD_PATH="/boot/arch-linux-lts.efi"
UKI_CMDLINE="root=zfs:$ZFS_BOOTFS rw noresume init_on_alloc=0 spl_hostid=$(hostid) rd.systemd.gpt_auto=0"
mkdir -p /etc/kernel
printf '%s\n' "$UKI_CMDLINE" > /etc/kernel/cmdline

# Traditional initramfs: used by the ZFSBootMenu snapshot/recovery entry.
dracut --force --hostonly --kver "$KERNEL_VERSION" /boot/initramfs-linux-lts.img

[ -s /boot/initramfs-linux-lts.img ] || die "dracut did not produce /boot/initramfs-linux-lts.img."
if ! lsinitrd /boot/initramfs-linux-lts.img 2>/dev/null | grep 'zfs\.ko' >/dev/null; then
    die "The generated initramfs does not contain the ZFS kernel module."
fi
if lsinitrd /boot/initramfs-linux-lts.img 2>/dev/null | grep -E '(^|[[:space:]/])etc/zfs/zroot\.key$' >/dev/null; then
    die "The initramfs contains /etc/zfs/zroot.key; refusing to build a UKI."
fi

# Unified Kernel Image: systemd-boot's default boot path.
if ! dracut --force --hostonly --kver "$KERNEL_VERSION" --uefi \
    --kernel-cmdline "$UKI_CMDLINE" "$UKI_BUILD_PATH"; then
    rm -f "$UKI_BUILD_PATH" "$UKI_BUILD_PATH.tmp"
    die "dracut failed to produce a UKI."
fi

[ -s "$UKI_BUILD_PATH" ] || {
    rm -f "$UKI_BUILD_PATH"
    die "dracut did not produce $UKI_BUILD_PATH."
}
for section in .linux .initrd .cmdline; do
    if ! objdump -h "$UKI_BUILD_PATH" | grep -F "$section" >/dev/null; then
        rm -f "$UKI_BUILD_PATH"
        die "The generated UKI is missing the $section section."
    fi
done
if lsinitrd "$UKI_BUILD_PATH" 2>/dev/null | grep -E '(^|[[:space:]/])etc/zfs/zroot\.key$' >/dev/null; then
    rm -f "$UKI_BUILD_PATH"
    die "The UKI contains /etc/zfs/zroot.key; refusing to install it on the unencrypted ESP."
fi
if ! lsinitrd "$UKI_BUILD_PATH" 2>/dev/null | grep 'zfs\.ko' >/dev/null; then
    rm -f "$UKI_BUILD_PATH"
    die "The generated UKI does not contain the ZFS kernel module."
fi

UKI_EMBEDDED_CMDLINE="$(mktemp)" || {
    rm -f "$UKI_BUILD_PATH"
    die "Could not create a temporary file for the UKI command line."
}
if ! objcopy --dump-section ".cmdline=$UKI_EMBEDDED_CMDLINE" "$UKI_BUILD_PATH"; then
    rm -f "$UKI_EMBEDDED_CMDLINE" "$UKI_BUILD_PATH"
    die "Could not read the .cmdline section from the generated UKI."
fi
if ! tr -d '\0' < "$UKI_EMBEDDED_CMDLINE" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | grep -Fqx "$UKI_CMDLINE"; then
    rm -f "$UKI_EMBEDDED_CMDLINE" "$UKI_BUILD_PATH"
    die "The UKI does not contain the expected kernel command line."
fi
rm -f "$UKI_EMBEDDED_CMDLINE"

# The UKI is verified; only now copy it to the unencrypted ESP. Copy to a
# temporary name first so a failed/partial copy cannot replace a working UKI.
UKI_TMP_PATH="${UKI_PATH}.new"
rm -f "$UKI_TMP_PATH"
if ! install -Dm644 "$UKI_BUILD_PATH" "$UKI_TMP_PATH"; then
    rm -f "$UKI_BUILD_PATH" "$UKI_TMP_PATH"
    die "Could not install the verified UKI to $UKI_TMP_PATH."
fi
if ! mv -f "$UKI_TMP_PATH" "$UKI_PATH"; then
    rm -f "$UKI_BUILD_PATH" "$UKI_TMP_PATH"
    die "Could not atomically install the verified UKI to $UKI_PATH."
fi
rm -f "$UKI_BUILD_PATH"

echo "Dracut and UKI configuration completed (kernel: $KERNEL_VERSION)."

# --------------------------------------------------------------------------------------------------------------------------
# SECURE BOOT
# --------------------------------------------------------------------------------------------------------------------------

print_header "Configure Secure Boot"

# Create local PK/KEK/db keys once, then enroll when firmware is in Setup Mode.
# sbctl stores its keys in /var/lib/sbctl by default; create-keys is idempotent.
if [ ! -f /var/lib/sbctl/keys/db/db.key ]; then
    sbctl create-keys
fi

if sbctl status 2>/dev/null | grep 'Setup Mode:.*Enabled' >/dev/null; then
    if ! sbctl enroll-keys -m; then
        warn "Key enrollment failed; continuing without enrolling keys."
    fi
else
    echo "Setup Mode is disabled; skipping key enrollment."
fi

# Sign every EFI binary in the boot chain: systemd-boot (both copies), the UKI
# and the ZFSBootMenu recovery image.
for efi in \
    /efi/EFI/systemd/systemd-bootx64.efi \
    /efi/EFI/BOOT/BOOTX64.EFI \
    "$UKI_PATH" \
    /efi/EFI/zbm/zfsbootmenu.EFI; do
    [ -f "$efi" ] || die "Cannot sign missing EFI binary: $efi"
    sbctl sign -s "$efi"
done
echo "systemd-boot, UKI and ZFSBootMenu EFI signed"

# --------------------------------------------------------------------------------------------------------------------------
# PACMAN HOOKS
# --------------------------------------------------------------------------------------------------------------------------

print_header "Install pacman hooks"

if [ -f /usr/local/share/archzfs/zfs-dracut-kernel-refresh.sh ] && \
   [ -f /usr/local/share/archzfs/60-zfs-dracut-post.hook ]; then
    install -Dm755 /usr/local/share/archzfs/zfs-dracut-kernel-refresh.sh \
        /usr/local/bin/zfs-dracut-kernel-refresh
    install -Dm644 /usr/local/share/archzfs/60-zfs-dracut-post.hook \
        /etc/pacman.d/hooks/60-zfs-dracut-post.hook
    echo "Installed UKI refresh pacman hook."
else
    warn "UKI refresh hook not found in the ISO; kernel updates will not rebuild/sign the UKI automatically."
fi

# --------------------------------------------------------------------------------------------------------------------------
# ZRAM
# --------------------------------------------------------------------------------------------------------------------------

print_header "Configure ZRAM"

cat > /etc/systemd/zram-generator.conf <<'EOFZRAM'
[zram0]
zram-size = min(ram, 32768)
compression-algorithm = zstd
EOFZRAM

cat > /etc/sysctl.d/99-vm-zram-parameters.conf <<'EOFSYSCTL'
vm.swappiness = 180
vm.watermark_boost_factor = 0
vm.watermark_scale_factor = 125
vm.page-cluster = 0
EOFSYSCTL

sysctl --system

# --------------------------------------------------------------------------------------------------------------------------
# MULTILIB REPO
# --------------------------------------------------------------------------------------------------------------------------

print_header "Enable Multilib repository"

sed -i '/\[multilib\]/,/Include/ s/^#//' /etc/pacman.conf
pacman -Sy --noconfirm

# --------------------------------------------------------------------------------------------------------------------------
# SYSTEM CONFIG
# --------------------------------------------------------------------------------------------------------------------------

print_header "System config"

echo "$TARGET_HOSTNAME" > /etc/hostname
ln -sf /usr/share/zoneinfo/Europe/Rome /etc/localtime
hwclock --systohc
sed -i '/^#en_US.UTF-8/s/^#//g' /etc/locale.gen
locale-gen
echo -e "127.0.0.1   localhost\n::1         localhost\n127.0.1.1   $TARGET_HOSTNAME.localdomain   $TARGET_HOSTNAME" > /etc/hosts
echo "KEYMAP=us" > /etc/vconsole.conf
echo "LANG=en_US.UTF-8" > /etc/locale.conf

# --------------------------------------------------------------------------------------------------------------------------
# USER
# --------------------------------------------------------------------------------------------------------------------------

print_header "Create user account"

useradd -m -G wheel -s /bin/bash "$TARGET_USER"
chpasswd < "$USERPASS_FILE"
shred -u "$USERPASS_FILE" || rm -f "$USERPASS_FILE"

cat > /etc/sudoers.d/10-wheel <<'EOFSUDOERS'
%wheel ALL=(ALL:ALL) ALL
EOFSUDOERS
chmod 0440 /etc/sudoers.d/10-wheel
visudo -cf /etc/sudoers.d/10-wheel >/dev/null
echo "User account '$TARGET_USER' created and sudo access configured."

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
if zfs list -H -t snapshot -o name "${ZFS_BOOTFS}@${SNAPSHOT_TAG}" >/dev/null 2>&1; then
    echo "Snapshot ${ZFS_BOOTFS}@${SNAPSHOT_TAG} already exists, skipping."
else
    zfs snapshot "${ZFS_BOOTFS}@${SNAPSHOT_TAG}"
    echo "Created snapshot: ${ZFS_BOOTFS}@${SNAPSHOT_TAG}"
fi

# ----------------------------------------------------------------------------------------------------------------------
# DESKTOP ENVIRONMENT
# ----------------------------------------------------------------------------------------------------------------------

ask_desktop_installation
echo "Desktop installation option: $INSTALL_DESKTOP"

if [ "$INSTALL_DESKTOP" = "yes" ]; then

    # ------------------------------------------------------------------------------------------------------------------
    # AUDIO
    # ------------------------------------------------------------------------------------------------------------------

    print_header "Install audio components"

    pacman -S --needed --noconfirm pipewire wireplumber pipewire-pulse pipewire-alsa alsa-utils pavucontrol-qt

    # ------------------------------------------------------------------------------------------------------------------
    # NVIDIA DRIVERS
    # ------------------------------------------------------------------------------------------------------------------

    print_header "Install NVIDIA drivers"

    # nvidia-open-lts supports Turing (RTX 20xx / GTX 16xx) and newer GPUs.
    # Pascal and older require the proprietary legacy branch (AUR nvidia-580xx-dkms).
    pacman -S --needed --noconfirm nvidia-open-lts nvidia-settings nvidia-utils opencl-nvidia libxnvctrl egl-wayland

    # Required for Wayland/KWin and for a clean framebuffer handoff on modern drivers.
    cat > /etc/modprobe.d/nvidia.conf <<'EOFNVIDIA'
options nvidia_drm modeset=1 fbdev=1
EOFNVIDIA

    # ------------------------------------------------------------------------------------------------------------------
    # YAY
    # ------------------------------------------------------------------------------------------------------------------

    print_header "Install yay"

    pacman -S --needed --noconfirm git go
    su - "$TARGET_USER" -c 'rm -rf /tmp/yay && git clone --depth 1 https://aur.archlinux.org/yay.git /tmp/yay && cd /tmp/yay && makepkg -s --noconfirm --needed'

    shopt -s nullglob
    yay_pkgs=(/tmp/yay/yay-*.pkg.tar.*)
    [ "${#yay_pkgs[@]}" -gt 0 ] || die "The yay package was not built."
    pacman -U --noconfirm "${yay_pkgs[0]}"
    rm -rf /tmp/yay

    # ------------------------------------------------------------------------------------------------------------------
    # KDE PLASMA
    # ------------------------------------------------------------------------------------------------------------------

    print_header "Install KDE Plasma desktop"

    pacman -Syu --needed --noconfirm \
        plasma-desktop plasma-pa plasma-nm kscreen breeze \
        konsole dolphin kate \
        xdg-desktop-portal-kde xdg-desktop-portal-gtk kde-gtk-config \
        plasma-login-manager flatpak-kcm

    # Plasma Login Manager: Wayland-only greeter (KWin). The package ships
    # plasmalogin.service with Alias=display-manager.service and no default
    # /etc/plasmalogin.conf: built-in defaults are used unless overridden.
    systemctl enable plasmalogin.service

    # ------------------------------------------------------------------------------------------------------------------
    # APPLICATIONS
    # ------------------------------------------------------------------------------------------------------------------

    print_header "Install additional applications"

    pacman -S --needed --noconfirm ghostty spotify-launcher steam firefox flatpak fzf eza zsh
    echo "Additional applications installed"

    # ------------------------------------------------------------------------------------------------------------------
    # EXTRA PACKAGES
    # ------------------------------------------------------------------------------------------------------------------

    print_header "Install extra packages"

    pacman -S --needed --noconfirm smartmontools task
    if ! run_yay_noninteractive "$TARGET_USER" downgrade informant; then
        warn "Some optional AUR packages (downgrade, informant) failed to install; continuing."
    fi
    echo "Extra packages installed"

else
    print_header "Desktop installation skipped"
    echo "Base system selected: stopping after base ZFS snapshot."
fi

# The desktop step runs `pacman -Syu`, which may update the kernel, ZFS, dracut
# or systemd after the initial UKI was built. Run the refresh helper once more
# so the final ESP image always matches the installed kernel. Listing `systemd`
# also forces a final bootctl install and re-sign of systemd-boot.
if [ -x /usr/local/bin/zfs-dracut-kernel-refresh ]; then
    printf 'linux-lts\nsystemd\n' | /usr/local/bin/zfs-dracut-kernel-refresh || \
        warn "Final UKI/initramfs refresh failed; verify the boot chain before rebooting."
fi

[ -s "$UKI_PATH" ] || die "The final UKI is missing from $UKI_PATH; refusing to finish."

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

read -r -p "Type R/r to reboot: " REBOOT_CONFIRM
if [ "$REBOOT_CONFIRM" = "R" ] || [ "$REBOOT_CONFIRM" = "r" ]; then
    reboot
else
    echo "Reboot skipped. You can reboot manually when ready."
fi

exit 0
