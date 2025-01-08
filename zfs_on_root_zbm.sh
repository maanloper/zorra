#!/bin/bash
#
########################
# Change ${RUN} to true to execute the script
RUN="true"

# Variables - Populate/tweak this before launching the script
export DISTRO="server"           #server, desktop
export RELEASE="noble"           # The short name of the release as it appears in the repository (mantic, jammy, etc)
export DISK="sda"                 # Enter the disk name only (sda, sdb, nvme1, etc)
export SWAPSIZE="4G"		# Enter swap size
export PASSPHRASE="strongpassword" # Encryption passphrase for "${POOLNAME}"
export PASSWORD="password"      # temporary root password & password for ${USERNAME}
export HOSTNAME="notdroppi"          # hostname of the new machine
export USERNAME="droppi"          # user to create in the new machine
export MOUNTPOINT="/mnt"          # debootstrap target location
export LOCALE="en_US.UTF-8"       # New install language setting.
export TIMEZONE="UTC"     # New install timezone setting.
export RTL8821CE="false"          # Download and install RTL8821CE drivers as the default ones are faulty

## Auto-reboot at the end of installation? (true/false)
REBOOT="false"

########################################################################
#### Enable/disable debug. Only used during the development phase.
DEBUG="false"
########################################################################
########################################################################
########################################################################
POOLNAME="zroot" #"${POOLNAME}" is the default name used in the HOW TO from ZFSBootMenu. You can change it to whateven you want

if [[ ${RUN} =~ "false" ]]; then
  echo "Refusing to run as \$RUN is set to false"
  exit 1
fi

DISKID=/dev/disk/by-id/$(ls -al /dev/disk/by-id | grep ${DISK} | awk '{print $9}' | head -1)
export DISKID
DISK="/dev/${DISK}"
export APT="/usr/bin/apt"
#export DEBIAN_FRONTEND="noninteractive"

git_check() {
  if [[ ! -x /usr/bin/git ]]; then
    apt install -y git
  fi
}

debug_me() {
  if [[ ${DEBUG} =~ "true" ]]; then
    echo "BOOT_DEVICE: ${BOOT_DEVICE}"
    echo "SWAP_DEVICE: ${SWAP_DEVICE}"
    echo "POOL_DEVICE: ${POOL_DEVICE}"
    echo "DISK: ${DISK}"
    echo "DISKID: ${DISKID}"
    if [[ -x /usr/sbin/fdisk ]]; then
      /usr/sbin/fdisk -l "${DISKID}"
    fi
    if [[ -x /usr/sbin/blkid ]]; then
      /usr/sbin/blkid "${DISKID}"
    fi
    read -rp "Hit enter to continue"
    if [[ -x /usr/sbin/zpool ]]; then
      /usr/sbin/zpool status "${POOLNAME}"
    fi
  fi
}

source /etc/os-release
export ID
export BOOT_DISK="${DISKID}"
export BOOT_PART="1"
export BOOT_DEVICE="${BOOT_DISK}-part${BOOT_PART}"

export SWAP_DISK="${DISKID}"
export SWAP_PART="2"
export SWAP_DEVICE="${SWAP_DISK}-part${SWAP_PART}"

export POOL_DISK="${DISKID}"
export POOL_PART="3"
export POOL_DEVICE="${POOL_DISK}-part${POOL_PART}"

debug_me

# Start installation
initialize() {
  apt update
  apt install -y debootstrap gdisk zfsutils-linux vim git curl nala
  zgenhostid -f 0x00bab10c
}

