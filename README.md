# Arch-btw

![Arch Linux Logo](assets/Archlinux-logo-standard-version.png)

Experimental Arch Linux ZFS installation ISO/script.

## Credits

This github workflow builds on the work by r-maerz:
- https://github.com/r-maerz/archlinux-lts-zfs

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

## Warning

The script is created for personal use and published only as reference; I assume no responsibility for any damage or data loss.

## Backup Section

This repository also includes a backup directory containing legacy scripts unrelated to the ZFS installation. These scripts are no longer maintained, since the archinstall tool included in the official Arch Linux ISO now covers most of their functionality.

## Script Implementation Details

The following details reflect how `src/scripts/archzfs.sh` configures the system.

**1) ZFS Structure + Encryption**
Disk layout: GPT with a 1 GiB EFI System Partition (ESP) and the rest for ZFS.
Pool: `zroot` on the second partition with `ashift=12`, `compression=lz4`, `atime=off`, `xattr=sa`, `autotrim=on`, `canmount=off`, `mountpoint=none`.
Datasets created: `zroot/ROOT` (mountpoint `none`) and `zroot/ROOT/default` (mountpoint `/`, `canmount=noauto`).
Optional datasets (commented in script): `zroot/data` and `zroot/data/home` (mountpoint `/home`).
Encryption: `aes-256-gcm` with a passphrase. A temporary key file in `/tmp` is used during pool creation, then a persistent key file is written to `/etc/zfs/zroot.key`. The pool keylocation is set to `file:///etc/zfs/zroot.key` so ZFS can unlock after ZFSBootMenu has prompted for the passphrase.

**2) ZRAM**
Service: `zram-generator` creates `zram0`.
Size: `min(ram, 32768)`.
Compression: `zstd`.
VM tuning for zram-backed swap: `vm.swappiness=180`, `vm.watermark_boost_factor=0`, `vm.watermark_scale_factor=125`, `vm.page-cluster=0`.

**3) Secure Boot**
Keys: `sbctl` creates PK/KEK/db keys if missing.
Enrollment: only if firmware is in Setup Mode.
Signing: `/efi/EFI/zbm/zfsbootmenu.EFI`.

**4) Dracut**
Config: `/etc/dracut.conf.d/99-zfs.conf`.
Modules and items: adds `zfs` module and includes `/etc/zfs/zroot.key`.
Initramfs: host-only for `linux-lts`, compressed with `zstd`.

**5) Desktop Environment**
Default: COSMIC plus selected applications. A ZFS snapshot named `zroot/ROOT/default@base` is created first, so you can roll back and choose a different DE or app set if desired.
