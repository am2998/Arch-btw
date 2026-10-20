#!/bin/bash

# Pacman hook helper: rebuild the ZFS initramfs and the systemd-boot Unified
# Kernel Image (UKI) after kernel/ZFS/dracut updates, then re-sign the boot
# chain with sbctl. Runs unconditionally on every matching transaction: the
# boot chain must stay in sync with the installed packages, so there is no
# user opt-out. Best effort by design: it must not block pacman.

set -euo pipefail

ESP_PATH="${ESP_PATH:-/efi}"
UKI_PATH="${UKI_PATH:-$ESP_PATH/EFI/Linux/arch-linux-lts.efi}"
KERNEL_FLAVOR="${KERNEL_FLAVOR:-linux-lts}"
CMDLINE_FILE="${CMDLINE_FILE:-/etc/kernel/cmdline}"

ESP_MOUNTED=0

log() {
    echo "zfs-dracut-kernel-refresh: $*" >&2
    if command -v logger >/dev/null 2>&1; then
        logger -t zfs-dracut-kernel-refresh -- "$*" 2>/dev/null || true
    fi
}

cleanup() {
    if [ "$ESP_MOUNTED" -eq 1 ] && mountpoint -q "$ESP_PATH"; then
        umount "$ESP_PATH" || log "warning: could not unmount $ESP_PATH"
    fi
}

trap cleanup EXIT

read_targets() {
    local line
    local targets=()

    while IFS= read -r line; do
        [ -n "$line" ] && targets+=("$line")
    done

    printf '%s\n' "${targets[@]:-}"
}

mount_esp() {
    if mountpoint -q "$ESP_PATH"; then
        return 0
    fi

    if mount "$ESP_PATH" >/dev/null 2>&1; then
        ESP_MOUNTED=1
        return 0
    fi

    return 1
}

kernel_version() {
    local kver

    # Use the package's module directory instead of guessing the kernel suffix.
    kver="$(pacman -Qlq "$KERNEL_FLAVOR" 2>/dev/null | awk -F'/usr/lib/modules/' '
        NF > 1 && $1 == "" {
            split($2, parts, "/")
            if (!found && parts[1] != "") {
                print parts[1]
                found = 1
            }
        }
    ')" || return 1

    [ -n "$kver" ] || return 1
    printf '%s\n' "$kver"
}

build_uki() {
    local kver="$1"
    local initramfs="/boot/initramfs-${KERNEL_FLAVOR}.img"
    # Build on the encrypted root; only a verified UKI is copied to the ESP.
    local build_path="/boot/arch-linux-lts.efi"

    [ -s "$CMDLINE_FILE" ] || {
        log "missing $CMDLINE_FILE, skipping UKI rebuild"
        return 1
    }

    # A UKI lives on the unencrypted ESP: never embed the ZFS passphrase.
    if [ -s "$initramfs" ] && lsinitrd "$initramfs" 2>/dev/null | \
        grep -E '(^|[[:space:]/])etc/zfs/zroot\.key$' >/dev/null; then
        log "refusing to build UKI: $initramfs contains /etc/zfs/zroot.key"
        return 1
    fi

    if [ -s "$initramfs" ] && ! lsinitrd "$initramfs" 2>/dev/null | \
        grep 'zfs\.ko' >/dev/null; then
        log "refusing to build UKI: $initramfs does not contain zfs.ko"
        return 1
    fi

    # Remove a stale build artifact before creating a fresh one.
    rm -f "$build_path" "$build_path.tmp"

    if ! dracut --force --hostonly --kver "$kver" --uefi \
        --kernel-cmdline "$(cat "$CMDLINE_FILE")" "$build_path"; then
        rm -f "$build_path" "$build_path.tmp"
        return 1
    fi
    if ! verify_uki "$build_path"; then
        log "refusing to install an invalid UKI: $build_path"
        rm -f "$build_path"
        return 1
    fi

    # Copy to a temporary name on the ESP first; .efi.new is ignored by
    # systemd-boot, and mv within the same FAT filesystem is atomic.
    local tmp_uki="${UKI_PATH}.new"
    rm -f "$tmp_uki"
    if ! install -Dm644 "$build_path" "$tmp_uki"; then
        log "warning: could not copy the verified UKI to $tmp_uki"
        rm -f "$build_path" "$tmp_uki"
        return 1
    fi
    if ! mv -f "$tmp_uki" "$UKI_PATH"; then
        log "warning: could not install the verified UKI to $UKI_PATH"
        rm -f "$build_path" "$tmp_uki"
        return 1
    fi
    rm -f "$build_path"

    [ -s "$UKI_PATH" ]
}

