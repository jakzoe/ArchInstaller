#!/bin/bash

# Note: conversion to an array in su_cp will not work in zsh

# USAGE: bash SoftwareInstall.sh path_to_dot_files
# to create a log (pipes standard error to standard output, so that both are piped to tee):
# bash SoftwareInstall.sh path_to_dot_files 2>&1 | tee -a ../log.txt
# 8 GB RAM is recommended when using the RAM disk configurations

sudo -v
sudo -l
# disable sudo timeout
while true; do sudo -v; sleep 60; done &

# Example:
# -> Word=1234
# comment Word= text.txt
# -> #Word=1234
function comment() {
  local regex="${1:?}"
  local file="${2:?}"
  local comment_mark="${3:-#}"
  sudo sed -ri "s:^([ ]*)($regex):\\1$comment_mark\\2:" "$file"
}

# Example:
# -> #Word=1234
# uncomment Word= text.txt
# -> Word=1234
function uncomment() {
  local regex="$1"
  local file="${2:?}"
  local comment_mark="${3:-#}"
  sudo sed -ri "s:^([ ]*)[$comment_mark]+[ ]?([ ]*$regex):\\1\\2:" "$file"
}

# Example:
# -> Word=1234
# set_value Word 0 file.txt
# -> Word=0
function set_value() {
  sudo sed -ie "s/^$1=.*/$1=$2/" "$3"
}

# some checks
wdctl
sudo dmesg | grep 'microcode'
systemd-analyze #blame
swapon --show
zramctl
# checking whether the Nvidia-GPU is disabled (if one is installed, to save power)
lspci

if pacman -Qi "apparmor" &> /dev/null; then
  aa-enabled
  sudo aa-status
fi

USER_NAME=$(whoami)
USER_ID=$(id -u)
# the browser (in this case Brave) and KeepassXC will run with the permissions of that user:
BROWSER_USER_NAME="browseruser"
BROWSER_GROUP_NAME="browser"

#if [ -z "$1" ]; then
#  echo "Error: No path to dot files provided."
#  exit 1
#fi

# needed when copying dot files
if [ -n "$1" ]; then
  dot=$1
else
  dot="/home/$USER_NAME/ArchInstaller"
fi

# still owned by root due to being copied by ArchInstall.sh
sudo chown $USER_NAME:$USER_NAME -R $dot
sudo chown $USER_NAME:$USER_NAME -R /home/$USER_NAME/.config

sudo groupadd $BROWSER_GROUP_NAME
sudo useradd -m -G audio,video,storage,optical,scanner,sys,lp,uucp,network,$BROWSER_GROUP_NAME $BROWSER_USER_NAME
sudo usermod -a -G $BROWSER_GROUP_NAME $USER_NAME

sudo mkdir /etc/systemd/system/getty@tty2.service.d/
sudo bash -c "echo \"
[Service]
ExecStart=
ExecStart=-/sbin/agetty -o '-p -- $BROWSER_USER_NAME' --noclear --skip-login - \$TERM
\" > /etc/systemd/system/getty@tty2.service.d/skip-username.conf"

sudo systemctl enable getty@tty2

# strings/commands that will be added to /home/$USER_NAME/.bash_profile
auto_start=()

sudo pacman -Syyu
sudo pacman -Fyy

# setup AUR helper yay
cd /tmp
git clone https://aur.archlinux.org/yay-bin.git
cd yay-bin
makepkg -si --noconfirm
cd ..
rm -rf yay-bin
cd

function pacman() {
  /usr/bin/sudo /usr/bin/pacman --needed --noconfirm "$@"
}

function yay() {
  /usr/bin/yay --needed --noconfirm "$@"
  rm -rf /run/user/$USER_ID/cache/yay
}

# https://wiki.archlinux.org/title/Unified_Extensible_Firmware_Interface/Secure_Boot#sbctl

# Note: sbctl does not work with all hardware. How well it will work depends on the manufacturer.

pacman -S sbctl
sudo sbctl status
# needs setup mode to be enabled
: '
sudo sbctl create-keys
sudo sbctl enroll-keys -m
# chattr -i the files sbctl mentions (should there even be any)
sudo sbctl verify
# e.g.:
sudo sbctl sign -s /boot/vmlinuz-linux-lts
sudo sbctl sign -s /efi/EFI/BOOT/BOOTX64.EFI
sudo sbctl sign -s /boot/EFI/systemd/systemd-bootx64.efi

# so that systemd-boot is able to sign the boot loader
sudo sbctl sign -s -o /usr/lib/systemd/boot/efi/systemd-bootx64.efi.signed /usr/lib/systemd/boot/efi/systemd-bootx64.efi
'
sudo sbctl verify
sudo sbctl status

#====System Maintainance====

# update mirrors once a week
pacman -S reflector
sudo systemctl enable reflector.service reflector.timer
sudo systemctl start reflector.service reflector.timer

pacman -S pacman-contrib
# one backup per package (runs once)
sudo paccache -rk1
# remove all cached versions of uninstalled packages (runs once)
sudo paccache -ruk0

# runs "paccache -r" once a week
sudo systemctl enable paccache.timer
sudo systemctl start paccache.timer

uncomment "ParallelDownloads =" /etc/pacman.conf
set_value "ParallelDownloads " " 3" /etc/pacman.conf

