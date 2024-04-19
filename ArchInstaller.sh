#!/bin/bash

: '
The following commandline arguments are needed:

	(first create the partitions e.g. with cfdisk, see SIZES)
1.  The EFI System Partition ($esp). If Dual Boot is desired, the already existing partition has to be specified.
2.  The root (/) partition, this is where all the installed software and the operating system (Arch Linux) is going to be installed.
3.  The home partition (/home). This is where all the user-data e.g. documents and pictures will be placed.

4.  The username that should be used
5.	The name of the computer that should be used
6.  Optional: adding "true" to encrypt the home partition, or anything else if it should not be encrypted.
7.  Optional: when dual-booting with Windows, the existing EFI partition will most likely be too small (due to using systemd-boot). Therefore, a boot partition should be specified.

Example (no dual boot): 	            bash ArchInstall.sh /dev/sda1 /dev/sda2 /dev/sda3 user machine true
Example (Windows dual boot):            bash ArchInstall.sh /dev/sda5 /dev/sda7 /dev/sda8 user machine true /dev/sda6
Example (another Windows dual boot):    bash ArchInstall.sh /dev/sda1 /dev/sda5 /dev/sda6 user machine true /dev/sda4

SIZES:
1. The $esp (FAT32) should be at least 300M when using GRUB and 1G when using systemd-boot (which is the one used here, so 1G is recommended), since it will then also hold
   the initramfs, kernel etc. When dual-booting with windows, the default $esp will be 100M. Then, one could create the boot partition with e.g. 900M (FAT32).
2. The remaining parts of the OS and software are going to be installed in root (/), which should therefore be at least 10G-20G.
3. All the user-data will be stored in /home. Normally, 10G is enough, it depends on the amount of pictures/videos/other large media.
Splitting all the disk-space between the root and home partition depends on the use case. One could split them equally, but
leaving more space for / is recommended, since the software will most likely need more storage than the user-data.
*. A swap partition is not necassary. The script uses zram instead, which will create the swap in RAM as a compressed block device.

General information regarding the bootloader and encryption:

This installation uses systemd-boot instead of GRUB. This is because:
1. systemd-boot is already pre-installed, while GRUB is not
2. systemd-boot may be therefore slightly smaller and faster
3. GRUB often has some vulnerabilities, while systemd-boot does not
4. The only advantage of GRUB would be its advanced features:
	4.1.When dual-booting, GRUB is able to place the kernel/initramfs in the /boot directory of the root partition.
		When using systemd-boot, this has to be a separate partition (missing filesystem drivers for ext4). However, this is only an issue when the $efi partition 
		is too small for all boot files. In case of dual booting with Windows, the default 100M are going to be always too small.
		If one does not want to create a separate boot partition, GRUB should be used for dual-booting instead.
		It should be kept in mind, that if one wants to encrypt the root partition too, a boot partition probably has to be created anyway.
	4.2 Concerning encryption, one has the option to encrypt the home partition using this install-script (which is strongly recommended). There is no support for root encryption. The reasons for this are:
		It decreases OS/CPU performance. Plus, since not much data is really exposed in root (installed software only, plus user names and password hashes in /etc/shadow, which would not be easy to crack because 
		of the strong passwords that are used).
		The only advantage is to prevent others from installing malware when the system is powered off. But then, one would have to deal with bootloader encryption
		(which GRUB supports instead of systemd-boot), /boot on an USB Drive, detached encryption headers and so on. In the end, if this is the needed thread model, 
		TailsOS or QubesOS might be better suited than Arch anyway.
		The availible home encryption is therefore meant only to prevent data access of others when e.g. a laptop is lost. In case the laptop is returend back or found, it would be the easiest to not start
		the OS directly and therefore setup a new OS, which should be a task with minimal effort, using this script, to prvent potentially injected code into the unencrypted root from being executed (if one should be afraid of that).
'

# one can select a kernel-flavour, some general information:
# Linux Kernel: always up to date, nothing special, vanilla.
# linux-lts: not as bleeding edge, since there is only one major update every couple years.
# 			 During the meantime, security updates are released only. Thus, this kernel is probably more stable and well tested.
# linux-hardened: Many patches to improve security, but some software might not work (e.g. zoom).
# linux-grsec: similar, with the Grsecurity-Patchset though
# linux-zen: high-performance kernel optimized for desktop use, aimed at gaming. Will therefore consume more energy.


ESP=$1
ROOT=$2
HOME=$3
USER_NAME=$4
HOST_NAME=$5
# HOME_CRYPT is $6, boolean

# only needed when dual booting with Windows: path to the boot partition
BOOT=$7

