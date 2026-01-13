# Pacman hook: ZFS snapshots

These files create a ZFS snapshot *before* every `pacman` transaction that installs or upgrades packages.

## What it does

- Pacman hook (PreTransaction) for `Install` and `Upgrade`
- Best-effort snapshot script (it will not block `pacman` if snapshot creation fails)
- Snapshots of:
  - dataset mounted at `/`
  - dataset mounted at `/home` (if it is ZFS)

## Installation (manual)

- Copy the hook file to `/etc/pacman.d/hooks/`
- Copy the script to `/usr/local/sbin/zfs-pacman-snapshot` and make it executable

## Temporary disable

- If the file `/etc/zfs-pacman-snapshot.disable` exists, the script does nothing.

## Snapshot name

Formato (UTC): `pacman-<pre>-uYYYYmmddTHHMMSSZ-<hash>`

The hash is derived from the targets list that pacman passes to the hook (when available).