uncomment Color /etc/pacman.conf
sudo sed -i '/Color/a ILoveCandy' /etc/pacman.conf

# clean system logs (runs once)
journalctl --disk-usage
sudo journalctl --vacuum-time=7d
sudo journalctl --vacuum-size=200M

# set permanent hard-limit of 200M for journal-files
uncomment SystemMaxUse= /etc/systemd/journald.conf
set_value SystemMaxUse 200M /etc/systemd/journald.conf

#====Power Saving====

# im case one wants to monitor the power consumption first:
# pacman -S powertop

# best power-saving, disables turbo-boost though
pacman -S tlp tlp-rdw powertop
# to avoid conflicts and assure proper operation of TLP's radio device switching options
sudo systemctl mask systemd-rfkill.service
sudo systemctl mask systemd-rfkill.socket
sudo systemctl enable tlp
# needed by tlp-rdw, but also other dispatcher scripts
sudo systemctl enable NetworkManager-dispatcher.service

# to emable tlp, even if no battery is detected, edit /etc/tlp.conf:

# Operation mode when no power supply can be detected: AC, BAT.
#TLP_DEFAULT_MODE=BAT

# Operation mode select: 0=depend on power source, 1=always use TLP_DEFAULT_MODE
#TLP_PERSISTENT_DEFAULT=1


# if one does not want to loose turbo-boost, this should be used instead
# auto-cpufreq should not affect the perfromance. It's configs can be edited, so that it runs even when no battery is used (see the GitHub documentation)
# view stats with auto-cpufreq --stats
: '
yay -S auto-cpufreq
sudo systemctl enable --now auto-cpufreq.service
pacman -S thermald
sudo systemctl enable --now thermald.service
'


#====Networking====

# USB-Tethering, one could also use systemd-networkd with udev instead (as always, see ArchWiki)
pacman -S usb_modeswitch

# takes a long time, in most cases there is not even an NFS to connect to during boot. Target is needed by e.g. reflector though
# (does not wait for internet-connection but finished NetworkManager startup)
#sudo systemctl disable NetworkManager-wait-online.service
# sync man-db less frequently
# sudo sed -i 's/daily/weekly/g' /usr/lib/systemd/system/man-db.timer

# to use a captive portal, manually connecting to a http connection (e.g. http://capnet.elementary.io) should work

pacman -S ufw
sudo systemctl --now enable ufw
sudo ufw default deny
# sudo ufw allow from 192.168.0.0/24
sudo ufw logging off
sudo ufw enable

# pacman -S firewalld
# sudo systemctl enable firewalld.service
# sudo systemctl start firewalld.service
# sudo firewall-cmd --state
# sudo firewall-cmd --set-default-zone=drop

# minimal
#pacman -S nftables
#sudo nft flush ruleset
#sudo nft add table inet filter
#sudo nft add chain inet filter input { type filter hook input priority 0\; policy drop\; }
#sudo nft add chain inet filter forward { type filter hook forward priority 0\; policy drop\; }
#sudo nft add chain inet filter output { type filter hook output priority 0\; policy accept\; }
#sudo nft list ruleset > /etc/nftables.conf
#sudo systemctl enable nftables
#sudo systemctl start nftables

# install Proton-VPN
yay -S protonvpn-cli
# protonvpn-cli login proton_emailaddress
# protonvpn-cli ks --permanent
# protonvpn-cli c -f (provide password from proton vpn website)
# configure custom DNS in .config/protonvpn when desired


# one could use random MAC, but may be root of problems in public wifi
# set wifi.cloned-mac-address=stable, if there are such issues
: '
# sudo bash -c ...
echo "
[device-mac-randomization]
# "yes" is already the default for scanning
wifi.scan-rand-mac-address=yes

[connection-mac-randomization]
# Randomize MAC for every connection
ethernet.cloned-mac-address=random
wifi.cloned-mac-address=random
" > /etc/NetworkManager/conf.d/wifi_rand_mac.conf
'

pacman -S macchanger

### Option 1: Do not use systemd-resolved

## even when the system resolver is configured to something else than systemd-resolved,
## DNS data that is discovered is pushed to systemd-resolved anyway.
## When systemd-resolved is disabled, this has no sense (can not pull DNS data since it is not running)

#sudo bash -c "
#echo '[main]
#systemd-resolved=false
#'>> /etc/NetworkManager/conf.d/no-systemd-resolved.conf"
# custom DNS, using cloudflare 1.1.1.1 and 1.0.0.1 and ISP backup (localhost)
#sudo bash -c "
#echo '
#[global-dns-domain-*]
#servers=1.1.1.1,1.0.0.1,::1,127.0.0.1
#' > /etc/NetworkManager/conf.d/dns-servers.conf"


### Option 2: use systemd-resolved

## configure networmanager to use systemd-resolved to query DNS data (has optional DNS caching, DNSSEC and DNS over TLS)
# Note: sytemd-resolved does not use custom DNS but the the connection's DNS servers.
# The alternatives are stored as default options (in /etc/systemd/resolved.conf: 1.1.1.1#cloudflare-dns.com 9.9.9.9#dns.quad9.net 8.8.8.8#dns.google)
sudo systemctl enable --now systemd-resolved.service