KERNEL="linux-lts"

# disable the use of apparmor:
APPARMOR=""
# to enable it:
#APPARMOR="lsm=landlock,lockdown,yama,integrity,apparmor,bpf"

if [ "$6" = "true" ]; then
	HOME_CRYPT=true
else
    HOME_CRYPT=false
fi

if [ -n "$7" ]; then
    DUAL_BOOT=true
else
	DUAL_BOOT=false
fi

read -s -p "Enter password for user $USER_NAME: " USER_PASSWORD
echo
read -s -p "Enter password again: " USER_PASSWORD2
echo
if [ "$USER_PASSWORD" != "$USER_PASSWORD2" ]; then
    echo "Passwords do not match"
    exit
fi

# partition checks

if [[ $(lsblk -no FSTYPE $ESP) == "" ]]; then
    mkfs.fat -F 32 $ESP
else
	mount $ESP /mnt
	if [[ $(ls -A /mnt) ]]; then
		echo "EFI partition is not empty, probably going to dual-boot"
		if ! $DUAL_BOOT; then
			echo "To use dual boot, you have to specify a boot partition (must be different than ESP)"
			umount /mnt
			exit
		fi
	else
		echo "EFI partition is empty, not going to dual-boot"
		if $DUAL_BOOT; then
			echo "The specified boot partition is not going to be used."
			echo "Please redefine your partition table \(recommended\) or remove that argument."
			umount /mnt
			exit
		fi
	fi
	umount /mnt
fi

# $BOOT will be used only when dual booting
if $DUAL_BOOT; then
	if [[ $(lsblk -no FSTYPE $BOOT) == "" ]]; then
    	mkfs.fat -F 32 $BOOT
	else
		echo "Boot partition is not empty, please control your settings."
		exit
	fi
fi


if [[ $(lsblk -no FSTYPE $ROOT) == "" ]]; then
    mkfs.ext4 $ROOT
	mount $ROOT /mnt
else
	mount $ROOT /mnt
	if [[ $(ls -A /mnt) ]]; then
		# to ensure the correct partition was selected (no mistakes were made)
		echo "The root partition is empty, which is good. No data will be deleted."
	else
		echo "The root partition is not empty, please control your settings."
		umount /mnt
		exit
	fi
fi


# $ROOT should be still mounted, see last partition check
# mount $ROOT /mnt

# is required by systemd-boot and is already assigned here since variables can not be created when invoking chroot
ROOT_PARTUUID=$(echo `blkid $ROOT` | grep -oP 'PARTUUID="\K[^"]+')


if $DUAL_BOOT; then
	EFI_PATH="/efi"
	mount --mkdir $ESP /mnt/efi
	mount --mkdir $BOOT /mnt/boot
else
	EFI_PATH="/boot"
	mount --mkdir $ESP /mnt/boot
fi


# one could use another filesystem like btrfs instead of ext4
if [[ $(lsblk -no FSTYPE $HOME) == "" ]]; then

	if $HOME_CRYPT; then
		# setup /home encryption

		# set the encryption password
		read -s -p "Enter password for home partition $HOME: " CRYPT_PASSWORD
		echo
		read -s -p "Enter password again: " CRYPT_PASSWORD2
		echo
		if [ "$CRYPT_PASSWORD" != "$CRYPT_PASSWORD2" ]; then
			echo "Passwords do not match."
			exit
		fi

		# data could be wiped by using e.g. shred -vn __number greater than 2__ my-partition on a HDD or using hdparm on an SSD
		# echo -n "$PASSWORD" | cryptsetup --type luks2 --cipher aes-xts-plain64 --hash sha256 ($BEST_HASH) --iter-time 2000 --key-size 256 --pbkdf argon2id --use-urandom --verify-passphrase=0 luksFormat $HOME
		echo "$CRYPT_PASSWORD" | cryptsetup -q -v luksFormat $HOME
		echo "$CRYPT_PASSWORD" | cryptsetup open $HOME home
		mkfs.ext4 /dev/mapper/home
		HOME_UUID=$(echo `blkid $HOME` | grep -oP ' UUID="\K[^"]+')
		mkdir /mnt/etc
		echo "home UUID=$HOME_UUID none luks,password-echo=no,timeout=180" > /mnt/etc/crypttab
		mount --mkdir /dev/mapper/home /mnt/home
	else
    	mkfs.ext4 $HOME
		mount --mkdir $HOME /mnt/home
	fi
else
	mount --mkdir $HOME /mnt/home
fi


