# Arch-btw

Experimental Arch Linux install assets.

## Warning

These scripts were created for personal use and published only as reference; I assume no responsibility for any damage or data loss.

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
