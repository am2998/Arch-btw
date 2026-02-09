#!/bin/bash

# EXT4 + EFISTUB 

exec > >(tee -a result.log) 2>&1


# --------------------------------------------------------------------------------------------------------------------------
# helper functions                                                                                     
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

select_install_disk() {
    local -a disks
    local index
    local selection
    local confirm_disk

    mapfile -t disks < <(lsblk -dpno NAME,TYPE | awk '$2 == "disk" {print $1}')
    [ "${#disks[@]}" -gt 0 ] || error_exit "No disks found."

    echo "Available disks:"
    for index in "${!disks[@]}"; do
        printf "  [%d] %s\n" "$((index + 1))" "${disks[$index]}"
    done

    read -r -p "Select target disk number: " selection
    [[ "$selection" =~ ^[0-9]+$ ]] || error_exit "Invalid selection."
    [ "$selection" -ge 1 ] && [ "$selection" -le "${#disks[@]}" ] || error_exit "Selection out of range."

    DISK="${disks[$((selection - 1))]}"
    if [[ "$DISK" =~ (nvme|mmcblk) ]]; then
        PARTITION_1="p1"
        PARTITION_2="p2"
    else
        PARTITION_1="1"
        PARTITION_2="2"
    fi

    echo "Selected disk: $DISK"
}

# --------------------------------------------------------------------------------------------------------------------------
# Prompt for root password and hostname                                                                                    
# --------------------------------------------------------------------------------------------------------------------------

get_password "Enter the password for user root" ROOTPASS
echo -n "Enter the hostname: "; read -r HOSTNAME


echo -e "\n\n# --------------------------------------------------------------------------------------------------------------------------"
echo -e "# Cleaning old partition table and partitioning"
echo -e "# --------------------------------------------------------------------------------------------------------------------------\n"

select_install_disk

wipefs -a -f "$DISK"

parted "$DISK" --script mklabel gpt
parted "$DISK" --script mkpart ESP fat32 1MiB 1GiB
parted "$DISK" --script set 1 esp on
parted "$DISK" --script mkpart primary 1GiB 100%

echo "Partitions created successfully."

echo -e "\n\n# --------------------------------------------------------------------------------------------------------------------------"
echo -e "# Format and mount partitions"
echo -e "# --------------------------------------------------------------------------------------------------------------------------\n"

mkfs.ext4 ${DISK}${PARTITION_2}
mount ${DISK}${PARTITION_2} /mnt

mkfs.fat -F32 ${DISK}${PARTITION_1}  
mkdir -p /mnt/boot && mount ${DISK}${PARTITION_1} /mnt/boot


echo -e "\n\n# --------------------------------------------------------------------------------------------------------------------------"
echo -e "# Install base system"
echo -e "# --------------------------------------------------------------------------------------------------------------------------\n"

pacstrap /mnt linux-zen linux-zen-headers booster base linux-firmware zram-generator networkmanager amd-ucode efibootmgr


echo -e "\n\n# --------------------------------------------------------------------------------------------------------------------------"
echo -e "# Generate fstab file"
echo -e "# --------------------------------------------------------------------------------------------------------------------------\n"

genfstab -U /mnt > /mnt/etc/fstab
echo -e "\nFstab file generated:\n"
cat /mnt/etc/fstab


echo -e "\n\n# --------------------------------------------------------------------------------------------------------------------------"
echo -e "# Chroot into the system and configure"
echo -e "# --------------------------------------------------------------------------------------------------------------------------\n"

env DISK=$DISK arch-chroot /mnt <<EOF

echo -e "in chroot...\n\n"

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


# --------------------------------------------------------------------------------------------------------------------------
# EFI Stub with Booster
# --------------------------------------------------------------------------------------------------------------------------

efibootmgr --create --disk $DISK --part 1 --label "Arch Linux" --loader /vmlinuz-linux-zen --unicode "root=UUID=$(blkid -s UUID -o value ${DISK}${PARTITION_2}) rw initrd=\amd-ucode.img initrd=\booster-linux-zen.img"

# --------------------------------------------------------------------------------------------------------------------------
# Install audio components
# --------------------------------------------------------------------------------------------------------------------------

pacman -S --needed --noconfirm wireplumber pipewire-pulse pipewire-alsa pavucontrol-qt alsa-utils


# --------------------------------------------------------------------------------------------------------------------------
# Install NVIDIA drivers
# --------------------------------------------------------------------------------------------------------------------------

pacman -S --needed --noconfirm nvidia-open nvidia-settings nvidia-utils opencl-nvidia libxnvctrl egl-wayland

# --------------------------------------------------------------------------------------------------------------------------
# System setup
# --------------------------------------------------------------------------------------------------------------------------

echo "$HOSTNAME" > /etc/hostname

localectl set-keymap --no-convert us

ln -sf /usr/share/zoneinfo/Europe/Rome /etc/localtime

hwclock --systohc

timedatectl set-ntp true

sed -i '/^#en_US.UTF-8/s/^#//g' /etc/locale.gen && locale-gen

echo -e "127.0.0.1   localhost\n::1         localhost\n127.0.1.1   $HOSTNAME.localdomain   $HOSTNAME" > /etc/hosts


# --------------------------------------------------------------------------------------------------------------------------
# Set Root passwords
# --------------------------------------------------------------------------------------------------------------------------

echo "root:$ROOTPASS" | chpasswd

# --------------------------------------------------------------------------------------------------------------------------
# Manage services
# --------------------------------------------------------------------------------------------------------------------------

systemctl enable NetworkManager
systemctl mask NetworkManager-wait-online.service
systemctl mask ldconfig.service
systemctl mask geoclue


EOF


# --------------------------------------------------------------------------------------------------------------------------
# Umount and reboot
# --------------------------------------------------------------------------------------------------------------------------

umount -R /mnt
reboot
