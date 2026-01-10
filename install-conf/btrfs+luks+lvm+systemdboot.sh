#!/bin/bash

# LUKS + LVM + BTRFS + SYSTEMD-BOOT
# KDE

exec > >(tee -a result.log) 2>&1


# --------------------------------------------------------------------------------------------------------------------------
# Prompt for user and system settings                                                                                      
# --------------------------------------------------------------------------------------------------------------------------

get_password() {
    local prompt=$1
    local password_var
    local password_recheck_var

    while true; do
        echo -n "$prompt: "; read -r -s password_var; echo
        echo -n "Re-enter password: "; read -r -s password_recheck_var; echo
        if [ "$password_var" = "$password_recheck_var" ]; then
            eval "$2='$password_var'"
            break
        else
            echo "Passwords do not match. Please enter a new password."
        fi
    done
}

echo -ne "\n\nEnter the username: "; read -r USER
get_password "Enter the password for user $USER" USERPASS
get_password "Enter the password for user root" ROOTPASS
get_password "Enter LUKS volume password" PASSPHRASE
echo -n "Enter the hostname: "; read -r HOSTNAME


echo -e "\n\n# --------------------------------------------------------------------------------------------------------------------------"
echo -e "# Check if there are existing PV and VG"
echo -e "# --------------------------------------------------------------------------------------------------------------------------\n"

umount -R /mnt 2>/dev/null
VG_NAME=$(vgdisplay -c | cut -d: -f1 | xargs)

if [ -z "$VG_NAME" ]; then
    echo -e "No volume group found. Skipping VG removal."
else
    echo -e "Removing volume group ${VG_NAME} and all associated volumes..."
    yes | vgremove "$VG_NAME" 2>/dev/null
    PV_NAME=$(pvs --noheadings -o pv_name | grep -w "$VG_NAME" | xargs)
    yes | pvremove "$PV_NAME" 2>/dev/null
fi


echo -e "\n\n# --------------------------------------------------------------------------------------------------------------------------"
echo -e "# Cleaning old partition table and partitioning"
echo -e "# --------------------------------------------------------------------------------------------------------------------------\n"

if lsblk | grep nvme &>/dev/null; then
    DISK="/dev/nvme0n1"
    PARTITION_1="p1"
    PARTITION_2="p2"
    echo "NVMe disk detected: $DISK"
elif lsblk | grep sda &>/dev/null; then
    DISK="/dev/sda"
    PARTITION_1="1"
    PARTITION_2="2"
    echo "SATA disk detected: $DISK"
else 
    echo "ERROR: No NVMe or SATA drive found. Exiting."
    exit 1
fi

wipefs -a -f $DISK 

(
echo g           # Create a GPT partition table
echo n           # Create the EFI partition
echo             # Default, 1
echo             # Default
echo +1G         # 1GB for the EFI partition
echo t           # Change partition type to EFI
echo 1           # EFI type
echo n           # Create the system partition
echo             # Default, 2
echo             # Default
echo             # Default, use the rest of the space
echo w           # Write the partition table
) | fdisk $DISK



echo -e "\n\n# --------------------------------------------------------------------------------------------------------------------------"
echo -e "# Create LUKS and LVM for the system partition"
echo -e "# --------------------------------------------------------------------------------------------------------------------------\n"

echo "$PASSPHRASE" | cryptsetup luksFormat ${DISK}${PARTITION_2} \
  --type luks2 \
  --hash sha512 \
  --pbkdf argon2id \
  --iter-time 5000 \
  --cipher aes-xts-plain64 \
  --key-size 256 \
  --sector-size 512 \
  --use-urandom

echo "$PASSPHRASE" | cryptsetup open ${DISK}${PARTITION_2} cryptroot

pvcreate --dataalignment 1m /dev/mapper/cryptroot
vgcreate sys /dev/mapper/cryptroot
yes | lvcreate -l 100%FREE -n root sys


echo -e "\n\n# --------------------------------------------------------------------------------------------------------------------------"
echo -e "# Format and mount partitions"
echo -e "# --------------------------------------------------------------------------------------------------------------------------\n"

mkfs.fat -F32 ${DISK}${PARTITION_1}   
mkfs.btrfs /dev/mapper/sys-root   

mount /dev/mapper/sys-root /mnt
btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@home
btrfs subvolume create /mnt/@var
umount /mnt

mount -o noatime,ssd,compress=zstd,space_cache=v2,subvol=@ /dev/mapper/sys-root /mnt
mkdir -p /mnt/{home,var}
mount -o noatime,ssd,compress=zstd,space_cache=v2,subvol=@home /dev/mapper/sys-root /mnt/home
mount -o noatime,ssd,compress=zstd,space_cache=v2,subvol=@var /dev/mapper/sys-root /mnt/var

mkdir -p /mnt/boot && mount ${DISK}${PARTITION_1} /mnt/boot


echo -e "\n\n# --------------------------------------------------------------------------------------------------------------------------"
echo -e "# Install base system"
echo -e "# --------------------------------------------------------------------------------------------------------------------------\n"

pacstrap /mnt linux base base-devel linux-firmware lvm2 btrfs-progs zram-generator reflector sudo networkmanager amd-ucode


echo -e "\n\n# --------------------------------------------------------------------------------------------------------------------------"
echo -e "# Generate fstab file"
echo -e "# --------------------------------------------------------------------------------------------------------------------------\n"

genfstab -U /mnt >> /mnt/etc/fstab


echo -e "\n\n# --------------------------------------------------------------------------------------------------------------------------"
echo -e "# Chroot into the system and configure"
echo -e "# --------------------------------------------------------------------------------------------------------------------------\n"