# Disk preparation
disk_prepare() {
  debug_me

  wipefs -a "${DISKID}"
  blkdiscard -f "${DISKID}"
  sgdisk --zap-all "${DISKID}"
  sync
  sleep 2

  ## gdisk hex codes:
  ## EF02 BIOS boot partitions
  ## EF00 EFI system
  ## BE00 Solaris boot
  ## BF00 Solaris root
  ## BF01 Solaris /usr & Mac Z
  ## 8200 Linux swap
  ## 8300 Linux file system
  ## FD00 Linux RAID

  sgdisk -n "${BOOT_PART}:1m:+512m" -t "${BOOT_PART}:EF00" "${BOOT_DISK}"
  sgdisk -n "${SWAP_PART}:0:+${SWAPSIZE}" -t "${SWAP_PART}:8200" "${SWAP_DISK}"
  sgdisk -n "${POOL_PART}:0:-10m" -t "${POOL_PART}:BF00" "${POOL_DISK}"
  sync
  sleep 2
  debug_me
}

# ZFS pool creation
zfs_pool_create() {
  # Create the zpool
  echo "------------> Create zpool <------------"
  echo "${PASSPHRASE}" >/etc/zfs/"${POOLNAME}".key
  chmod 000 /etc/zfs/"${POOLNAME}".key

  zpool create -f -o ashift=12 \
    -O compression=lz4 \
    -O acltype=posixacl \
    -O xattr=sa \
    -O relatime=on \
    -O encryption=aes-256-gcm \
    -O keylocation=file:///etc/zfs/"${POOLNAME}".key \
    -O keyformat=passphrase \
    -o autotrim=on \
    -o compatibility=openzfs-2.1-linux \
    -m none "${POOLNAME}" "$POOL_DEVICE"

  sync
  sleep 2

  # Create initial file systems
  zfs create -o mountpoint=none "${POOLNAME}"/ROOT
  sync
  sleep 2
  zfs create -o mountpoint=/ -o canmount=noauto "${POOLNAME}"/ROOT/"${ID}"
  zfs create -o mountpoint=/home "${POOLNAME}"/home
  sync
  zpool set bootfs="${POOLNAME}"/ROOT/"${ID}" "${POOLNAME}"

  # Export, then re-import with a temporary mountpoint of "${MOUNTPOINT}"
  zpool export "${POOLNAME}"
  zpool import -N -R "${MOUNTPOINT}" "${POOLNAME}"
  ## Remove the need for manual prompt of the passphrase
  echo "${PASSPHRASE}" >/tmp/zpass
  sync
  chmod 0400 /tmp/zpass
  zfs load-key -L file:///tmp/zpass "${POOLNAME}"
  rm /tmp/zpass

  zfs mount "${POOLNAME}"/ROOT/"${ID}"
  zfs mount "${POOLNAME}"/home

  # Update device symlinks
  udevadm trigger
  debug_me
}