verify_uki() {
    local uki="${1:-$UKI_PATH}"
    local section tmp expected

    for section in .linux .initrd .cmdline; do
        objdump -h "$uki" 2>/dev/null | grep -F "$section" >/dev/null || return 1
    done

    # A UKI lives on the unencrypted ESP: never embed the ZFS passphrase.
    if lsinitrd "$uki" 2>/dev/null | \
        grep -E '(^|[[:space:]/])etc/zfs/zroot\.key$' >/dev/null; then
        log "refusing to keep a UKI that contains /etc/zfs/zroot.key"
        return 1
    fi
    if ! lsinitrd "$uki" 2>/dev/null | grep 'zfs\.ko' >/dev/null; then
        log "refusing to keep a UKI without zfs.ko"
        return 1
    fi

    tmp="$(mktemp)" || return 1
    if ! objcopy --dump-section ".cmdline=$tmp" "$uki" 2>/dev/null; then
        rm -f "$tmp"
        return 1
    fi

    expected="$(sed 's/^[[:space:]]*//; s/[[:space:]]*$//' "$CMDLINE_FILE")"
    if ! tr -d '\0' < "$tmp" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | grep -Fqx "$expected"; then
        rm -f "$tmp"
        return 1
    fi

    rm -f "$tmp"
    return 0
}

sign_file() {
    local file="$1"

    if ! command -v sbctl >/dev/null 2>&1; then
        log "warning: sbctl not found; leaving $file UNSIGNED on the ESP"
        return 0
    fi
    if [ ! -f /var/lib/sbctl/keys/db/db.key ]; then
        log "warning: no sbctl db key; leaving $file UNSIGNED on the ESP"
        return 0
    fi
    [ -f "$file" ] || return 0

    if ! sbctl sign -s "$file" >/dev/null 2>&1; then
        log "warning: sbctl could not sign $file"
    fi
}

main() {
    local targets
    targets="$(read_targets || true)"

    if ! command -v dracut >/dev/null 2>&1; then
        log "dracut not found, skipping initramfs/UKI regeneration"
        exit 0
    fi

    if ! command -v zfs >/dev/null 2>&1; then
        # Hook is meant for ZFS systems; silently skip elsewhere.
        exit 0
    fi

    local kver
    kver="$(kernel_version || true)"

    if [ -z "$kver" ] || [ ! -d "/usr/lib/modules/$kver" ]; then
        log "warning: cannot determine the installed $KERNEL_FLAVOR kernel version"
        exit 0
    fi

    # Always rebuild the traditional initramfs: it lives on the ZFS root and is
    # what the ZFSBootMenu recovery entry uses. This must not depend on the ESP
    # being mountable.
    local initramfs="/boot/initramfs-${KERNEL_FLAVOR}.img"
    if dracut --force --hostonly --kver "$kver" "$initramfs" >/dev/null 2>&1; then
        if lsinitrd "$initramfs" 2>/dev/null | grep 'zfs\.ko' >/dev/null; then
            log "initramfs regenerated for $kver"
        else
            log "warning: $initramfs does not contain zfs.ko"
        fi
        if lsinitrd "$initramfs" 2>/dev/null | \
            grep -E '(^|[[:space:]/])etc/zfs/zroot\.key$' >/dev/null; then
            log "warning: $initramfs contains /etc/zfs/zroot.key; UKI rebuild will be refused"
        fi
    else
        log "warning: dracut initramfs regeneration failed for $kver"
    fi

    # The UKI and systemd-boot live on the ESP. If it cannot be mounted, leave
    # the existing signed UKI/systemd-boot in place and keep the fresh
    # initramfs for the ZFSBootMenu fallback.
    if ! mount_esp; then
        log "warning: cannot mount $ESP_PATH, skipping UKI and systemd-boot refresh"
        exit 0
    fi

    # A systemd update replaces systemd-boot on the ESP; reinstall and re-sign
    # both copies so Secure Boot keeps working.
    if printf '%s\n' "$targets" | grep -qx 'systemd'; then
        if command -v bootctl >/dev/null 2>&1; then
            # Keep the automatic, unsigned bootloader updater disabled; this
            # hook installs and signs systemd-boot instead.
            systemctl disable systemd-boot-update.service >/dev/null 2>&1 || true
            if ! bootctl --esp-path="$ESP_PATH" --variables=no install >/dev/null 2>&1; then
                log "warning: bootctl install failed after systemd update"
            fi
            sign_file "$ESP_PATH/EFI/systemd/systemd-bootx64.efi"
            sign_file "$ESP_PATH/EFI/BOOT/BOOTX64.EFI"
        fi
    fi

    if build_uki "$kver"; then
        sign_file "$UKI_PATH"
        log "UKI rebuilt for $kver: $UKI_PATH"
    else
        log "warning: UKI rebuild failed for $kver"
    fi

    if [ -n "$targets" ]; then
        log "processed transaction targets: $(echo "$targets" | tr '\n' ' ')"
    fi

    exit 0
}

main "$@"
