# Pacman hooks: ZFS snapshots + dracut/UKI refresh

These files provide:
- ZFS snapshot creation *before* every `pacman` install/upgrade transaction.
- dracut initramfs + systemd-boot UKI regeneration *after* kernel, ZFS, dracut or systemd upgrades.
- Automatic re-signing of the boot chain with `sbctl`.

## What it does

- Pacman hook (PreTransaction) for `Install` and `Upgrade`.
- Best-effort snapshot script (it will not block `pacman` if snapshot creation fails).
- **Automatic cleanup** of old snapshots to prevent disk space issues.
- Snapshots of:
  - the dataset mounted at `/`
  - the dataset mounted at `/home` (when it is a ZFS dataset)
- Pacman hook (PostTransaction) on `linux-lts`, `zfs-dkms`, `zfs-utils`, `dracut` and `systemd`.
- Best-effort rebuild of `/boot/initramfs-linux-lts.img` and `/efi/EFI/Linux/arch-linux-lts.efi`.
- Re-signs the UKI, and after a `systemd` update also reinstalls/re-signs systemd-boot.
- If `sbctl` or its stored keys are unavailable, the target file is left unsigned and a warning is logged (this alone does not fail the hook).
- Keeps `systemd-boot-update.service` disabled: its unattended `bootctl update` is not signed.
- Mounts `/efi` temporarily when it is not already mounted (useful for manual setups where the ESP is not in `/etc/fstab`).

## Installation (manual)

Install the helper scripts and the hook definitions:

```bash
sudo install -Dm755 src/pacman-hooks/zfs-pacman-snapshot.sh /usr/local/bin/zfs-pacman-snapshot
sudo install -Dm755 src/pacman-hooks/zfs-dracut-kernel-refresh.sh /usr/local/bin/zfs-dracut-kernel-refresh
sudo install -Dm644 src/pacman-hooks/50-zfs-snapshot-pre.hook /etc/pacman.d/hooks/50-zfs-snapshot-pre.hook
sudo install -Dm644 src/pacman-hooks/60-zfs-dracut-post.hook /etc/pacman.d/hooks/60-zfs-dracut-post.hook
```

The installer installs the UKI refresh helper and hook automatically from the
ISO. The `Exec` paths in the `.hook` files must match the installed helper
paths. Both use `/usr/local/bin` (no `.sh` suffix).

## Configuration

### Automatic cleanup

By default, the script keeps the latest **3 snapshots** per dataset. Pacman
hooks do not inherit your shell environment, so configure the limit in
`/etc/zfs-pacman-snapshot.conf`:

```bash
# /etc/zfs-pacman-snapshot.conf
ZFS_PACMAN_MAX_SNAPSHOTS=10
```

The file is sourced by the helper (keep it owned by `root` and mode `0644`).

## Temporary disable

- If the file `/etc/zfs-pacman-snapshot.disable` exists, the snapshot script does nothing.
- If the file `/etc/zfs-dracut-kernel-refresh.disable` exists, dracut regeneration is skipped.

## Snapshot name

Format: `pacman-<YYYYMMDD-HHMMSS>-<hash>`

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
