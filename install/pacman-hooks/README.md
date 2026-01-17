# Pacman hook: ZFS snapshots

These files create a ZFS snapshot *before* every `pacman` transaction that installs or upgrades packages.

## What it does

- Pacman hook (PreTransaction) for `Install` and `Upgrade`
- Best-effort snapshot script (it will not block `pacman` if snapshot creation fails)
- **Automatic cleanup** of old snapshots to prevent disk space issues
- Snapshots of:
  - dataset mounted at `/`
  - dataset mounted at `/home`

## Installation (manual)

- Copy the hook file to `/etc/pacman.d/hooks/`
- Copy the script to `/usr/local/sbin/zfs-pacman-snapshot` and make it executable
- Optionally copy `zfs-cleanup-snapshots.sh` to `/usr/local/sbin/` for manual cleanup

## Configuration

### Automatic cleanup
By default, the script keeps the latest **10 snapshots** per dataset. You can configure this by setting the environment variable:

```bash
export ZFS_PACMAN_MAX_SNAPSHOTS=15  # Keep 15 snapshots instead of 10
```

Or create a systemd environment file at `/etc/environment.d/zfs-pacman.conf`:
```
ZFS_PACMAN_MAX_SNAPSHOTS=15
```

## Temporary disable

- If the file `/etc/zfs-pacman-snapshot.disable` exists, the script does nothing.

## Snapshot name

Formato: `pacman-<dd-mm-yy-HHMMSS>-<hash>`

The hash is derived from the targets list that pacman passes to the hook (when available).

## Monitoring

Check your snapshots:
```bash
# List all pacman snapshots
zfs list -t snapshot | grep pacman

# Check disk usage
zfs list -o space
```
