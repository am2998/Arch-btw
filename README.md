# Arch-btw

![Arch Linux Logo](assets/Archlinux-logo-standard-version.png)

Experimental Arch Linux ZFS installation ISO/script.

## Credits

This github workflow builds on the work by r-maerz:
- https://github.com/r-maerz/archlinux-lts-zfs

## Warning

The script is created for personal use and published only as reference; I assume no responsibility for any damage or data loss.

## Backup Section

This repository also includes a backup directory containing legacy scripts unrelated to the ZFS installation. These scripts are no longer maintained, since the archinstall tool included in the official Arch Linux ISO now covers most of their functionality.

## Installation Methods

There are three ways to install Arch Linux with ZFS using this repository:

1. **Via Script**: Run the `archzfs.sh` script directly on an existing Arch Linux system. This assumes you have a compatible environment set up.

2. **Via Manual Commands**: Copy the commands from the manual section at the bottom of the `archzfs.sh` script file and execute them manually step by step. This gives you full control over each installation step.

3. **Via ISO (Recommended)**: Download the pre-built ISO from the Releases section, which includes the script and a live environment ready for installation.

<br>

**Note**: By default, the script installs the Cosmic desktop environment along with some applications. A ZFS snapshot is created first, allowing you to rollback and choose alternative desktop environments or applications if desired.

## Quick Start (using ISO)

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