sudo rm /etc/resolv.conf
sudo ln -s /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
# systemd-resolved should now be used automatically (via the symblink), to enable explicitly:
sudo bash -c "
echo '[main]
dns=systemd-resolved
' >> /etc/NetworkManager/conf.d/dns.conf"

# DHCP and VPN clients might use resolvconf to set the DNS server. Remove the package when systemd-resolved is not running, else might cause problems
pacman -S systemd-resolvconf

# enable DNSSEC, change to DNSSEC=allow-downgrade to validate DNSSEC only if the upstream DNS server supports it, DNSSEC=true to always try to use it, even if not supported
# (many public hotspots and tethering options do not support it)
sudo  mkdir -p /etc/systemd/resolved.conf.d
sudo bash -c "
echo '[Resolve]
DNSSEC=allow-downgrade
' >> /etc/systemd/resolved.conf.d/dnssec.conf"

# enable DNS over TLS, change to DNSOverTLS=opportunistic to only use DNS over TLS if the server supports it, DNSOverTLS=yes to always try to use it, even if not supported
sudo bash -c "
echo '[Resolve]
DNS=1.1.1.1#cloudflare-dns.com
DNSOverTLS=opportunistic
' >> /etc/systemd/resolved.conf.d/dns_over_tls.conf"

curl ipinfo.io

#====GUI====

# additional fonts/emojis/icons, using "Arc-Dark" theme. There are even more in the AUR, one might want to try them.
# (see e.g. https://itsfoss.com/icon-themes-arch-linux/ for ideas)
pacman -S ttf-jetbrains-mono-nerd noto-fonts-emoji arc-gtk-theme papirus-icon-theme noto-fonts
# manages the aboth
#pacman -S lxappearance

sudo bash -c 'echo "
[Icon Theme]
Inherits=Papirus-Dark
" > /usr/share/icons/default/index.theme'


# audio
pacman -S pipewire pipewire-pulse pipewire-alsa pipewire-jack pipewire-audio wireplumber pavucontrol pamixer playerctl

# needed to get root access on some graphical applications
pacman -S polkit-gnome

# notification daemon
pacman -S dunst

# pacman -S python-pip

# apparmor notification on DENIED
if pacman -Qi "apparmor" &> /dev/null; then
  pacman -S audit python-notify2 python-psutil
  # /etc/audit/auditd.conf
  # log_group = wheel
  sudo groupadd -r audit
  sudo gpasswd -a $USER_NAME audit
  sudo bash -c 'echo "log_group = audit" >> /etc/audit/auditd.conf'
  sudo systemctl enable --now auditd.service
fi

# weather icon, rofi dependencies
pacman -S python-chardet python-requests python-pillow

# hyprland: window manager
# waybar: similar to a task bar
# desktop portal: GUI Apps and environment communication (e.g. browser opening files app/chooser)
# rofi: application search menu
# swaybg: set wallpaper
# swayidle: automatic screen locking/timeout etc.
# kitty: terminal
# socat: used for hyprland IP C (socket communication)

pacman -S hyprland waybar xdg-desktop-portal-hyprland rofi swaybg swayidle kitty socat

