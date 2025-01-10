#!/bin/bash
set -e

## Default settings
export POOLNAME="rpool"				# Name of the root pool for ZFS on root
export DISTRO="server"				# Options: server, desktop
export RELEASE="noble"				# The short name of the release as it appears in the repository (mantic, jammy, etc)
export DISKNAME="sda"				# Enter the disk name only (sda, sdb, nvme1, etc)
export SWAPSIZE="4G"				# Enter swap size
export PASSPHRASE="strongpassword"	# Encryption passphrase for "${POOLNAME}"
export PASSWORD="password"			# temporary root password & password for ${USERNAME}
export HOSTNAME="notdroppi"			# hostname of the new machine
export USERNAME="droppi"			# user to create in the new machine
export MOUNTPOINT="/mnt"			# debootstrap target location
export LOCALE="en_US.UTF-8"			# New install language setting.
export TIMEZONE="UTC"				# New install timezone setting.
export refind_timeout="5"			# Timeout before rEFInd boots latest ZBM image
export zbm_timeout="-1" 			# Timeout before ZBM boots default OS [zbm.timeout=0 -> zbm.skip, zbm.timeout=-1 -> zbm.show]

## Auto-reboot at the end of installation? (true/false)
REBOOT="false"


#export DEBIAN_FRONTEND="noninteractive"