# some environment checks
echo "checking UEFI Mode"
ls /sys/firmware/efi/efivars
echo "setting time"
timedatectl set-timezone Europe/Amsterdam
echo "time:"
timedatectl status
echo "checking internet connection"
ping -c 3 archlinux.org

if [[ $(lscpu | grep -o 'AuthenticAMD') ]]; then
  CPU_TYPE="amd"
else
  CPU_TYPE="intel"
fi
echo "detected an $CPU_TYPE cpu..."


# will take a while
pacstrap -K /mnt base $KERNEL linux-firmware base-devel git nano man-db $CPU_TYPE-ucode --noconfirm --needed

genfstab -U /mnt > /mnt/etc/fstab

arch-chroot /mnt /bin/bash <<EOF
ln -sf /usr/share/zoneinfo/Europe/Amsterdam /etc/localtime
hwclock --systohc

echo "en_US.UTF-8 UTF-8" > /etc/locale.gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf
locale-gen
# the keyboard layout that should be used
#echo "KEYMAP=de-latin1" > /etc/vconsole.conf
echo $HOST_NAME > /etc/hostname
echo "

127.0.0.1  localhost
::1        localhost ip6-localhost ip6-loopback
ff02::1    ip6-allnodes
ff02::2    ip6-allrouters

127.0.1.1  $HOST_NAME
" >  /etc/hosts


# add user, https://wiki.archlinux.org/title/Users_and_groups#Group_list
useradd -m -G wheel,audio,video,storage,optical,scanner,sys,lp,uucp,network $USER_NAME
echo "$USER_NAME:$USER_PASSWORD" | chpasswd


mkdir /etc/systemd/system/getty@tty1.service.d/
echo "
[Service]
ExecStart=
ExecStart=-/sbin/agetty -o '-p -- $USER_NAME' --noclear --skip-login - \$TERM
" > /etc/systemd/system/getty@tty1.service.d/skip-username.conf

systemctl enable getty@tty1

pacman -S networkmanager --noconfirm --needed
systemctl enable NetworkManager.service

pacman -S zram-generator --noconfirm --needed
echo "
# This config file enables a /dev/zram0 device with the default settings
[zram0]
" > /etc/systemd/zram-generator.conf

if [ "$APPARMOR" != "" ]; then
	pacman -S apparmor --noconfirm --needed
	systemctl enable apparmor.service
fi

pacman -S sudo --noconfirm --needed
echo "Defaults insults" >> /etc/sudoers
sed -i '/^# %wheel ALL=(ALL:ALL) ALL/s/^# //' /etc/sudoers

pacman -S usbguard --noconfirm --needed
usbguard generate-policy > /etc/usbguard/rules.conf
systemctl enable --now usbguard.service
# allow Bluetooth
usbguard allow-device -p $(lsusb | grep "Bluetooth" | grep -oP 'ID \K\S+' | awk '{print $1}')

if lspci | grep -iq 'intel'; then
    pacman -S intel-media-driver --noconfirm --needed
elif lspci | grep -iq 'amd'; then
    pacman -S libva-mesa-driver mesa-vdpau --noconfirm --needed
fi

if lspci | grep -A 2 -E "(VGA|3D)" | grep -iq nvidia; then

    if [ $KERNEL == "linux" ]; then
        pacman -S nvidia --noconfirm --needed
    elif [ $KERNEL == "linux-lts" ]; then
        pacman -S nvidia-lts --noconfirm --needed
    else
	# build nvidia module with kernel headers, will work for every kernel package
        pacman -S $KERNEL-headers nvidia-dkms --noconfirm --needed
    fi

	# if DRM kernel mode setting etc. is not needed (when the GPU is not used to render the display)
	sed -i "s/kms //g" /etc/mkinitcpio.conf
	mkinitcpio -P

	echo "
blacklist nouveau
options nouveau modeset=0
	" >> /etc/modprobe.d/blacklist-nouveau.conf

	# turn off Nvidia-GPU on boot (to safe power, can be enabled to e.g. untilize CUDA)
	echo '
# Remove NVIDIA USB xHCI Host Controller devices, if present
ACTION=="add", SUBSYSTEM=="pci", ATTR{vendor}=="0x10de", ATTR{class}=="0x0c0330", ATTR{power/control}="auto", ATTR{remove}="1"

# Remove NVIDIA USB Type-C UCSI devices, if present
ACTION=="add", SUBSYSTEM=="pci", ATTR{vendor}=="0x10de", ATTR{class}=="0x0c8000", ATTR{power/control}="auto", ATTR{remove}="1"

# Remove NVIDIA Audio devices, if present
ACTION=="add", SUBSYSTEM=="pci", ATTR{vendor}=="0x10de", ATTR{class}=="0x040300", ATTR{power/control}="auto", ATTR{remove}="1"

