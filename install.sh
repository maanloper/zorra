#!/bin/bash
set -e

#TODO: set NTP server?

## General install-only settings
MOUNTPOINT="/mnt"							# Temporary debootstrap mount location in live environment


pre-install(){
	## Set default locales in live environment to prevent warnings during installation
	locale-gen en_US.UTF-8 ${LOCALE}
	echo 'LANG="${LOCALE}"' > /etc/default/locale
	echo 'LANGUAGE="${LOCALE}"' >> /etc/default/locale
	echo 'LC_ALL="${LOCALE}"' >> /etc/default/locale
	echo 'LC_MESSAGE="${LOCALE}"' >> /etc/default/locale
	echo 'LC_CTYPE="${LOCALE}"' >> /etc/default/locale
}

debootstrap_install(){
	export_variables() {
		## Export disk variables
		DISK="/dev/${DISKNAME}"
		DISKID=/dev/disk/by-id/$(ls -al /dev/disk/by-id | grep ${DISKNAME} | awk '{print $9}' | head -1)
		
		BOOT_PART="1"
		BOOT_DEVICE="${DISKID}-part${BOOT_PART}"
		
		SWAP_PART="2"
		SWAP_DEVICE="${DISKID}-part${SWAP_PART}"
		
		POOL_PART="3"
		POOL_DEVICE="${DISKID}-part${POOL_PART}"
	}

	install_packages_live_environment(){
		## Install required packages in live environment
		apt update
		apt install -y debootstrap gdisk zfsutils-linux
	}

	create_partitions(){
		## Wipe disk and create partitions
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
		
		sgdisk -n "${BOOT_PART}:1m:+${BOOTSIZE}" -t "${BOOT_PART}:EF00" "${DISKID}"
		sgdisk -n "${SWAP_PART}:0:+${SWAPSIZE}" -t "${SWAP_PART}:8200" "${DISKID}"
		sgdisk -n "${POOL_PART}:0:-10m" -t "${POOL_PART}:BF00" "${DISKID}"
		sync
		sleep 2
	}

	create_pool_and_datasets(){
		## Put password in keyfile and set permissions
		echo "${PASSPHRASE}" > "${keyfile}"
		chmod 000 "${keyfile}"
		
		## Generate hostid (used by ZFS for host-identification)
		zgenhostid -f

		## Create zpool TODO: check if -o bootfs="${POOLNAME}"/ROOT/"${INSTALL_DATASET}" is set OK
		zpool create -f -o ashift=12 \
			-O compression=zstd \
			-O acltype=posixacl \
			-O xattr=sa \
			-O atime=off \
			-O encryption=aes-256-gcm \
			-O keylocation="file://${keyfile}" \
			-O keyformat=passphrase \
			-o bootfs="${POOLNAME}"/ROOT/"${INSTALL_DATASET}" \
			-m none "${POOLNAME}" "$POOL_DEVICE"
		
		sync
		sleep 2
		##### TODO: can all syncs/sleeps be removed???
		## Create ROOT dataset
		zfs create -o mountpoint=none "${POOLNAME}"/ROOT
		sync
		sleep 2

		## Create OS installation dataset [TODO: stillneeded?: and set bootfs on zpool
		zfs create -o mountpoint=/ -o canmount=noauto "${POOLNAME}"/ROOT/"${INSTALL_DATASET}"
		sync
		#zpool set bootfs="${POOLNAME}"/ROOT/"${INSTALL_DATASET}" "${POOLNAME}"

		## Create keystore dataset 
		zfs create -o mountpoint=/etc/zfs/key "${POOLNAME}"/keystore
		
		## Export, then re-import with a temporary mountpoint of "${MOUNTPOINT}"
		zpool export "${POOLNAME}"
		zpool import -N -R "${MOUNTPOINT}" "${POOLNAME}"
		
		## Remove the need for manual prompt of the passphrase TODO: check can reuse "${keyfile}"????
		#echo "${PASSPHRASE}" >/tmp/zpass
		#sync
		#chmod 0400 /tmp/zpass
		zfs load-key -L "file://${keyfile}" "${POOLNAME}"
		#chmod 000 "${keyfile}"
		#rm /tmp/zpass
		
		zfs mount "${POOLNAME}"/ROOT/"${INSTALL_DATASET}"
		
		## Update device symlinks
		udevadm trigger
	}

	debootstrap_ubuntu(){
		## Debootstrap ubuntu
		debootstrap "${RELEASE}" "${MOUNTPOINT}"
		
		## Copy files into the new install
		cp /etc/hostid "${MOUNTPOINT}/etc/hostid"
		cp /etc/resolv.conf "${MOUNTPOINT}/etc/"
		mkdir -p "${MOUNTPOINT}/etc/zfs/key"
		cp "${keyfile}" "${MOUNTPOINT}/etc/zfs/key"
		chmod 000 "${MOUNTPOINT}${keyfile}"
		
		## Mount required dirs
		mount -t proc proc "${MOUNTPOINT}"/proc
		mount -t sysfs sys "${MOUNTPOINT}"/sys
		mount -B /dev "${MOUNTPOINT}"/dev
		mount -t devpts pts "${MOUNTPOINT}"/dev/pts
		
		## Set a hostname
		echo "$HOSTNAME" >"${MOUNTPOINT}"/etc/hostname
		echo "127.0.1.1       $HOSTNAME" >>"${MOUNTPOINT}"/etc/hosts
		
		## Set root passwd TODO: check is this needed??
		#chroot "${MOUNTPOINT}" /bin/bash -x <<-EOCHROOT
		#	echo -e "root:$PASSWORD" | chpasswd -c SHA256
		#EOCHROOT
		
		## Set up APT sources
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
			## Update respository and install locales and tzdata TODO: check is locales not already installed after debootstrap?
			apt update
			apt install -y apt-transport-https
			apt install -y --no-install-recommends locales tzdata keyboard-configuration console-setup
			
			## Set locale
			locale-gen en_US.UTF-8 ${LOCALE}
			echo 'LANG="${LOCALE}"' > /etc/default/locale
			echo 'LANGUAGE="${LOCALE}"' >> /etc/default/locale
			echo 'LC_ALL="${LOCALE}"' >> /etc/default/locale
			echo 'LC_MESSAGE="${LOCALE}"' >> /etc/default/locale
			echo 'LC_CTYPE="${LOCALE}"' >> /etc/default/locale
			cat /etc/default/locale
			locale
			
			## set timezone
			ln -fs /usr/share/zoneinfo/"${TIMEZONE}" /etc/localtime
		EOCHROOT

		## Upgrade all packages and install linux-generic
		chroot "${MOUNTPOINT}" /bin/bash -x <<-EOCHROOT
			apt upgrade -y
			apt install -y --no-install-recommends linux-generic
		EOCHROOT
		
		## Install and enable required packages for ZFS
		chroot "${MOUNTPOINT}" /bin/bash -x <<-EOCHROOT
			## Install packages
			apt install -y dosfstools zfs-initramfs zfsutils-linux
			
			## Enable ZFS services
			systemctl enable zfs.target
			systemctl enable zfs-import-cache
			systemctl enable zfs-mount
			systemctl enable zfs-import.target
			
			## Set UMASK to prevent leaking of zfsroot.key in initramfs to users on the system
			echo "UMASK=0077" > /etc/initramfs-tools/conf.d/umask.conf
		EOCHROOT
	}

	create_swap(){
		## Setup swap partition, using AES encryption with keysize 256 bits
		echo swap "${DISKID}"-part2 /dev/urandom \
			plain,swap,cipher=aes-xts-plain64:sha256,size=256 >>"${MOUNTPOINT}"/etc/crypttab
		echo /dev/mapper/swap none swap defaults 0 0 >>"${MOUNTPOINT}"/etc/fstab
	}

	install_zfsbootmenu(){
		## Create fstab entry
		echo "------------> Installing ZFSBootMenu <------------"
		cat <<-EOF >>${MOUNTPOINT}/etc/fstab
			$(blkid | grep -E "${DISK}(p)?${BOOT_PART}" | cut -d ' ' -f 2) /boot/efi vfat defaults 0 0
		EOF
		
		## Set zfs boot parameters
		chroot "${MOUNTPOINT}" /bin/bash -x <<-EOCHROOT
			zfs set org.zfsbootmenu:commandline="quiet splash loglevel=0" "${POOLNAME}"
			zfs set org.zfsbootmenu:keysource="${POOLNAME}/keystore" "${POOLNAME}"
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
			#mkdir -p /boot/efi/EFI/ZBM # TODO is this required?
			
			## Install packages to compile ZBM TODO: is efibootmgr required here? Or can be in EFI_install()?
			apt install -y --no-install-recommends \
				curl \
				libsort-versions-perl \
				libboolean-perl \
				libyaml-pp-perl \
				fzf \
				make \
				mbuffer \
				kexec-tools \
				dracut-core \
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
			
			## Generate the ZFSBootMenu components
			update-initramfs -c -k all 2>&1 | grep -v "cryptsetup: WARNING: Resume target swap uses a key file"
			generate-zbm
			
			## Mount the efi variables filesystem (TODO check is this needed?)
			#mount -t efivarfs efivarfs /sys/firmware/efi/efivars
		EOCHROOT
	}

	install_refind(){
		## Install and configure refind for ZBM
		chroot "${MOUNTPOINT}" /bin/bash -x <<-EOCHROOT
			## Install rEFInd
			apt install -y refind

			## Set rEFInd timeout
			sed -i 's,^timeout .*,timeout $refind_timeout,' /boot/efi/EFI/refind/refind.conf
		EOCHROOT

		cat <<-EOF > ${MOUNTPOINT}/boot/efi/EFI/ZBM/refind_linux.conf
			"Boot default"  "quiet loglevel=0 zbm.timeout=${zbm_timeout}"
			"Boot to menu"  "quiet loglevel=0 zbm.show"
		EOF
	}

	enable_tmpmount(){
		## Setup tmp.mount for ram-based /tmp
		chroot "${MOUNTPOINT}" /bin/bash -x <<-EOCHROOT
			cp /usr/share/systemd/tmp.mount /etc/systemd/system/
			systemctl enable tmp.mount
		EOCHROOT
	}

	config_netplan_yaml(){
		## Setup netplan yaml config to enable ethernet
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

	create_user(){
		## Create user
		chroot "${MOUNTPOINT}" /bin/bash -x <<-EOCHROOT
			useradd "${USERNAME}" --create-home --groups adm,cdrom,dip,plugdev,sudo
			echo -e "${USERNAME}:${PASSWORD}" | chpasswd
			chown -R "${USERNAME}":"${USERNAME}" "/home/${USERNAME}"
			chmod 700 "/home/${USERNAME}"
			chmod 600 "/home/${USERNAME}/.*
		EOCHROOT
	}

	install_ubuntu_server(){
		## Install distro bundle
		chroot "${MOUNTPOINT}" /bin/bash -x <<-EOCHROOT
			## Upgrade full system
			apt dist-upgrade -y

			## Install ubuntu server
			apt install -y ubuntu-server

			## Install additional packages TODO chek which are already installed AND remove non-ed2519 keys generated by OpenSSH
			#apt install -y --no-install-recommends \
			#	parted \
			#	openssh-server \
			#	git \
			#	nano
			#rm /etc/ssh/ssh_host_ecdsa*
			#rm /etc/ssh/ssh_host_rsa*
			#systemctl restart ssh
		EOCHROOT
	}

	uncompress_logs(){
		## Disable log gzipping as we already use compresion at filesystem level
		chroot "${MOUNTPOINT}" /bin/bash -x <<-EOCHROOT
			for file in /etc/logrotate.d/* ; do
				if grep -Eq "(^|[^#y])compress" "\${file}" ; then
					sed -i -r "s/(^|[^#y])(compress)/\1#\2/" "\${file}"
				fi
			done
		EOCHROOT
	}

	#disable_root_login() {
	#	echo "------------> Disable root login <------------"
	#	chroot "${MOUNTPOINT}" /bin/bash -x <<-EOCHROOT
	#		usermod -L root
	#	EOCHROOT
	#}
	
	configs_with_user_interactions(){
		## Set keyboard configuration and console
		dpkg-reconfigure keyboard-configuration console-setup
	}

	cleanup(){
		## Umount target and final cleanup
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
	create_partitions					# Wipe disk and create boot/swap/zfs partitions
	create_pool_and_datasets 			# Create zpool, create datasets, mount datasets
	debootstrap_ubuntu
	create_swap
	install_zfsbootmenu
	install_refind
	enable_tmpmount
	config_netplan_yaml
	create_user
	install_ubuntu_server
	uncompress_logs
	###disable_root_login
	configs_with_user_interactions
	#cleanup

	cat <<-EOF

		Debootstrap installation of Ubuntu Server (release: ${RELEASE}) completed
		After rebooting into the new system, run zorra to view available post-reboot options, such as:
		  - Setup remote access with authorized keys
		  - Auto-unlock storage pools
		  - Set rEFInd and ZBM timeouts
		  - Set a rEFInd theme
		
	EOF
}

if ${debootstrap_install}; then
	debootstrap_install
fi