debootstrap_install(){
	## Export variables from live environment
	export_variables() {
		echo "------------> Exporting variables from live environment <------------"
		## Set apts
		export APT="/usr/bin/apt"
		
		## Export running distribution name
		source /etc/os-release
		export ID
		#export ID="${ID}_${DISTRO}_${RELEASE}"
		
		## Export disk variables
		export DISK="/dev/${DISKNAME}"
		export DISKID=/dev/disk/by-id/$(ls -al /dev/disk/by-id | grep ${DISKNAME} | awk '{print $9}' | head -1)
		
		export BOOT_DISK="${DISKID}"
		export BOOT_PART="1"
		export BOOT_DEVICE="${BOOT_DISK}-part${BOOT_PART}"
		
		export SWAP_DISK="${DISKID}"
		export SWAP_PART="2"
		export SWAP_DEVICE="${SWAP_DISK}-part${SWAP_PART}"
		
		export POOL_DISK="${DISKID}"
		export POOL_PART="3"
		export POOL_DEVICE="${POOL_DISK}-part${POOL_PART}"
	}

	## Install required packages in live environment
	install_packages_live_environment() {
		echo "------------> Installing packages in live environment <------------"
		apt update
		apt install -y debootstrap gdisk zfsutils-linux
		zgenhostid -f 0x00bab10c
	}

	## Wipe disk and create partitions
	disk_prepare() {
		echo "------------> Wipe disk and create partitions <------------"
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
	}

	## Create ZFS pool, create and mount datasets
	zfs_pool_create() {
		## Create zpool
		echo "------------> Create zpool and datasets <------------"
		echo "${PASSPHRASE}" >/etc/zfs/"${POOLNAME}".key
		#chmod 000 /etc/zfs/"${POOLNAME}".key
		
		zpool create -f -o ashift=12 \
			-O compression=zstd \
			-O acltype=posixacl \
			-O xattr=sa \
			-O atime=off \
			-O encryption=aes-256-gcm \
			-O keylocation=file:///etc/zfs/"${POOLNAME}".key \
			-O keyformat=passphrase \
			-m none "${POOLNAME}" "$POOL_DEVICE"
		
		sync
		sleep 2
		
		## Create datasets and set bootfs on zpool
		zfs create -o mountpoint=none "${POOLNAME}"/ROOT
		sync
		sleep 2
		zfs create -o mountpoint=/ -o canmount=noauto "${POOLNAME}"/ROOT/"${ID}"
		sync
		zpool set bootfs="${POOLNAME}"/ROOT/"${ID}" "${POOLNAME}"
		
		## Export, then re-import with a temporary mountpoint of "${MOUNTPOINT}"
		zpool export "${POOLNAME}"
		zpool import -N -R "${MOUNTPOINT}" "${POOLNAME}"
		
		## Remove the need for manual prompt of the passphrase TODO: reuse "/etc/zfs/"${POOLNAME}".key"????
		#echo "${PASSPHRASE}" >/tmp/zpass
		#sync
		#chmod 0400 /tmp/zpass
		zfs load-key -L file:///etc/zfs/"${POOLNAME}".key "${POOLNAME}"
		chmod 000 /etc/zfs/"${POOLNAME}".key
		#rm /tmp/zpass
		
		zfs mount "${POOLNAME}"/ROOT/"${ID}"
		
		## Update device symlinks
		udevadm trigger
	}

	## Debootstrap ubuntu
	ubuntu_debootstrap() {
		echo "------------> Debootstrap Ubuntu ${RELEASE} <------------"
		debootstrap ${RELEASE} "${MOUNTPOINT}"
		
		## Copy files into the new install
		cp /etc/hostid "${MOUNTPOINT}"/etc/hostid
		cp /etc/resolv.conf "${MOUNTPOINT}"/etc/
		mkdir "${MOUNTPOINT}"/etc/zfs
		cp /etc/zfs/"${POOLNAME}".key "${MOUNTPOINT}"/etc/zfs
		
		## Mount required dirs
		mount -t proc proc "${MOUNTPOINT}"/proc
		mount -t sysfs sys "${MOUNTPOINT}"/sys
		mount -B /dev "${MOUNTPOINT}"/dev
		mount -t devpts pts "${MOUNTPOINT}"/dev/pts
		
		## Set a hostname
		echo "$HOSTNAME" >"${MOUNTPOINT}"/etc/hostname
		echo "127.0.1.1       $HOSTNAME" >>"${MOUNTPOINT}"/etc/hosts
		
		## Set root passwd TODO: is this needed??
		chroot "${MOUNTPOINT}" /bin/bash -x <<-EOCHROOT
			echo -e "root:$PASSWORD" | chpasswd -c SHA256
		EOCHROOT
		
		# Set up APT sources
		cat <<-EOF >"${MOUNTPOINT}"/etc/apt/sources.list
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
		
		## Update repository cache, install locales and set locale and timezone
		chroot "$MOUNTPOINT" /bin/bash -x <<-EOCHROOT
			## Update respository and install locales and tzdata TODO: is locales not already installed after debootstrap?
			${APT} update
			${APT} install -y --no-install-recommends locales tzdata keyboard-configuration console-setup
			
			## Set locale # TODO: RE-AUTOMATE, BUT THEN ALSO SET: LC_CTYPE LC_MESSAGES LC_ALL AS LC_CTYPE="en_US.UTF-8" (note quotes in final file required)
			dpkg-reconfigure locales
			echo "============================================================================================================================================================"
				cat /etc/default/locale
			echo "============================================================================================================================================================"
			locale
			echo "============================================================================================================================================================"  
			#locale-gen en_US.UTF-8 $LOCALE
			#echo 'LANG="$LOCALE"' > /etc/default/locale
				#echo 'LANGUAGE="$LOCALE"' >> /etc/default/locale
			#echo 'LC_ALL="$LOCALE"' >> /etc/default/locale
				#echo 'LC_MESSAGE="$LOCALE"' >> /etc/default/locale
				#echo 'LC_CTYPE="$LOCALE"' >> /etc/default/locale
			
			## set timezone
			ln -fs /usr/share/zoneinfo/"$TIMEZONE" /etc/localtime

			## Set keyboard configuration and console TODO: Make the reconfigurations below selectable by variables
				dpkg-reconfigure keyboard-configuration console-setup
		EOCHROOT

		echo "------------> Upgrading all packages and installing linux-generic <------------"
		## Upgrade all packages and install linux-generic
		chroot "${MOUNTPOINT}" /bin/bash -x <<-EOCHROOT
			${APT} upgrade -y
			${APT} install -y --no-install-recommends linux-generic
		EOCHROOT
		
		## Install and configure required packages for ZFS and EFI/boot creation.
		chroot "${MOUNTPOINT}" /bin/bash -x <<-EOCHROOT
			## Install packages
			${APT} install -y dosfstools zfs-initramfs zfsutils-linux
			
			## Enable ZFS services
			systemctl enable zfs.target
			systemctl enable zfs-import-cache
			systemctl enable zfs-mount
			systemctl enable zfs-import.target
			
			## Set UMASK to prevent leaking of $POOLNAME.key
			echo "UMASK=0077" > /etc/initramfs-tools/conf.d/umask.conf
			
			## Update initramfs
			update-initramfs -c -k all
		EOCHROOT
	}

	## Setup swap partition
	create_swap() {
		echo "------------> Create swap partition <------------"
		echo swap "${DISKID}"-part2 /dev/urandom \
			plain,swap,cipher=aes-xts-plain64:sha256,size=512 >>"${MOUNTPOINT}"/etc/crypttab
		echo /dev/mapper/swap none swap defaults 0 0 >>"${MOUNTPOINT}"/etc/fstab
	}

	## Install ZFS Boot Menu
	ZBM_install() {
		# Create fstab entry
		echo "------------> Installing ZFSBootMenu <------------"
		cat <<-EOF >>${MOUNTPOINT}/etc/fstab
			$(blkid | grep -E "${DISK}(p)?${BOOT_PART}" | cut -d ' ' -f 2) /boot/efi vfat defaults 0 0
		EOF
		
		## Set zfs boot parameters
		chroot "${MOUNTPOINT}" /bin/bash -x <<-EOCHROOT
			zfs set org.zfsbootmenu:commandline="quiet splash loglevel=0" "${POOLNAME}"
			zfs set org.zfsbootmenu:keysource="${POOLNAME}"/ROOT/"${ID}" "${POOLNAME}"
		EOCHROOT
		
		## Format boot partition
		chroot "${MOUNTPOINT}" /bin/bash -x <<-EOCHROOT
			mkfs.vfat -v -F32 "$BOOT_DEVICE" # the EFI partition must be formatted as FAT32
			sync
			sleep 2
		EOCHROOT
		
		## Install ZBM and configure EFI boot entries
		chroot "${MOUNTPOINT}" /bin/bash -x <<-EOCHROOT
			## Create and mount /boot/efi
			mkdir -p /boot/efi
			mount /boot/efi
			mkdir -p /boot/efi/EFI/ZBM # TODO is this required?
			
			## Install packages to compile ZBM TODO: is efibootmgr required here? Or can be in EFI_install()?
			apt install -y --no-install-recommends \
				curl \
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
			-e 's|ManageImages:.*|ManageImages: true|' \
			-e 's|ImageDir:.*|ImageDir: /boot/efi/EFI/ZBM|' \
			-e 's|Versions:.*|Versions: 2|' \
			-e '/^Components:/,/^[^[:space:]]/ s|Enabled:.*|Enabled: true|' \
				-e '/^EFI:/,/^[^[:space:]]/ s|Enabled:.*|Enabled: false|' \
			-i /etc/zfsbootmenu/config.yaml
			
			###### \/ TODO: CHECK THE NAME OF THE CREATED EFI IMAGE \/ ######## name must match with names in EFI_install
			generate-zbm
			
			## Mount the efi variables filesystem
			mount -t efivarfs efivarfs /sys/firmware/efi/efivars
		EOCHROOT
	}

	## Create boot entry with efibootmgr
	EFI_install() {
		echo "------------> Installing efibootmgr <------------"
		chroot "${MOUNTPOINT}" /bin/bash -x <<-EOCHROOT
			## Install efibootmgr
			#${APT} install -y efibootmgr
			
			## Create backup boot EFI # TODO: when doing generate ZBM for the second+ time, copy the last as -backup?
			cp /boot/efi/EFI/ZBM/vmlinuz-bootmenu /boot/efi/EFI/ZBM/vmlinuz-bootmenu-BACKUP
			cp /boot/efi/EFI/ZBM/initramfs-bootmenu.img /boot/efi/EFI/ZBM/initramfs-bootmenu-BACKUP.img
			efibootmgr -c -d "$DISK" -p "$BOOT_PART" \
				-L "ZFSBootMenu (Backup)" \
				-l '\EFI\ZBM\vmlinuz-bootmenu-BACKUP' \
				-u "ro initrd=\EFI\ZBM\initramfs-bootmenu-BACKUP.img quiet"
			
			## Create main boot EFI
			efibootmgr -c -d "$DISK" -p "$BOOT_PART" \
				-L "ZFSBootMenu" \
				-l '\EFI\ZBM\vmlinuz-bootmenu' \
				-u "ro initrd=\EFI\ZBM\initramfs-bootmenu.img quiet"
			
			sync
			sleep 1
		EOCHROOT
	}

	rEFInd_install() {
		echo "------------> Installing rEFInd <------------"
		chroot "${MOUNTPOINT}" /bin/bash -x <<-EOCHROOT
			## Install rEFInd
			${APT} install -y refind

			## Set rEFInd timeout
			sed -i 's,^timeout .*,timeout $refind_timeout,' /boot/efi/EFI/refind/refind.conf
		EOCHROOT

		cat <<-EOF > ${MOUNTPOINT}/boot/efi/EFI/ZBM/refind_linux.conf
			"Boot default"  "quiet loglevel=0 zbm.timeout=${zbm_timeout}"
			"Boot to menu"  "quiet loglevel=0 zbm.show"
		EOF
	}



	## Setup tmp.mount for ram-based /tmp
	enable_tmpmount() {
		echo "------------> Enabling tmp.mount <----------------"
		chroot "${MOUNTPOINT}" /bin/bash -x <<-EOCHROOT
			cp /usr/share/systemd/tmp.mount /etc/systemd/system/ # TODO: is this required?
			systemctl enable tmp.mount
		EOCHROOT
	}

	## Create system groups and network setup
	config_netplan_yaml() {
		echo "------------> Configuring netplan yaml <----------------"
		ethernet_name=$(basename "$(find /sys/class/net -maxdepth 1 -mindepth 1 -name "e*")")
		cat <<-EOF >"${MOUNTPOINT}/etc/netplan/01-${ethernet_name}.yaml"
			network:
			version: 2
			renderer: networkd
			ethernets:
				enp1s0:
				dhcp4: yes
				dhcp6: yes
		EOF
	}

	## Create user TODO: CHANGE TO WHAT IS ON DROPPI ALREADY
	create_user() {
		echo "------------> Creating user $USERNAME <------------"
		chroot "${MOUNTPOINT}" /bin/bash -x <<-EOCHROOT
			adduser --disabled-password --gecos "" ${USERNAME}
			cp -a /etc/skel/. /home/${USERNAME}
			chown -R ${USERNAME}:${USERNAME} /home/${USERNAME}
			usermod -a -G adm,cdrom,dip,plugdev,sudo ${USERNAME}
			echo "${USERNAME} ALL=(ALL) NOPASSWD: ALL" >/etc/sudoers.d/${USERNAME}
			chown root:root /etc/sudoers.d/${USERNAME}
			chmod 400 /etc/sudoers.d/${USERNAME}
			echo -e "${USERNAME}:$PASSWORD" | chpasswd
		EOCHROOT
	}

	## Install distro bundle
	install_ubuntu() {
		echo "------------> Installing ${DISTRO} bundle <------------"
		chroot "${MOUNTPOINT}" /bin/bash -x <<-EOCHROOT
			## Upgrade full system
			${APT} dist-upgrade -y
			
			## Install selected distribution
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
		EOCHROOT
	}

	## Disable log gzipping as we already use compresion at filesystem level
	uncompress_logs() {
		echo "------------> Uncompress logs <------------"
		chroot "${MOUNTPOINT}" /bin/bash -x <<-EOCHROOT
			for file in /etc/logrotate.d/* ; do
				if grep -Eq "(^|[^#y])compress" "\${file}" ; then
					sed -i -r "s/(^|[^#y])(compress)/\1#\2/" "\${file}"
				fi
			done
		EOCHROOT
	}

	## Re-lock root account # TODO: when remove root password, can this be removed??
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

	
	## Install steps
	export_variables					# Export ID and disk variables in live environment
	install_packages_live_environment 	# Install debootstrap/zfs/gdisk in live environment
	disk_prepare						# Wipe disk and create boot/swap/zfs partitions
	zfs_pool_create 					# Create zpool, create datasets, mount datasets
	ubuntu_debootstrap
	create_swap
	ZBM_install
	rEFInd_install
	enable_tmpmount
	config_netplan_yaml
	create_user
	install_ubuntu
	uncompress_logs

	disable_root_login
	#cleanup

	if [[ ${REBOOT} =~ "true" ]]; then
	reboot
	fi
}

if ${debootstrap_install}; then
	debootstrap_install
fi