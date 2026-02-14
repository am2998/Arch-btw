# Arch-btw

![Arch Linux Logo](assets/Archlinux-logo-standard-version.png)

Experimental Arch Linux ZFS installation ISO/script.

## Credits

The GitHub workflow used to generate the ISO image builds upon the work by r-maerz:
- https://github.com/r-maerz/archlinux-lts-zfs

## Warning

The script is created for personal use and published only as reference; I assume no responsibility for any damage or data loss.


## Quick Start (using ISO)

1. Download latest ISO + checksum from Releases:
```bash
# Replace with the actual Release asset URLs
curl -L -o archlinux-lts-zfs-x86_64.iso <ISO_URL>
curl -L -o archlinux-lts-zfs-x86_64.iso.sha256 <SHA_URL>
```

2. Verify:
```bash
sha256sum -c archlinux-lts-zfs-*-x86_64.iso.sha256
```

3. Write USB (replace `/dev/sdX`):
```bash
sudo dd if=archlinux-lts-zfs-*-x86_64.iso of=/dev/sdX bs=4M status=progress conv=fsync
sync
```

4. Boot USB and run installer:
```bash
chmod +x /root/archzfs.sh
/root/archzfs.sh
```

## Installation Methods

There are three ways to install Arch Linux with ZFS using this repository:

1. **Via Script**: Run the `archzfs.sh` script directly on an existing Arch Linux system. This assumes you have a compatible environment set up.

2. **Via Manual Commands**: Copy the commands from the manual section at the bottom of the `archzfs.sh` script file and execute them manually step by step. This gives you full control over each installation step.

3. **Via ISO (Recommended)**: Download the pre-built ISO from the Releases section, which includes the script and a live environment ready for installation.


## Legacy scripts

This repository also includes a backup directory containing legacy scripts unrelated to the ZFS installation. These scripts are no longer maintained, since the archinstall tool included in the official Arch Linux ISO now covers most of their functionality.


## Script Implementation Details

The following details reflect how `src/scripts/archzfs.sh` configures the system.

#### ZFS Structure + Encryption ####
- Disk layout: GPT with a 1 GiB EFI System Partition (ESP) and the rest for ZFS.
- Pool: `zroot` on the second partition with `ashift=12`, `compression=lz4`, `atime=off`, `xattr=sa`, `autotrim=on`, `canmount=off`, `mountpoint=none`.
- Datasets created: `zroot/ROOT` (mountpoint `none`) and `zroot/ROOT/default` (mountpoint `/`, `canmount=noauto`).
- Optional datasets (commented in script): `zroot/data` and `zroot/data/home` (mountpoint `/home`).
- Encryption: `aes-256-gcm` with a passphrase. A temporary key file in `/tmp` is used during pool creation, then a persistent key file is written to `/etc/zfs/zroot.key`. The pool - - - keylocation is set to `file:///etc/zfs/zroot.key` so ZFS can unlock after ZFSBootMenu has prompted for the passphrase.

#### ZRAM ####
- Service: `zram-generator` creates `zram0`.
- Size: `min(ram, 32768)`.
- Compression: `zstd`.
- VM tuning for zram-backed swap: `vm.swappiness=180`, `vm.watermark_boost_factor=0`, `vm.watermark_scale_factor=125`, `vm.page-cluster=0`.

#### Secure Boot ####
- Keys: `sbctl` creates PK/KEK/db keys if missing.
- Enrollment: only if firmware is in Setup Mode.
- Signing: `/efi/EFI/zbm/zfsbootmenu.EFI`.

#### Dracut ####
- Config: `/etc/dracut.conf.d/99-zfs.conf`.
- Modules and items: adds `zfs` module and includes `/etc/zfs/zroot.key`.
- Initramfs: host-only for `linux-lts`, compressed with `zstd`.

#### Desktop Environment ####
- Default: COSMIC plus selected applications. A ZFS snapshot named `zroot/ROOT/default@base` is created first, so you can roll back and choose a different DE or app set if desired.

#### Audio ####
- Audio stack: PipeWire with WirePlumber session manager.
- Packages installed: `wireplumber`, `pipewire-pulse`, `pipewire-alsa`, `pavucontrol-qt`, `alsa-utils`.

#### NVIDIA Drivers ####
- Driver path in script: proprietary NVIDIA Open kernel module variant for LTS kernel.
- Packages installed: `nvidia-open-lts`, `nvidia-settings`, `nvidia-utils`, `opencl-nvidia`, `libxnvctrl`, `egl-wayland`.

## Hooks and Zrepl

### Pacman Hooks (`src/pacman-hooks`)

Provides pacman hooks for:
- creating pre-transaction ZFS snapshots (`pacman-*`)
- refreshing dracut artifacts after kernel/ZFS-relevant updates

Install:

```bash
sudo install -Dm755 src/pacman-hooks/zfs-pacman-snapshot.sh /usr/local/bin/zfs-pacman-snapshot.sh
sudo install -Dm644 src/pacman-hooks/50-zfs-snapshot-pre.hook /etc/pacman.d/hooks/50-zfs-snapshot-pre.hook
sudo install -Dm755 src/pacman-hooks/zfs-dracut-kernel-refresh.sh /usr/local/bin/zfs-dracut-kernel-refresh.sh
sudo install -Dm644 src/pacman-hooks/60-zfs-dracut-post.hook /etc/pacman.d/hooks/60-zfs-dracut-post.hook
```

### Zrepl (`src/zrepl`)

`src/zrepl` contains a local push-to-disk zrepl setup:
- source: auto-detected dataset mounted on `/` (or `--source-dataset` override)
- destination: `backup/zrepl/sink`
- schedule: hourly snapshot + replication
- pruning: retention grid for `zrepl_*`, while keeping `base` and `pacman-*`

Quick start:

```bash
cd src/zrepl
./scripts/bootstrap-zrepl-local-backup.sh --source-pool zroot --source-dataset zroot/ROOT/default
sudo install -m 0644 zrepl.yml /etc/zrepl/zrepl.yml
sudo zrepl configcheck --config /etc/zrepl/zrepl.yml
sudo systemctl restart zrepl
sudo zrepl signal wakeup backup_hourly
```

If the backup pool does not exist yet and must be created on `/dev/sdc`:

```bash
./scripts/bootstrap-zrepl-local-backup.sh --source-pool zroot --source-dataset zroot/ROOT/default --backup-pool backup --create-backup-pool --apply
```