# Install Ubuntu
ubuntu_debootstrap() {
  echo "------------> Debootstrap Ubuntu ${RELEASE} <------------"
  debootstrap ${RELEASE} "${MOUNTPOINT}"

  # Copy files into the new install
  cp /etc/hostid "${MOUNTPOINT}"/etc/hostid
  cp /etc/resolv.conf "${MOUNTPOINT}"/etc/
  mkdir "${MOUNTPOINT}"/etc/zfs
  cp /etc/zfs/"${POOLNAME}".key "${MOUNTPOINT}"/etc/zfs

  # Chroot into the new OS
  mount -t proc proc "${MOUNTPOINT}"/proc
  mount -t sysfs sys "${MOUNTPOINT}"/sys
  mount -B /dev "${MOUNTPOINT}"/dev
  mount -t devpts pts "${MOUNTPOINT}"/dev/pts

  # Set a hostname
  echo "$HOSTNAME" >"${MOUNTPOINT}"/etc/hostname
  echo "127.0.1.1       $HOSTNAME" >>"${MOUNTPOINT}"/etc/hosts

  # Set root passwd
  chroot "${MOUNTPOINT}" /bin/bash -x <<-EOCHROOT
  echo -e "root:$PASSWORD" | chpasswd -c SHA256
EOCHROOT

  # Set up APT sources
  cat <<EOF >"${MOUNTPOINT}"/etc/apt/sources.list
# Uncomment the deb-src entries if you need source packages

deb http://archive.ubuntu.com/ubuntu/ ${RELEASE} main restricted universe multiverse
# deb-src http://archive.ubuntu.com/ubuntu/ ${RELEASE} main restricted universe multiverse

deb http://archive.ubuntu.com/ubuntu/ ${RELEASE}-updates main restricted universe multiverse
# deb-src http://archive.ubuntu.com/ubuntu/ ${RELEASE}-updates main restricted universe multiverse

deb http://archive.ubuntu.com/ubuntu/ ${RELEASE}-security main restricted universe multiverse
# deb-src http://archive.ubuntu.com/ubuntu/ ${RELEASE}-security main restricted universe multiverse

deb http://archive.ubuntu.com/ubuntu/ ${RELEASE}-backports main restricted universe multiverse
# deb-src http://archive.ubuntu.com/ubuntu/ ${RELEASE}-backports main restricted universe multiverse
EOF

  # Update the repository cache and system, install base packages, set up
  # console properties
  chroot "${MOUNTPOINT}" /bin/bash -x <<-EOCHROOT
  ${APT} update
  ${APT} upgrade -y
  ${APT} install -y --no-install-recommends linux-generic locales keyboard-configuration console-setup curl nala git
EOCHROOT

  chroot "$MOUNTPOINT" /bin/bash -x <<-EOCHROOT
		##4.5 configure basic system
		locale-gen en_US.UTF-8 $LOCALE
		echo 'LANG="$LOCALE"' > /etc/default/locale

		##set timezone
		ln -fs /usr/share/zoneinfo/"$TIMEZONE" /etc/localtime
    # TODO: Make the reconfigurations below selectable by variables
		#dpkg-reconfigure locales tzdata keyboard-configuration console-setup
    dpkg-reconfigure keyboard-configuration
EOCHROOT

  # ZFS Configuration
  chroot "${MOUNTPOINT}" /bin/bash -x <<-EOCHROOT
  ${APT} install -y dosfstools zfs-initramfs zfsutils-linux curl vim wget git
  systemctl enable zfs.target
  systemctl enable zfs-import-cache
  systemctl enable zfs-mount
  systemctl enable zfs-import.target
  echo "UMASK=0077" > /etc/initramfs-tools/conf.d/umask.conf
  update-initramfs -c -k all
EOCHROOT
}

ZBM_install() {
  # Install and configure ZFSBootMenu
  # Set ZFSBootMenu properties on datasets
  # Create a vfat filesystem
  # Create an fstab entry and mount
  echo "------------> Installing ZFSBootMenu <------------"
  cat <<EOF >>${MOUNTPOINT}/etc/fstab
$(blkid | grep -E "${DISK}(p)?${BOOT_PART}" | cut -d ' ' -f 2) /boot/efi vfat defaults 0 0
EOF

  debug_me
  ## Set zfs boot parameters and format boot partition
  chroot "${MOUNTPOINT}" /bin/bash -x <<-EOCHROOT
  zfs set org.zfsbootmenu:commandline="quiet loglevel=4 splash" "${POOLNAME}"/ROOT
  zfs set org.zfsbootmenu:keysource="${POOLNAME}"/ROOT/"${ID}" "${POOLNAME}"
  mkfs.vfat -v -F32 "$BOOT_DEVICE" # the EFI partition must be formatted as FAT32
  sync
  sleep 2
EOCHROOT

  ## Install ZBM and configure EFI boot entries
  chroot "${MOUNTPOINT}" /bin/bash -x <<-EOCHROOT
  mkdir -p /boot/efi
  mount /boot/efi
  mkdir -p /boot/efi/EFI/ZBM

  ## Install packages to compile ZBM
  apt install \
    libsort-versions-perl \
    libboolean-perl \
    libyaml-pp-perl \
    git \
    fzf \
    make \
    mbuffer \
    kexec-tools \
    dracut-core \
    efibootmgr \
    bsdextrautils

  ## Compile ZBM from source
  mkdir -p /usr/local/src/zfsbootmenu
  cd /usr/local/src/zfsbootmenu
  curl -L https://get.zfsbootmenu.org/source | tar -zxv --strip-components=1 -f -
  make core dracut
  
  ## Update ZBM configuration file
  sed \
  -e 's,ManageImages:.*,ManageImages: true,' \
  -e 's@ImageDir:.*@ImageDir: /boot/efi/EFI/ZBM@' \
  -e 's,Versions:.*,Versions: false,' \
  -i /etc/zfsbootmenu/config.yaml

###### \/ TODO: CHECK THE NAME OF THE CREATED EFI IMAGE \/ ######## name must match with names in EFI_install
  generate-zbm
  cp /boot/efi/EFI/ZBM/VMLINUZ.EFI /boot/efi/EFI/ZBM/VMLINUZ-BACKUP.EFI

  ## Mount the efi variables filesystem
  mount -t efivarfs efivarfs /sys/firmware/efi/efivars
EOCHROOT
}