auto_start+=(
"export XDG_SCREENSHOTS_DIR=/run/user/$USER_ID/screenshots
mkdir \$XDG_SCREENSHOTS_DIR
export GTK_THEME=Arc-Dark
# kitty uses XDG_RUNTIME_DIR by default, but also changes it's permissions by calling os.chmod(candidate, 0o700) in kitty/kitty/constants.py
export KITTY_RUNTIME_DIRECTORY=\$XDG_RUNTIME_DIR/kitty
# not necessary, but less errors
export LIBSEAT_BACKEND=logind")

auto_start+=("! pgrep -x Hyprland > /dev/null && Hyprland &")


# in case x11-windows should be forwarded too: allow $BROWSER_USER_NAME to access xorg display of $USER_NAME
# pacman -S xorg-xhost

auto_start+=(
"
# if hyprctl sockets should be available, make the corrosponding sockets in /tmp/hypr accessable in the same way and export the HYPRLAND_INSTANCE_SIGNATURE variable

# making piping windows to the display-server of $USER_NAME possible:
# wait for the wayland socket to be created
bash -c '
sleep 4
chown :$BROWSER_GROUP_NAME \$XDG_RUNTIME_DIR
chmod 770 \$XDG_RUNTIME_DIR
chown :$BROWSER_GROUP_NAME \$XDG_RUNTIME_DIR/wayland-1
chmod 660 \$XDG_RUNTIME_DIR/wayland-1
chown :$BROWSER_GROUP_NAME \$XDG_RUNTIME_DIR/pipewire-0
chmod 660 \$XDG_RUNTIME_DIR/pipewire-0
# not needed?
#chown :$BROWSER_GROUP_NAME /run/user/$USER_ID/bus
#chmod 770 /run/user/$USER_ID/bus

# make xwayland accessable
#export DISPLAY=:0
#xhost +SI:localuser:$BROWSER_USER_NAME
' &
")


# hyprpicker: color picker
# swaylock effects: another version of swaylock, locks screen
yay -S hyprpicker-git swaylock-effects-git

# screenshots, since flameshot does not work:
# grim: screenshot, slurp: select region
pacman -S grim slurp wl-clipboard
yay -S grimblast-git

# bluetooth
pacman -S bluez bluez-utils blueman
uncomment "Experimental =" /etc/bluetooth/main.conf
set_value "Experimental " " true" /etc/bluetooth/main.conf
sudo systemctl enable --now bluetooth.service

# network applet: small icon to select e.g. wifi network etc.
# nm connection editor: edit network connections
# brightnessctl: screen brightness (laptop)
pacman -S network-manager-applet nm-connection-editor brightnessctl

# setup file explorer, together with common features e.g. access the filesystem of a plugged in smart phones, image previews etc.
pacman -S thunar thunar-archive-plugin file-roller thunar-volman thunar-media-tags-plugin gvfs gvfs-mtp tumbler
# zsh instead of bash
pacman -S zsh zsh-completions zsh-autosuggestions zsh-syntax-highlighting zsh-history-substring-search zsh-theme-powerlevel10k
pacman -S bash-completion

pacman -S nano-syntax-highlighting
#curl https://raw.githubusercontent.com/scopatz/nanorc/master/install.sh | sh

sudo bash -c 'echo "
include \"/usr/share/nano/*.nanorc\"
include \"/usr/share/nano/extra/*.nanorc\"
include \"/usr/share/nano-syntax-highlighting/*.nanorc\"
" >> /etc/nanorc'
# fix typo
sudo sed -i 's/icolor brightnormal/icolor normal/g' /usr/share/nano-syntax-highlighting/nanorc.nanorc

# keyd: configure shortcuts, e.g. caps lock + h = left, caps lock + l = right and so on
yay -S keyd
sudo systemctl enable keyd

#====SSD Health====

# SSD S.M.A.R.T Info
# already written bytes are calculated with Total_LBAs_Written * Sector Size (LogicaL)
pacman -S smartmontools
sudo smartctl -a /dev/sda

# TRIM SSD once a week
sudo systemctl enable fstrim.timer

#====Browser-Profiles-To-RAM====

# recommended: setting browser download dir to /run/user/<user id>. One then does not have to delete them manually, they are removed on poweroff.
# Should moving certain files to hard disk was forgotten, they could be downloaded once again.

pacman -S anything-sync-daemon

comment WHATTOSYNC= /etc/asd.conf
sudo bash -c "echo \"
WHATTOSYNC=(
'/home/$BROWSER_USER_NAME/.config/BraveSoftware/Brave-Browser'
'/home/$USER_NAME/.config/BraveSoftware/Brave-Browser'
'/home/$USER_NAME/.config/Code'
)
\" >> /etc/asd.conf"

# make sure the paths do exist
sudo -u $BROWSER_USER_NAME mkdir -p /home/$BROWSER_USER_NAME/.config/BraveSoftware/Brave-Browser
mkdir -p /home/$USER_NAME/.config/BraveSoftware/Brave-Browser
mkdir -p /home/$USER_NAME/.config/Code

#uncomment USE_BACKUPS= /etc/asd.conf
#uncomment BACKUP_LIMIT= /etc/asd.conf
#set_value BACKUP_LIMIT 1 /etc/asd.conf
sudo bash -c 'echo "USE_BACKUPS=\"no\"" >> /etc/asd.conf'

# can not leave it as /tmp, since exec is required. To prevent access to other user's files, VOLATILE is set to a dir owned by root.
#sudo bash -c 'echo "VOLATILE=\"/run/user/'"$USER_ID"'\"" >> /etc/asd.conf'
sudo bash -c 'echo "VOLATILE=/root/tmp" >> /etc/asd.conf'
sudo bash -c 'echo "USE_OVERLAYFS=\"yes\"" >> /etc/asd.conf'

sudo systemctl enable asd

# another option: use profile-sync-daemon:
# In the worst case, syncing might create a larger performnace overhead/disk writes than leaving it as it is, since overlayfs is no option due to security:
# I recommend disabling it, since (according to ArchWiki):
# 1. Usage of psd in overlayfs mode (in particular, psd-overlay-helper) may lead to privilege escalation
# 2. Using overlayfs is a trade off: faster initial sync times and less memory usage vs. disk space in the home dir.
# to use it anyway:
# echo "`whoami` ALL=(ALL) NOPASSWD: /usr/bin/psd-overlay-helper" >> /etc/sudoers

: '
pacman -S profile-sync-daemon

# support for Brave (or install the AUR package profile-sync-daemon-brave)
cp brave /usr/share/psd/browsers
cp brave-nightly /usr/share/psd/browsers

echo "USE_BACKUPS=\"no\"" >> /home/$USER_NAME/.config/psd/psd.conf
uncomment BACKUP_LIMIT= /home/$USER_NAME/.config/psd/psd.conf
set_value BACKUP_LIMIT= 1 /home/$USER_NAME/.config/psd/psd.conf

systemctl --user enable psd
systemctl --user start psd
'

# whitelist style, leave the remaining dirs on the hard disk
: '
# move certain cache dirs to RAM disk
directories=(
  "BraveSoftware/Brave-Browser"
  "mesa_shader_cache"
)

for directory in "${directories[@]}"; do

  DISK_CACHE="/home/$USER_NAME/.cache/${directory}"
  RAM_CACHE="/run/user/$USER_ID/${directory}"

  rm -r $DISK_CACHE
  mkdir -p $RAM_CACHE
  ln -s $RAM_CACHE $DISK_CACHE
  auto_start+=("mkdir -p $RAM_CACHE")
done


# JNA sometimes creates executables in a temp dir
rm -rf /home/$USER_NAME/.cache/JNA
mkidr -p /run/user/$USER_ID/JNA
ln -s /run/user/$USER_ID/JNA /home/$USER_NAME/.cache/JNA

auto_start+=("mkidr -p /run/user/$USER_ID/JNA && ln -s /run/user/$USER_ID/JNA /home/$USER_NAME/.cache/JNA")
'

# blacklist style, leave the ones in the array on hard disk only
directories=(
  #"yay"
)

rm -rf /home/$USER_NAME/.cache
mkdir -p /run/user/$USER_ID/cache
auto_start+=("mkdir -p /run/user/$USER_ID/cache")
ln -s /run/user/$USER_ID/cache /home/$USER_NAME/.cache
mkdir /home/$USER_NAME/.perm_cache

for directory in "${directories[@]}"; do

  DISK_CACHE="/home/$USER_NAME/.perm_cache/${directory}"
  RAM_CACHE="/run/user/$USER_ID/cache/${directory}"

  mkdir -p $DISK_CACHE
  ln -s $DISK_CACHE $RAM_CACHE
  auto_start+=("ln -s $DISK_CACHE $RAM_CACHE")
done


# link .cache to RAM disk for $BROWSER_USER_NAME

BROWSER_USER_ID=$(id -u $BROWSER_USER_NAME)

sudo rm -rf /home/$BROWSER_USER_NAME/.cache
sudo -u $BROWSER_USER_NAME mkdir -p /run/user/$BROWSER_USER_ID/cache
sudo bash -c "echo \"mkdir -p /run/user/$BROWSER_USER_ID/cache\" >> /home/$BROWSER_USER_NAME/.bash_profile"
sudo -u $BROWSER_USER_NAME ln -s /run/user/$BROWSER_USER_ID/cache /home/$BROWSER_USER_NAME/.cache
sudo -u $BROWSER_USER_NAME mkdir /home/$BROWSER_USER_NAME/.perm_cache

for directory in "${directories[@]}"; do

  DISK_CACHE="/home/$BROWSER_USER_NAME/.perm_cache/${directory}"
  RAM_CACHE="/run/user/$BROWSER_USER_ID/cache/${directory}"

  sudo -u $BROWSER_USER_NAME mkdir -p $DISK_CACHE
  sudo -u $BROWSER_USER_NAME ln -s $DISK_CACHE $RAM_CACHE
  sudo bash -c "echo \"ln -s $DISK_CACHE $RAM_CACHE\" >> /home/$BROWSER_USER_NAME/.bash_profile"
done


#====Browser Security and Keepassxc====

# password manager, used with it's browser-extension for storing website passwords
pacman -S keepassxc qt5-wayland

# this will start Brave and KeepassXC by a separate user and foreward the windows to the current user's screen, for improved security

sudo bash -c "echo '

export DISPLAY=:0
export WAYLAND_DISPLAY=wayland-1
export XDG_BACKEND=wayland
export XDG_SESSION_TYPE=wayland
export QT_QPA_PLATFORM=wayland
export HYPRLAND_CMD=Hyprland
export XDG_CURRENT_DESKTOP=Hyprland
export XDG_SESSION_DESKTOP=Hyprland
export MOZ_ENABLE_WAYLAND=1
export XCURSOR_SIZE=24
export XDG_VTNR=1
export XDG_SESSION_ID=1

# linking the socketes is cleaner
#export XDG_RUNTIME_DIR=/run/user/$USER_ID
#export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$USER_ID/bus

ln -s /run/user/$USER_ID/wayland-1 \$XDG_RUNTIME_DIR/wayland-1
touch \$XDG_RUNTIME_DIR/wayland-1.lock
rm \$XDG_RUNTIME_DIR/pipewire-0
# audio etc.
ln -s /run/user/$USER_ID/pipewire-0 \$XDG_RUNTIME_DIR/pipewire-0
touch \$XDG_RUNTIME_DIR/pipewire-0.lock
# not needed
#rm \$XDG_RUNTIME_DIR/bus
#ln -s /run/user/$USER_ID/bus \$XDG_RUNTIME_DIR/bus

# typing the password as $BROWSER_USER_NAME should make it unkeyloggable by $USER_NAME
read -s -p \"Enter password for your database: \" PASSWORD
sudo chvt 1
echo \$PASSWORD | keepassxc --keyfile keyfile --pw-stdin Keys > /dev/null 2>&1 &
brave --enable-features=UseOzonePlatform --ozone-platform=wayland > /dev/null 2>&1 &
#physlock # -d -m -s
vlock
' >> /home/$BROWSER_USER_NAME/.bash_profile"

sudo bash -c "echo \"$BROWSER_USER_NAME ALL=(ALL) NOPASSWD: /usr/bin/chvt 1\" >> /etc/sudoers"

echo "
--enable-features=WaylandWindowDecorations
--ozone-platform-hint=auto
#--enable-webrtc-pipewire-capturer
" >> /home/$USER_NAME/.config/electron25-flags.conf >> /home/$USER_NAME/.config/code-flags.conf # >> /home/$USER_NAME/.config/codium-flags.conf

sudo bash -c "echo '
--enable-features=WaylandWindowDecorations
--ozone-platform-hint=auto
#--enable-webrtc-pipewire-capturer
' >> /home/$BROWSER_USER_NAME/.config/electron25-flags.conf >> /home/$BROWSER_USER_NAME/.config/code-flags.conf" # >> /home/$BROWSER_USER_NAME/.config/codium-flags.conf"

#===Copying Dotfiles===

lock_permissions() {
  local path=$1

  if [[ -d "$path" ]]; then
    /usr/bin/sudo /usr/bin/chmod 500 "$path"
    /usr/bin/sudo /usr/bin/find "$path" -type d -exec /usr/bin/sudo /usr/bin/chmod 500 {} +
    /usr/bin/sudo /usr/bin/find "$path" -type f -exec /usr/bin/sudo /usr/bin/chmod 400 {} +
    /usr/bin/sudo /usr/bin/find "$path" ! -type l -exec /usr/bin/sudo /usr/bin/chattr +i {} +
  else
    /usr/bin/sudo /usr/bin/chmod 400 "$path"
  fi
  /usr/bin/sudo /usr/bin/chattr +i "$path"
}

cp() {
  /usr/bin/cp -rp "$@"
}

su_cp() {

  path_list=($(echo "$1"))

  for path in "${path_list[@]}"; do
    /usr/bin/sudo /usr/bin/chown -R root:root $path

    if [[ -d "$path" ]]; then
      /usr/bin/sudo /usr/bin/chmod 544 "$path"
      /usr/bin/sudo /usr/bin/find "$path" -type d -exec /usr/bin/sudo /usr/bin/chmod 544 {} +
      /usr/bin/sudo /usr/bin/find "$path" -type f -exec /usr/bin/sudo /usr/bin/chmod 444 {} +
    else
      /usr/bin/sudo /usr/bin/chmod 444 "$path"
    fi
    /usr/bin/sudo /usr/bin/cp -rp "$@"
  done
}

# unused method, has to be run externally
copy_conf() {
  cd
  mkdir ArchInstaller
  cd ArchInstaller

  mkdir etc
  cp /etc/keyd etc
  # custom message on tty login
  cp /etc/issue etc

  mkdir cfg
  CONFIG_DIR=~/.config
  cp $CONFIG_DIR/dunst cfg
  cp $CONFIG_DIR/hypr cfg
  cp $CONFIG_DIR/kitty cfg
  cp $CONFIG_DIR/pipewire cfg
  cp $CONFIG_DIR/ranger cfg
  cp $CONFIG_DIR/rofi cfg
  cp $CONFIG_DIR/swaylock cfg
  cp $CONFIG_DIR/waybar cfg
  cp $CONFIG_DIR/mimeapps.list cfg
  mkdir -p cfg/Code/User
  # turn off telemetry and make titleBarStyle dark
  # "telemetry.telemetryLevel": "off",
  # "window.titleBarStyle": "custom",
  # "window.dialogStyle": "custom"
  # maybe also add flag to run natively under wayland?
  cp $CONFIG_DIR/Code/User/settings.json cfg/Code/User
  cp $CONFIG_DIR/Code/User/snippets cfg/Code/User

  mkdir home
  cp ~/.bashrc home
  cp ~/.zshrc home
  cp ~/.p10k.zsh home

  mkdir other
  cp /usr/share/zsh/manjaro-zsh-config other
  su_cp /usr/local/bin/Help other

  #mkdir keymanager
  #sudo cp /home/$BROWSER_USER_NAME/Keys keymanager
  #sudo cp /home/$BROWSER_USER_NAME/keyfile keymanager

  #copy ~/.config/rclone/rclone.conf
  #copy browser-profile
}

# include dot files in *
if [ -n "$BASH_VERSION" ]; then
  shopt -s dotglob
elif [ -n "$ZSH_VERSION" ]; then
  setopt dot_glob
elif command -v fish >/dev/null 2>&1; then
  fish -c "set -gU dot_glob 1"
else
  echo "Unsupported shell."
fi


su_cp $dot/etc/* /etc
cp $dot/cfg/* /home/$USER_NAME/.config
cp $dot/home/* /home/$USER_NAME
su_cp $dot/other/manjaro-zsh-config /usr/share/zsh
su_cp $dot/other/Help /usr/local/bin
sudo chmod +x /usr/local/bin/Help
#su_cp $dot/keymanager/* /home/$BROWSER_USER_NAME
#sudo chown $BROWSER_USER_NAME:$BROWSER_USER_NAME /home/$BROWSER_USER_NAME/keyfile /home/$BROWSER_USER_NAME/Keys
#sudo chmod 600 /home/$BROWSER_USER_NAME/Keys
#sudo chmod 400 /home/$BROWSER_USER_NAME/keyfile

sudo bash -c 'echo "
if [ ! -z \"\$PS1\" ]; then
  exec /bin/zsh \$*
fi
" >> /root/.bashrc'

su_cp $dot/home/.zshrc /root
su_cp $dot/home/.p10k.zsh /root

sudo bash -c 'echo "
TMOUT=300
readonly TMOUT
export TMOUT
" >> /root/.zshrc'

echo 'if [ "$(tty)" = "/dev/tty1" ]; then' >> /home/$USER_NAME/.bash_profile
for element in "${auto_start[@]}"; do
  while IFS= read -r line; do
    echo "  $line" >> /home/$USER_NAME/.bash_profile
  done <<< "$element"
done
echo "fi" >> /home/$USER_NAME/.bash_profile

# to change e.g. us(altgr-intl)
: '
default partial alphanumeric_keys
xkb_symbols "basic" {
    include "us(altgr-intl)"
    include "level3(caps_switch)"
    name[Group1] = "English (US, international with German umlaut)";
    key <AD03> { [ e, E, EuroSign, cent ] };
    key <AD07> { [ u, U, udiaeresis, Udiaeresis ] };
    key <AD09> { [ o, O, odiaeresis, Odiaeresis ] };
    key <AC01> { [ a, A, adiaeresis, Adiaeresis ] };
    key <AC02> { [ s, S, ssharp ] };
};
 > ~/.config/xkb/symbols/us-german-umlaut
'

#====Basic Tools====
pacman -S wget exa bat htop iotop btop nano openssh ncdu acpi exfatprogs ntfs-3g udiskie meld lshw

# PDFs are by default in /var/spool/cups-pdf/$USER_NAME, if not changed in /etc/cups/cups-pdf.conf
pacman -S cups cups-pdf
sudo systemctl enable cups.socket

# appropriate for most installations, less resources but less accuracy
# sudo timedatectl set-ntp true

# NTP might be better when running a server
#pacman -S ntp
# use ntpdate.service to check only once per boot
#sudo systemctl enable ntpd.service

pacman -S chrony
sudo systemctl enable chronyd
sudo systemctl start chronyd

# atool is needed for file (de)compression in ranger/python
pacman -S ranger atool
# install some more compression algorithms, just in case. One might want to add even more.
pacman -S p7zip unrar

# to count lines of source code and comments
pacman -S cloc

# in case one wants to use vim. Subl might be more convenient though.

# lvim is installed in ~/.local/bin, has to be downloaded before making the dir unwritable
# Console-IDE: LunarVim
#pacman -S nvim
#LV_BRANCH='release-1.3/neovim-0.9' bash <(curl -s https://raw.githubusercontent.com/LunarVim/LunarVim/release-1.3/neovim-0.9/utils/installer/install.sh)

#git clone https://github.com/NvChad/NvChad ~/.config/nvim --depth 1 && nvim

# sublime-text setup
curl -O https://download.sublimetext.com/sublimehq-pub.gpg && sudo pacman-key --add sublimehq-pub.gpg && sudo pacman-key --lsign-key 8A8F901A && rm sublimehq-pub.gpg
echo -e "\n[sublime-text]\nServer = https://download.sublimetext.com/arch/stable/x86_64" | sudo tee -a /etc/pacman.conf
pacman -Syu sublime-text

# useful AUR tools:
# downgrade: use "sudo downgrade <package_name>" to downgrade a package
# fatrace:   use "sudo fatrace -f W" to view all filesystem writes
yay -S downgrade fatrace

# if one never uses all of the availible RAM, this tries to speed up launching applications by
# automatically loading often used files into RAM, although it may increase booting time.
# In case one wants to decide which applications should be loaded into RAM explicitly, gopreload-git should be used.
# One should keep in mind, that none of these tools receive updates anymore. They are probably considered being "done".
yay -S preload
sudo systemctl enable preload

# TensorFlow/Machine Learning, Nvidia should already be installed (by ArchInstall.sh)
# it is probably the easiest to run:
# pacman -S cuda cudnn python-tensorflow-opt-cuda # python-tensorflow for CPU

# mouse in tty (for copying and pasting). Normally already pulled when installing NetworManager
#pacman -S gpm
# change ExecStart in the service file to:
# ExecStart=/usr/bin/gpm -m /dev/psaux -t ps2 -2
#sudo systemctl enable gpm


#====Software====

# brave: browser (scaling bug on startup in hyprland is "solved" in the Hyprland IPC script)
# vscode: code editor (one might want to use the official "code" or AUR vscodium package instead)
# these are large binaries that will be compiled in RAM. Since RAM-Cache-Cleaning is done after an execution of yay only, some packages are split into multiple iterations.
yay -S brave-bin
yay -S visual-studio-code-bin
pacman -S gimp vlc hunspell hunspell-en_us hunspell-de libreoffice-still # -fresh

# does not work with Wayland/Hyprland
#pacman -S discord
#yay -S webcord-bin
yay -S discord-chat-exporter-cli

pacman -S obsidian
yay -S anki-bin
yay -S zotero-bin

# an alternative to downloading the AppImage from the official webpage
# yay -S tutanota-desktop-bin joplin

# to install pentesting tools e.g. nmap, hashcat, dirb, gobuster etc., add blackarch mirrors

# in combination with the LaTeX Workshop extension in VSCode:
# excludes texlive-fontsextra (it's package-size is ca. 1.5G and the fonts are most likely not needed)
pacman -Sgq texlive | grep -v texlive-fontsextra | pacman -S -
# making fonts available to Fontconfig
sudo ln -s /usr/share/fontconfig/conf.avail/09-texlive-fonts.conf /etc/fonts/conf.d/09-texlive-fonts.conf
fc-cache && mkfontscale && mkfontdir

# video-downloader
pacman -S yt-dlp ffmpeg

#yay -S ttf-ms-win11-auto

#====Security====

# files copied with su_cp will show a "permission denied" error message, which is normal as their permissions have been restricted even further
find /home/$USER_NAME -type f -exec chmod 600 {} \; -o -type d -exec chmod 700 {} \;

mkdir -p /home/$USER_NAME/.config/systemd
touch /home/$USER_NAME/.nanorc

locked_paths=(
  "/home/$USER_NAME/.bashrc"
  "/home/$USER_NAME/.bash_profile"
  "/home/$USER_NAME/.bash_logout"
  "/home/$USER_NAME/.p10k.zsh"
  "/home/$USER_NAME/.zshrc"
  "/home/$USER_NAME/.nanorc"
  #"/home/$USER_NAME/.nano"
  # some apps e.g. browseres are writing to .config all the time
  #/home/$USER_NAME/.config
  "/home/$USER_NAME/.config/systemd"
  "/home/$USER_NAME/.config/kitty"
  "/home/$USER_NAME/.config/swaylock"
  "/home/$USER_NAME/.config/ranger"
  # "/home/$USER_NAME/.config/hypr"
  # "/home/$USER_NAME/.config/nvim"
  "/home/$USER_NAME/.config/pacman"
)

# apply appropriate permissions to each path
for path in "${locked_paths[@]}"; do
  lock_permissions "$path"
done

# --confdir has to be writable for ranger to work
sudo chattr -i /home/$USER_NAME/.config/ranger
sudo chmod 700 /home/$USER_NAME/.config/ranger
# which makes malicious code-injection possible...
# sudo chattr +i /home/$USER_NAME/.config/ranger

mkdir -p /home/$USER_NAME/.local
# ~/.local is not executable due to /home being noexec
for dir in bin lib share; do
  sudo mkdir -p /opt/local_$USER_NAME/$dir
  sudo chown $USER_NAME /opt/local_$USER_NAME/$dir
  sudo mv /home/$USER_NAME/.local/$dir/* /opt/local_$USER_NAME/$dir
  rmdir /home/$USER_NAME/.local/$dir
  sudo ln -s /opt/local_$USER_NAME/$dir /home/$USER_NAME/.local/$dir
done

# making trash usable
# this makes trashing possible. However, the shortcut of Thunar does not work, not even with bind mount ("not able to trash across filesystem boundaries")
mkdir /home/$USER_NAME/.local/Trash
sudo rm -r /home/$USER_NAME/.local/share/Trash
sudo ln -s /home/$USER_NAME/.local/Trash /home/$USER_NAME/.local/share/Trash

pacman -S arch-audit

: '
pacman -S usbguard
# Warning: Make sure to actually configure the daemon before starting/enabling it or all USB devices, including keyboard and mouse, will immediately be blocked
# allow all devices connected at the current moment:
sudo usbguard generate-policy > /etc/usbguard/rules.conf
# disable the policy for a moment, revert my using block instead of allow (man usbguard)
# sudo usbguard set-parameter ImplicitPolicyTarget allow
sudo systemctl enable usbguard.service
sudo systemctl start usbguard.service
'

if pacman -Qi "apparmor" &> /dev/null; then
  uncomment "exec-once = aa-notify" /home/$USER_NAME/.config/hypr/hyprland.conf
  : '
  # run apparmor script
  # do this by moving everything as a separate file
  echo "
  @{XDG_PROJECTS_DIR}+="go"
  @{XDG_PASSWORD_STORE_DIR}+="@{HOME}/.keepass/"
  @{user_pkg_dirs}+=@{user_cache_dirs}/yay/
  " > /etc/apparmor.d/tunables/xdg-user-dirs.d/local

  # one could also add things like
  @{XDG_VIDEOS_DIR}+="Films"
  @{XDG_MUSIC_DIR}+="Musique"
  @{XDG_PICTURES_DIR}+="Images"
  @{XDG_BOOKS_DIR}+="BD" "Comics"
  @{XDG_PROJECTS_DIR}+="Git" "Papers"
  '
fi


#===Finishing===

pacman -S xorg-xauth

#Hyprland &
#sleep 4
#thunar
gsettings set org.gnome.desktop.interface gtk-theme "Arc-Dark"
gsettings set org.gnome.desktop.interface icon-theme "Papirus-Dark"
pacman -S xfconf
xfconf-query --create -t string -c xsettings -p /Net/ThemeName -s "Arc-Dark"
xfconf-query --create -t string -c xsettings -p /Net/IconThemeName -s "Papirus-Dark"

# in case X11 windows should be forwarded too. Currently, it would have to be run manually afterwards. Not used at the moment anyway though.
#sudo -u $USER_NAME xauth generate :0 . trusted
#sudo -u $BROWSER_USER_NAME xauth generate :0 . trusted
#sudo -u $USER_NAME xhost +SI:localuser:$BROWSER_USER_NAME

sudo du -sh ~/.cache
#rm -rf ~/.cache/*

# removing orphans:
#pacman -Rns $(pacman -Qdtq)
# informant: blocks pacman until all downloaded Arch-Newsletters are marked as read
yay -S informant

# always show diffs
yay --save --answerdiff All

# kill the sudo -v job
jobs
kill %1

reboot
