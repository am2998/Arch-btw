# Arch-btw

Experimental Arch Linux ZFS installation ISO/script.

## Credits

This github workflow builds on the work by r-maerz:
- https://github.com/r-maerz/archlinux-lts-zfs

## Warning

The script is created for personal use and published only as reference; I assume no responsibility for any damage or data loss.

## Backup Section

This repository also includes a backup directory containing legacy scripts unrelated to the ZFS installation. These scripts are no longer maintained, since the archinstall tool included in the official Arch Linux ISO now covers most of their functionality.

## Main Installer

- `install/scripts/archzfs.sh`

## Quick Use

1. Download latest ISO + checksum from Releases:

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