# Create boot entry with efibootmgr
EFI_install() {
  echo "------------> Installing efibootmgr <------------"
  debug_me
  chroot "${MOUNTPOINT}" /bin/bash -x <<-EOCHROOT
${APT} install -y efibootmgr
efibootmgr -c -d "$DISK" -p "$BOOT_PART" \
  -L "ZFSBootMenu (Backup)" \
  -l '\EFI\ZBM\VMLINUZ-BACKUP.EFI'

efibootmgr -c -d "$DISK" -p "$BOOT_PART" \
  -L "ZFSBootMenu" \
  -l '\EFI\ZBM\VMLINUZ.EFI'

sync
sleep 1
debug_me
EOCHROOT
}

# Setup swap partition

create_swap() {
  echo "------------> Create swap partition <------------"

  debug_me
  echo swap "${DISKID}"-part2 /dev/urandom \
    swap,cipher=aes-xts-plain64:sha256,size=512 >>"${MOUNTPOINT}"/etc/crypttab
  echo /dev/mapper/swap none swap defaults 0 0 >>"${MOUNTPOINT}"/etc/fstab
}

# Create system groups and network setup
groups_and_networks() {
  echo "------------> Setup groups and networks <----------------"
  chroot "${MOUNTPOINT}" /bin/bash -x <<-EOCHROOT
  cp /usr/share/systemd/tmp.mount /etc/systemd/system/
  systemctl enable tmp.mount
  addgroup --system lpadmin
  addgroup --system lxd
  addgroup --system sambashare

  echo "network:" >/etc/netplan/01-network-manager-all.yaml
  echo "  version: 2" >>/etc/netplan/01-network-manager-all.yaml
  echo "  renderer: NetworkManager" >>/etc/netplan/01-network-manager-all.yaml
EOCHROOT
}

# Create user
create_user() {
  chroot "${MOUNTPOINT}" /bin/bash -x <<-EOCHROOT
  adduser --disabled-password --gecos "" ${USERNAME}
  cp -a /etc/skel/. /home/${USERNAME}
  chown -R ${USERNAME}:${USERNAME} /home/${USERNAME}
  usermod -a -G adm,cdrom,dip,lpadmin,lxd,plugdev,sambashare,sudo ${USERNAME}
  echo "${USERNAME} ALL=(ALL) NOPASSWD: ALL" >/etc/sudoers.d/${USERNAME}
  chown root:root /etc/sudoers.d/${USERNAME}
  chmod 400 /etc/sudoers.d/${USERNAME}
  echo -e "${USERNAME}:$PASSWORD" | chpasswd
EOCHROOT
}