# Remove NVIDIA VGA/3D controller devices
ACTION=="add", SUBSYSTEM=="pci", ATTR{vendor}=="0x10de", ATTR{class}=="0x03[0-9]*", ATTR{power/control}="auto", ATTR{remove}="1"
	' > /etc/udev/rules.d/00-remove-nvidia.rules

fi
# to turn the GPU on, the file has to be moved to a different location and the machine then has to do a reboot, e.g. 
# mv /etc/udev/rules.d/00-remove-nvidia.rules /etc
# reboot
#
# revert:
# mv /etc/00-remove-nvidia.rules /etc/udev/rules.d
# CUDA should load all necassary kernel modules automatically when the GPU is on
# turn off again, after using CUDA:
# rmmod nvidia_uvm
# rmmod nvidia

mkdir /etc/pacman.d/hooks
echo "
[Trigger]
Type = Package
Operation = Upgrade
Target = systemd

[Action]
Description = upgrading systemd-boot
When = PostTransaction
Exec = /usr/bin/systemctl restart systemd-boot-update.service
" > /etc/pacman.d/hooks/95-systemd-boot.hook
#systemctl enable systemd-boot-update.service

# change permissions of /boot and EFI_PATH to 700
sed -i -E 's/(fmask=)[0-9]+/\10077/g; s/(dmask=)[0-9]+/\10077/g' /etc/fstab

if $DUAL_BOOT; then
	bootctl --esp-path=$EFI_PATH --boot-path=/boot install
else
	bootctl install
fi

mkdir -p $EFI_PATH/loader
mkdir -p /boot/loader/entries

# if one sets the timeout to 0, the bootmenu can be accessed by pressing the space-bar
# tabs are not supported. Use spaces instead.
# editor HAS TO BE NO, else everybody could change the kernel parameters of any boot entry by pressing e. Then, one could spawn a root shell using init=/bin/bash
echo "
default  arch.conf
timeout  0
console-mode max
editor   no
" > $EFI_PATH/loader/loader.conf


echo '
title   Arch Linux
linux   /vmlinuz-$KERNEL
initrd  /$CPU_TYPE-ucode.img
initrd  /initramfs-$KERNEL.img
options root=PARTUUID=$ROOT_PARTUUID rw nowatchdog quiet udev.log_priority=2 libahci.ignore_sss=1 zswap.enabled=0 $APPARMOR
' > /boot/loader/entries/arch.conf


echo '
title   Arch Linux (fallback initramfs)
linux   /vmlinuz-$KERNEL
initrd  /$CPU_TYPE-ucode.img
initrd  /initramfs-$KERNEL-fallback.img
options root=PARTUUID=$ROOT_PARTUUID rw zswap.enabled=0 $APPARMOR
' > /boot/loader/entries/arch-fallback.conf


# for desktop/laptop only. Servers and IoT Devices should leave it enabled.
# The NMI watchdog is a debugging feature to catch hardware hangs that cause a kernel panic.
# On some systems it can generate a lot of interrupts, causing a noticeable increase in power usage.
echo "kernel.nmi_watchdog = 0" > /etc/sysctl.d/disable_watchdog.conf
# watchdog for AMD 700 chipset series
echo "blacklist sp5100_tco" > /etc/modprobe.d/disable-sp5100-watchdog.conf



# iTCO_wdt: the default watchdog
# pcspkr: PC speaker sounds
# joydev: a joystick
# (not removed here): mousedev PS2 mouse support (some laptops use this interface)
# mac_hid: support for Apple products

# disable these features
echo "
blacklist iTCO_wdt
blacklist pcspkr
blacklist joydev
blacklist mac_hid
" >> /etc/modprobe.d/blacklist.conf

# disable core dumps
echo "kernel.core_pattern=/dev/null" > /etc/sysctl.d/50-coredump.conf

# Kexec allows replacing the current running kernel.
echo "kernel.kexec_load_disabled = 1" >> /etc/sysctl.d/51-kexec-restrict.conf

echo "
# hidepid=1 hides all processes information but not the process itself from other users, except for root and the proc group
# hidepid=2 hides all processes from other users, except root and proc group. May cause errors.
#proc				/proc	proc	nosuid,nodev,noexec,hidepid=1,gid=proc	0	0
" >> /etc/fstab

# add nosuid,nodev,noexec, to /tmp
echo "tmpfs   /tmp         tmpfs   defaults,nodev,nosuid,noexec,noatime          0  0" >> /etc/fstab
mkdir /root/tmp
echo "tmpfs   /root/tmp         tmpfs   defaults,nodev,nosuid,noatime,mode=0700          0  0" >> /etc/fstab

