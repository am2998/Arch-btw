#!/bin/bash

# Pacman hook helper: create ZFS snapshots before a transaction.
# Designed to be safe in hooks: it never blocks pacman on snapshot failures.

set -euo pipefail

DISABLE_SENTINEL="/etc/zfs-pacman-snapshot.disable"
LOCK_FILE="/run/lock/zfs-pacman-snapshot.lock"
MAX_SNAPSHOTS="${ZFS_PACMAN_MAX_SNAPSHOTS:-3}"  # Keep max 3 snapshots by default

log() {
    if command -v logger >/dev/null 2>&1; then
        logger -t zfs-pacman-snapshot -- "$*"
    else
        echo "zfs-pacman-snapshot: $*" >&2
    fi
}

sanitize() {
    # Allow only characters valid in ZFS snapshot names.
    # Conservative set: alnum, underscore, dash, dot, colon
    tr -cd 'A-Za-z0-9_.:-' | tr '[:upper:]' '[:lower:]'
}

read_targets() {
    local line
    local targets=()

    # When NeedsTargets is set, pacman passes one target per line on stdin.
    while IFS= read -r line; do
        [ -n "$line" ] && targets+=("$line")
    done

    printf '%s\n' "${targets[@]:-}"
}

get_zfs_source_for_mount() {
    local mountpoint="$1"

    # findmnt returns "zroot/ROOT/default" for ZFS mounts; empty if not mounted.
    if ! command -v findmnt >/dev/null 2>&1; then
        return 0
    fi

    findmnt -n -o SOURCE --target "$mountpoint" 2>/dev/null || true
}

is_zfs_dataset() {
    local ds="$1"
    [ -n "$ds" ] || return 1
    command -v zfs >/dev/null 2>&1 || return 1
    zfs list -H -o name "$ds" >/dev/null 2>&1
}

cleanup_old_snapshots() {
    local dataset="$1"
    local max_snapshots="${2:-3}"  # Default: keep 3 snapshots
    
    if ! is_zfs_dataset "$dataset"; then
        return 0
    fi
    
    # Get pacman snapshots sorted by creation time (oldest first)
    local snapshots
    snapshots="$(zfs list -H -t snapshot -o name -S creation "$dataset" 2>/dev/null | grep "@pacman-" || true)"
    
    if [ -z "$snapshots" ]; then
        return 0
    fi
    
    local count=0
    local to_delete=()
    
    # Count snapshots and mark old ones for deletion
    while IFS= read -r snap; do
        count=$((count + 1))
        if [ "$count" -gt "$max_snapshots" ]; then
            to_delete+=("$snap")
        fi
    done <<< "$snapshots"
    
    # Delete old snapshots
    for snap in "${to_delete[@]}"; do
        if zfs destroy "$snap" >/dev/null 2>&1; then
            log "old snapshot deleted: $snap"
        else
            log "WARNING: failed to delete old snapshot: $snap"
        fi
    done
}

snapshot_dataset() {
    local dataset="$1"
    local snapname="$2"

    if ! is_zfs_dataset "$dataset"; then
        return 0
    fi

    if zfs snapshot "${dataset}@${snapname}" >/dev/null 2>&1; then
        log "snapshot created: ${dataset}@${snapname}"
        # Clean up old snapshots after creating new one
        cleanup_old_snapshots "$dataset" "$MAX_SNAPSHOTS"
    else
        log "WARNING: snapshot failed: ${dataset}@${snapname}"
    fi
}

main() {
    if [ -e "$DISABLE_SENTINEL" ]; then
        log "disabled via $DISABLE_SENTINEL"
        exit 0
    fi

    if ! command -v zfs >/dev/null 2>&1; then
        # Not a ZFS system; silently do nothing.
        exit 0
    fi

    local root_ds
    root_ds="$(get_zfs_source_for_mount /)"

    if ! is_zfs_dataset "$root_ds"; then
        # Root is not ZFS; nothing to do.
        exit 0
    fi

    local home_ds
    home_ds="$(get_zfs_source_for_mount /home)"

    local targets targets_hash
    targets="$(read_targets || true)"

    if [ -n "$targets" ] && command -v sha256sum >/dev/null 2>&1; then
        targets_hash="$(printf '%s\n' "$targets" \
            | sha256sum \
            | awk '{print $1}' \
            | cut -c1-5)"
    else
        targets_hash="no-targets"
    fi

    local ts snapname
    ts="$(TZ=Europe/Rome date +%d-%m-%y-%H%M%S)"
    snapname="pacman-${ts}-${targets_hash}"
    snapname="$(printf '%s' "$snapname" | sanitize)"

    # Best-effort locking (avoid overlapping hooks).
    if command -v flock >/dev/null 2>&1; then
        mkdir -p "$(dirname "$LOCK_FILE")" 2>/dev/null || true

        # Open lock file on FD 9
        exec 9>"$LOCK_FILE" || true

        # Non-blocking lock; if already locked, silently skip
        flock -n 9 || exit 0
    fi

    snapshot_dataset "$root_ds" "$snapname"
    snapshot_dataset "$home_ds" "$snapname"

    exit 0
}

main "$@"