# Install distro bundle
install_ubuntu() {
  echo "------------> Installing ${DISTRO} bundle <------------"
  chroot "${MOUNTPOINT}" /bin/bash -x <<-EOCHROOT
    ${APT} dist-upgrade -y

    debug_me

    #TODO: Unlock more cases

		case "${DISTRO}" in
		server)
		##Server installation has a command line interface only.
		##Minimal install: ubuntu-server-minimal
		${APT} install -y ubuntu-server
		;;
		desktop)
		##Ubuntu default desktop install has a full GUI environment.
		##Minimal install: ubuntu-desktop-minimal
			${APT} install -y ubuntu-desktop
		;;
    *)
    echo "No distro selected."
    ;;
    esac
		# 	kubuntu)
		# 		##Ubuntu KDE plasma desktop install has a full GUI environment.
		# 		##Select sddm as display manager.
		# 		echo sddm shared/default-x-display-manager select sddm | debconf-set-selections
		# 		${APT} install --yes kubuntu-desktop
		# 	;;
		# 	xubuntu)
		# 		##Ubuntu xfce desktop install has a full GUI environment.
		# 		##Select lightdm as display manager.
		# 		echo lightdm shared/default-x-display-manager select lightdm | debconf-set-selections
		# 		${APT} install --yes xubuntu-desktop
		# 	;;
		# 	budgie)
		# 		##Ubuntu budgie desktop install has a full GUI environment.
		# 		##Select lightdm as display manager.
		# 		echo lightdm shared/default-x-display-manager select lightdm | debconf-set-selections
		# 	;;
		# 	MATE)
		# 		##Ubuntu MATE desktop install has a full GUI environment.
		# 		##Select lightdm as display manager.
		# 		echo lightdm shared/default-x-display-manager select lightdm | debconf-set-selections
		# 		${APT} install --yes ubuntu-mate-desktop
		# 	;;
    # esac
EOCHROOT
}

# Disable log gzipping as we already use compresion at filesystem level
uncompress_logs() {
  echo "------------> Uncompress logs <------------"
  chroot "${MOUNTPOINT}" /bin/bash -x <<-EOCHROOT
  for file in /etc/logrotate.d/* ; do
    if grep -Eq "(^|[^#y])compress" "/etc/logrotate.d/${file}" ; then
        sed -i -r "s/(^|[^#y])(compress)/\1#\2/" "${file}"
    fi
  done
EOCHROOT
}

# re-lock root account
disable_root_login() {
  echo "------------> Disable root login <------------"
  chroot "${MOUNTPOINT}" /bin/bash -x <<-EOCHROOT
  usermod -L root
EOCHROOT
}

#Umount target and final cleanup
cleanup() {
  echo "------------> Final cleanup <------------"
  umount -n -R "${MOUNTPOINT}"
  sync
  sleep 5
  umount -n -R "${MOUNTPOINT}" >/dev/null 2>&1

  zpool export "${POOLNAME}"
}

# Download and install RTL8821CE drivers
rtl8821ce_install() {
  echo "------------> Installing RTL8821CE drivers <------------"
  chroot "${MOUNTPOINT}" /bin/bash -x <<-EOCHROOT
  ${APT} install -y bc module-assistant build-essential dkms
  m-a prepare
  cd /root
  ${APT} install -y git
  /usr/bin/git clone https://github.com/tomaspinho/rtl8821ce.git
  cd rtl8821ce
  ./dkms-install.sh
  zfs set org.zfsbootmenu:commandline="quiet loglevel=4 splash pcie_aspm=off" "${POOLNAME}"/ROOT
  echo "blacklist rtw88_8821ce" >> /etc/modprobe.d/blacklist.conf
EOCHROOT
}

################################################################
# MAIN Program
initialize
disk_prepare
zfs_pool_create
ubuntu_debootstrap
create_swap
ZBM_install
EFI_install
rEFInd_install
groups_and_networks
create_user
install_ubuntu
uncompress_logs
if [[ ${RTL8821CE} =~ "true" ]]; then
  rtl8821ce_install
fi
disable_root_login
cleanup

if [[ ${REBOOT} =~ "true" ]]; then
  reboot
fi