# add commit=120 to root
sed -i 's|\(\s\+/ \s\+ext4\s\+\)[^[:space:]]*|\1rw,relatime,commit=120|' /etc/fstab

# change mount options for home to defaults,noatime,nosuid,nodev,noexec
# if a "failed to map segment from shared object" error is thrown when executing a binary, this is most likely related to the noexec option
# one could add the commit mount option too, to increase the delay between page-cache to hard-drive syncing.
# This could reduce disk writes (-> SSD TBW), but could lead to data loss when the system crashes.
# default is commit=5 (in seconds)
sed -i 's|\(\s\+/home\s\+ext4\s\+\)[^[:space:]]*|\1defaults,noatime,nosuid,nodev,noexec|' /etc/fstab


# grant privilidges to access /proc for proc group and root
mkdir /etc/systemd/system/systemd-logind.service.d
sudo echo "[Service]
SupplementaryGroups=proc" >> /etc/systemd/system/systemd-logind.service.d/hidepid.conf


# limit max processes to prevent fork bombs, does not affect systemd services/daemons
# the number of processes at the moment:  ps --no-headers -Leo user | sort | uniq --count
# set to max by executing "sudo prlimit"
echo "
* 		    soft 	nproc 	 2000
*           hard    nproc 	 4000
root        hard    nproc    65536       # Prevent root from not being able to launch enough processes
" >> /etc/security/limits.conf

echo "auth optional pam_faildelay.so delay=4000000" >> /etc/pam.d/system-login

# one could add Linux filesystem hardening here
# chmod go-r path_to_hide
# e.g. for /boot, /etc/nftables.conf, /etc/iptables etc.

passwd -l root
EOF


# yay COULD be installed this way, but then multiple packages like base-devel would have to be downloaded, so leaving this for post-installation
: '
arch-chroot /mnt /bin/bash <<EOF
git clone https://aur.archlinux.org/yay-bin.git
EOF

chmod 777 /mnt/yay-bin
pacman -Sy base-devel --noconfirm --needed

# makepkg can not be run as root
useradd user
su user /bin/bash -c "cd /mnt/yay-bin && makepkg -s && mv *yay*.pkg.tar.zst .. && cd .. && rm -r yay-bin"
userdel user

arch-chroot /mnt /bin/bash <<EOF
# install yay
pacman -U *yay*.pkg.tar.zst
rm *yay*.pkg.tar.zst
EOF
'


# example:
# -> #Word=1234
# uncomment Word= text.txt
# -> Word=1234
function uncomment() {
    local regex="$1"
    local file="${2:?}"
    local comment_mark="${3:-#}"
    sed -ri "s:^([ ]*)[$comment_mark]+[ ]?([ ]*$regex):\\1\\2:" "$file"
}

# Example:
# -> Word=1234
# set_value Word 0 file.txt
# -> Word=0
function set_value() {
  sed -ie "s/^$1=.*/$1=$2/" "$3"
}

# set BUILDDIR to /tmp in general
uncomment BUILDDIR= /mnt/etc/makepkg.conf

# /tmp being noexec, some AUR packages need to execute scripts, thus setting BUILDDIR to/run/user/USER_ID:
mkdir -p /mnt/home/$USER_NAME/.config/pacman
cp /mnt/etc/makepkg.conf /mnt/home/$USER_NAME/.config/pacman
# set BUILDDIR to /run/user/USER_ID: (user_id of first created user will always be 1000, $(id -u $USER_NAME) does not work due to not being in the chroot anymore)
set_value BUILDDIR \\/run\\/user\\/1000 /mnt/home/$USER_NAME/.config/pacman/makepkg.conf

# anything-sync-daemon and yay (for building packages, see the post-install-script) will use a RAM disk. Increase the size in case of out of storage:
uncomment RuntimeDirectorySize= /mnt/etc/systemd/logind.conf
set_value RuntimeDirectorySize "20%" /mnt/etc/systemd/logind.conf


set_value IPCAllowedUsers "root $USER_NAME" /mnt/etc/usbguard/usbguard-daemon.conf

# speed up by caching compiled profiles
if [ "$APPARMOR" != "" ]; then
	uncomment write-cache /mnt/etc/apparmor/parser.conf
	uncomment Optimize=compress-fast /mnt/etc/apparmor/parser.conf

	# enable all apparmor profiles
	# will be added somtime
fi

cd ..
mv ArchInstaller /mnt/home/$USER_NAME
umount -R /mnt
poweroff
