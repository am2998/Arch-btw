#!/bin/bash

# Pacman hook helper: regenerate dracut initramfs after kernel updates.
# Best effort by design: it should not block pacman if dracut fails.

set -euo pipefail

DISABLE_SENTINEL="/etc/zfs-dracut-kernel-refresh.disable"

log() {
    if command -v logger >/dev/null 2>&1; then
        logger -t zfs-dracut-kernel-refresh -- "$*"
    else
        echo "zfs-dracut-kernel-refresh: $*" >&2
    fi
}

read_targets() {
    local line
    local targets=()

    while IFS= read -r line; do
        [ -n "$line" ] && targets+=("$line")
    done

    printf '%s\n' "${targets[@]:-}"
}

main() {
    local targets
    targets="$(read_targets || true)"

    if [ -e "$DISABLE_SENTINEL" ]; then
        log "disabled via $DISABLE_SENTINEL"
        exit 0
    fi

    if ! command -v dracut >/dev/null 2>&1; then
        log "dracut not found, skipping initramfs regeneration"
        exit 0
    fi

    if ! command -v zfs >/dev/null 2>&1; then
        # Hook is meant for ZFS systems; silently skip elsewhere.
        exit 0
    fi

    if dracut --force --regenerate-all >/dev/null 2>&1; then
        if [ -n "$targets" ]; then
            log "dracut initramfs regenerated after kernel transaction: $(echo "$targets" | tr '\n' ' ')"
        else
            log "dracut initramfs regenerated after kernel transaction"
        fi
    else
        log "WARNING: dracut regeneration failed (pacman transaction not blocked)"
    fi

    exit 0
}

main "$@"
