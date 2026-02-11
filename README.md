# Arch-btw

Personal repository with scripts and hooks for experimental Arch Linux installations.

It contains:
- automated installation scripts for different setups (Btrfs/LUKS/LVM, EXT4/EFISTUB, ZFS/ZFSBootMenu)
- `pacman` hooks for pre-transaction ZFS snapshots

## Project Status

This project is intended for personal/lab use. These scripts are powerful and **destructive**: they erase partitions and rewrite system configuration.

Use them only if you fully understand what they do and after creating complete backups.

## Repository Structure

```text
.
├── install
│   ├── pacman-hooks
│   │   ├── 50-zfs-snapshot-pre.hook
│   │   ├── 60-zfs-dracut-post.hook
│   │   ├── zfs-dracut-kernel-refresh.sh
│   │   ├── zfs-pacman-snapshot.sh
│   │   └── README.md
│   └── scripts
│       ├── btrfs+luks+lvm+systemdboot.sh
│       ├── ext4+efistub.sh
│       └── zfs-zfsbootmenu.sh
├── LICENSE
└── README.md
```

## General Prerequisites

- booted from Arch Linux live ISO
- active internet connection
- root privileges
- UEFI available
- dedicated target disk (scripts wipe data)

Recommended checks before running:

```bash
lsblk
ip a
ping -c 3 archlinux.org
```

## Installation Scripts

### 1) `install/scripts/btrfs+luks+lvm+systemdboot.sh`

Target setup:
- GPT + EFI (1 GiB)
- LUKS2 on the system partition
- LVM (`sys/root`)
- Btrfs with `@`, `@home`, `@var` subvolumes
- `systemd-boot` bootloader
- KDE-oriented desktop package set

What it does (summary):
- detects disk automatically (`/dev/nvme0n1` or `/dev/sda`)
- removes existing VG/PV and partition table
- creates and configures LUKS + LVM + Btrfs
- installs base system with `pacstrap`
- configures locale/timezone/hostname/network/sudo
- enables multilib, zram, mkinitcpio, systemd-boot

Run:

```bash
chmod +x install/scripts/btrfs+luks+lvm+systemdboot.sh
./install/scripts/btrfs+luks+lvm+systemdboot.sh
```

Notes:
- uses `Europe/Rome` timezone
- configures reflector mirrors for Italy
- interactive script (user/password/hostname/LUKS passphrase)

### 2) `install/scripts/ext4+efistub.sh`

Target setup:
- GPT + EFI (1 GiB)
- EXT4 root filesystem
- EFISTUB boot (with `linux-zen` + booster)
- minimal base install with audio/NVIDIA components

What it does (summary):
- partitions and formats disk
- installs base system with `linux-zen`
- configures zram, locale, hostname, mirrors, multilib
- creates UEFI entry via `efibootmgr`
- installs audio components and NVIDIA drivers

Run:

```bash
chmod +x install/scripts/ext4+efistub.sh
./install/scripts/ext4+efistub.sh
```

Important notes:
- interactive script (root password + hostname)
- prompts for disk selection before wiping
- installs `linux-zen` + `booster` and creates an EFISTUB boot entry
- does not create a non-root user account

### 3) `install/scripts/zfs-zfsbootmenu.sh`

Target setup:
- GPT + EFI
- ZFS pool `zroot`
- encrypted root dataset (`zroot/ROOT/default`)
- ZFSBootMenu bootloader

What it does (summary):
- interactive disk selection
- disk wipe and ZFS pool/dataset creation
- base install (`linux-lts`) and system configuration
- ZFS repo/package setup + dracut configuration for ZFS boot
- ZFSBootMenu UEFI entry installation
- Secure Boot key handling/signing via `sbctl`
- creates snapshot `zroot/ROOT/default@pre-cosmic-wayland`
- installs COSMIC session and enables `cosmic-greeter.service`

Run:

```bash
chmod +x install/scripts/zfs-zfsbootmenu.sh
./install/scripts/zfs-zfsbootmenu.sh
```

Useful characteristics:
- `set -euo pipefail`
- helper functions + validations (hostname/password)
- automatic cleanup on error (`trap`)

## ZFS Pacman Hooks

Folder: `install/pacman-hooks`

Components:
- `50-zfs-snapshot-pre.hook`: PreTransaction hook for `Install` and `Upgrade`
- `zfs-pacman-snapshot.sh`: creates pre-update snapshots and handles retention cleanup
- `60-zfs-dracut-post.hook`: PostTransaction hook for kernel package updates
- `zfs-dracut-kernel-refresh.sh`: regenerates dracut initramfs after kernel upgrades

Behavior:
- snapshots dataset mounted at `/`
- snapshots dataset mounted at `/home`
- naming format: `pacman-<dd-mm-yy-HHMMSS>-<hash>`
- default retention: 3 snapshots per dataset (`ZFS_PACMAN_MAX_SNAPSHOTS`)
- triggers dracut after kernel updates (`linux`, `linux-lts`, `linux-zen`, `linux-hardened`, ...)

Manual installation:

```bash
sudo install -Dm644 install/pacman-hooks/50-zfs-snapshot-pre.hook /etc/pacman.d/hooks/50-zfs-snapshot-pre.hook
sudo install -Dm755 install/pacman-hooks/zfs-pacman-snapshot.sh /usr/local/sbin/zfs-pacman-snapshot
sudo install -Dm644 install/pacman-hooks/60-zfs-dracut-post.hook /etc/pacman.d/hooks/60-zfs-dracut-post.hook
sudo install -Dm755 install/pacman-hooks/zfs-dracut-kernel-refresh.sh /usr/local/sbin/zfs-dracut-kernel-refresh
```

Retention configuration (example: keep 10 snapshots):

```bash
echo 'ZFS_PACMAN_MAX_SNAPSHOTS=10' | sudo tee /etc/environment.d/zfs-pacman.conf
```

Temporary disable:

```bash
sudo touch /etc/zfs-pacman-snapshot.disable
# re-enable
sudo rm -f /etc/zfs-pacman-snapshot.disable

# disable dracut regeneration hook
sudo touch /etc/zfs-dracut-kernel-refresh.disable
# re-enable
sudo rm -f /etc/zfs-dracut-kernel-refresh.disable
```

Verify snapshots:

```bash
zfs list -t snapshot | grep pacman
journalctl -t zfs-dracut-kernel-refresh -n 50 --no-pager
```

## Safety and Risks

- scripts use `wipefs`, `fdisk`/`parted`, `mkfs`, `vgremove/pvremove` and can irreversibly erase data
- some choices are hardcoded (timezone, mirror country, package selection)
- not suitable for production without deep review

## Suggested Customization

Before usage, review at least:
- target disk and partition naming
- timezone and locale
- default installed packages
- boot configuration (microcode, kernel parameters)
- enabled/disabled services

## Quick Troubleshooting

- `arch-chroot` fails: check mounts for `/mnt`, `/mnt/boot`, or `/mnt/efi`
- boot entry missing in UEFI: verify with `efibootmgr -v`
- ZFS pool not imported: check `zpool import`, `zpool status`, `zfs mount -a`
- pacman hook not running: check hook path in `/etc/pacman.d/hooks` and script permissions in `/usr/local/sbin`

## License

This project is released under Apache 2.0. See `LICENSE`.

## Disclaimer

Experimental repository. The author is not responsible for data loss, downtime, or damage resulting from script usage.