arch-chroot /mnt <<EOF


# --------------------------------------------------------------------------------------------------------------------------
# Basic settings
# --------------------------------------------------------------------------------------------------------------------------

echo "$HOSTNAME" > /etc/hostname

localectl set-keymap --no-convert us

ln -sf /usr/share/zoneinfo/Europe/Rome /etc/localtime

hwclock --systohc

timedatectl set-ntp true

sed -i '/^#en_US.UTF-8/s/^#//g' /etc/locale.gen && locale-gen

echo -e "127.0.0.1   localhost\n::1         localhost\n127.0.1.1   $HOSTNAME.localdomain   $HOSTNAME" > /etc/hosts


# --------------------------------------------------------------------------------------------------------------------------
# Create user and set passwords
# --------------------------------------------------------------------------------------------------------------------------

useradd -m $USER
echo "$USER:$USERPASS" | chpasswd
echo "root:$ROOTPASS" | chpasswd


# --------------------------------------------------------------------------------------------------------------------------
# Configure sudoers file
# --------------------------------------------------------------------------------------------------------------------------

echo -e "\n\n%$USER ALL=(ALL:ALL) ALL" | tee -a /etc/sudoers


# --------------------------------------------------------------------------------------------------------------------------
# Configure mirrors
# --------------------------------------------------------------------------------------------------------------------------

reflector --country "Italy" --latest 10 --sort rate --protocol https --age 7 --save /etc/pacman.d/mirrorlist


# --------------------------------------------------------------------------------------------------------------------------
# Enable Multilib repository
# --------------------------------------------------------------------------------------------------------------------------

sed -i '/\[multilib\]/,/Include/ s/^#//' /etc/pacman.conf
pacman -Syy


# --------------------------------------------------------------------------------------------------------------------------
# Configure ZRAM
# --------------------------------------------------------------------------------------------------------------------------

bash -c 'cat > /etc/systemd/zram-generator.conf <<EOF
[zram0]
zram-size = min(ram, 32768)
compression-algorithm = zstd
EOF'

echo "vm.swappiness = 180" >> /etc/sysctl.d/99-vm-zram-parameters.conf
echo "vm.watermark_boost_factor = 0" >> /etc/sysctl.d/99-vm-zram-parameters.conf
echo "vm.watermark_scale_factor = 125" >> /etc/sysctl.d/99-vm-zram-parameters.conf
echo "vm.page-cluster = 0" >> /etc/sysctl.d/99-vm-zram-parameters.conf

sysctl --system


# -----------------------------------------------a---------------------------------------------------------------------------
# Install systemd-boot
# --------------------------------------------------------------------------------------------------------------------------

bootctl --path=/boot install

touch /boot/loader/entries/arch.conf

echo "title Arch Linux" > /boot/loader/entries/arch.conf
echo "linux vmlinuz-linux" >> /boot/loader/entries/arch.conf
echo "initrd amd-ucode.img" >> /boot/loader/entries/arch.conf
echo "initrd initramfs-linux.img" >> /boot/loader/entries/arch.conf
echo "options cryptdevice=UUID=$(blkid -s UUID -o value ${DISK}${PARTITION_2}):cryptroot root=/dev/mapper/sys-root rootfstype=btrfs rootflags=subvol=@ rw quiet splash" >> /boot/loader/entries/arch.conf

touch /boot/loader/loader.conf

echo -e "default arch\ntimeout 4\nconsole-mode max\neditor no" > /boot/loader/loader.conf


# --------------------------------------------------------------------------------------------------------------------------
# Configure mkinitcpio
# --------------------------------------------------------------------------------------------------------------------------

sed -i 's/\(filesystems\) \(fsck\)/\1 encrypt lvm2 \2/' /etc/mkinitcpio.conf

mkinitcpio -p linux


# --------------------------------------------------------------------------------------------------------------------------
# Install utilities and applications
# --------------------------------------------------------------------------------------------------------------------------

pacman -S --noconfirm net-tools flatpak firefox konsole dolphin okular kate git man nano vi lite-xl distrobox veracrypt rclone cronie


# --------------------------------------------------------------------------------------------------------------------------
# Install audio components
# --------------------------------------------------------------------------------------------------------------------------

pacman -S --noconfirm pipewire wireplumber pipewire-pulse alsa-plugins alsa-firmware sof-firmware alsa-card-profiles pavucontrol-qt


# --------------------------------------------------------------------------------------------------------------------------
# Install NVIDIA drivers
# --------------------------------------------------------------------------------------------------------------------------

pacman -S --noconfirm nvidia-open nvidia-settings nvidia-utils opencl-nvidia libxnvctrl


# --------------------------------------------------------------------------------------------------------------------------
# Install Plasma and SDDM
# --------------------------------------------------------------------------------------------------------------------------

pacman -S --noconfirm plasma

pacman -Syu --noconfirm sddm 
sed -i 's/^Current=.*$/Current=breeze/' /usr/lib/sddm/sddm.conf.d/default.conf
sed -i '/^\[X11\]/,/\[.*\]/s/^SessionDir=.*$/SessionDir=/' /usr/lib/sddm/sddm.conf.d/default.conf

systemctl enable sddm


# --------------------------------------------------------------------------------------------------------------------------
# Enable services
# --------------------------------------------------------------------------------------------------------------------------

systemctl enable NetworkManager
systemctl enable cronie


EOF


# --------------------------------------------------------------------------------------------------------------------------
# Umount and reboot
# --------------------------------------------------------------------------------------------------------------------------

umount -R /mnt
reboot
