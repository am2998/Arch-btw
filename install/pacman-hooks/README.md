# Pacman hooks: ZFS snapshots + dracut kernel refresh

These files provide:
- ZFS snapshot creation *before* every `pacman` install/upgrade transaction.
- dracut initramfs regeneration *after* kernel upgrades.

## What it does

- Pacman hook (PreTransaction) for `Install` and `Upgrade`
- Best-effort snapshot script (it will not block `pacman` if snapshot creation fails)
- **Automatic cleanup** of old snapshots to prevent disk space issues
- Snapshots of:
  - dataset mounted at `/`
  - dataset mounted at `/home`
- Pacman hook (PostTransaction) on kernel package upgrades (`linux`, `linux-lts`, `linux-zen`, ...)
- Best-effort `dracut --force --regenerate-all` execution for updated kernels

## Installation (manual)

- Copy the hook file to `/etc/pacman.d/hooks/`
- Copy the script to `/usr/local/sbin/zfs-pacman-snapshot` and make it executable
- Copy the dracut hook/script:
  - `60-zfs-dracut-post.hook` -> `/etc/pacman.d/hooks/`
  - `zfs-dracut-kernel-refresh.sh` -> `/usr/local/sbin/zfs-dracut-kernel-refresh`

## Configuration

### Automatic cleanup
By default, the script keeps the latest **3 snapshots** per dataset. You can configure this by setting the environment variable:

```bash
export ZFS_PACMAN_MAX_SNAPSHOTS=10  # Keep 10 snapshots instead of 3
```

Or create a systemd environment file at `/etc/environment.d/zfs-pacman.conf`:
```
ZFS_PACMAN_MAX_SNAPSHOTS=15
```

## Temporary disable

- If the file `/etc/zfs-pacman-snapshot.disable` exists, the script does nothing.
- If the file `/etc/zfs-dracut-kernel-refresh.disable` exists, dracut regeneration is skipped.

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

# Check dracut hook logs
journalctl -t zfs-dracut-kernel-refresh -n 50 --no-pager
```
