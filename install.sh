#!/bin/bash
set -e

debootstrap_install(){
	get_install_inputs(){
		## Get input for user-defined variables
		prompt_input codename "short name of release (e.g. noble) to install"
		ls -l /dev/disk/by-id | grep -v part | sort | awk '{print $11 " " $10 " " $9}'
		prompt_input disk_name "disk name (e.g. sda, nvme1, etc.)"
		prompt_input passphrase "passphrase for disk encryption" confirm
		prompt_input hostname "hostname"
		prompt_input username "username"
		prompt_input password "password for user '${username}'" confirm
		prompt_input ssh_authorized_key "OpenSSH key for user '${username}' for key-based login"
	}

	set_install_variables(){
		## Set general variables
		mountpoint="/mnt" # Temporary debootstrap mount location in live environment
		disk="/dev/${disk_name}"
		disk_id=/dev/disk/by-id/$(ls -al /dev/disk/by-id | grep ${disk_name} | awk '{print $9}' | head -1)
		boot_part="1"
		swap_part="2"
		pool_part="3"

		## Set install_dataset name by extracting release (e.g. 24.04) from Ubuntu wiki
		release=$(curl -s https://wiki.ubuntu.com/Releases | awk -v search="$codename" 'tolower($0) ~ tolower(search) {print prev} {prev=$0}' | grep -Eo '[0-9]{2}\.[0-9]{2}' | head -1)
		install_dataset="ubuntu_server_${release}" # Dataset name to install ubuntu server to

		## Export locales to prevent warnings about unset locales during installation while chrooted TODO: check if this works or needed to set /etc/default/locale DOES NOT WORK!
		export "LANG=${locale}"
		export "LANGUAGE=${locale}"
		export "LC_ALL=${locale}"
	}

	install_packages_live_environment(){
		## Install required packages in live environment
		apt update
		apt install -y debootstrap gdisk zfsutils-linux
	}

	create_partitions(){
		## Wipe disk and create partitions
		wipefs -a "${disk_id}"
		blkdiscard -f "${disk_id}"
		sgdisk --zap-all "${disk_id}"
		sync
		sleep 2
		
		## Format disk using sgdisk hex codes (view with 'sgdisk -L')
		sgdisk -n "${boot_part}:1m:+${boot_size}" -t "${boot_part}:EF00" "${disk_id}"
		sgdisk -n "${swap_part}:0:+${swap_size}" -t "${swap_part}:8200" "${disk_id}"
		sgdisk -n "${pool_part}:0:-10m" -t "${pool_part}:BF00" "${disk_id}"
		sync
		sleep 2
	}

	create_pool_and_datasets(){
		## Generate hostid (used by ZFS for host-identification)
		zgenhostid -f

		## Put passphrase in keyfile on live environment
		mkdir -p $(dirname "${keyfile}")
		echo "${passphrase}" > "${keyfile}"

		## Create zpool
		zpool create -f -o ashift=12 \
			-O compression=zstd \
			-O acltype=posixacl \
			-O xattr=sa \
			-O normalization=formD \
			-O atime=off \
			-O encryption=aes-256-gcm \
			-O keylocation="file://${keyfile}" \
			-O keyformat=passphrase \
			-O canmount=off \
			-m none "${root_pool_name}" "${disk_id}-part${pool_part}"
		
		sync
		sleep 2

		##### TODO: can all syncs/sleeps be removed???
		## Create ROOT dataset
		zfs create -o mountpoint=none -o canmount=off "${root_pool_name}"/ROOT
		sync
		sleep 2

		## Create OS installation dataset
		zfs create -o mountpoint=/ -o canmount=noauto "${root_pool_name}/ROOT/${install_dataset}"
		sync
		zpool set bootfs="${root_pool_name}/ROOT/${install_dataset}" "${root_pool_name}"

		## Create keystore dataset (temporarily set with canmount=off to prevent auto-mounting after re-import, reset to 'on' in debootstrap step)
		zfs create -o mountpoint=/etc/zfs/key -o canmount=off "${root_pool_name}/keystore"
		
		## Export, then re-import with a temporary mountpoint of "${mountpoint}"
		zpool export "${root_pool_name}"
		zpool import -l -R "${mountpoint}" "${root_pool_name}"

		## Mount the install dataset
		zfs mount "${root_pool_name}/ROOT/${install_dataset}"

		## Update device symlinks
		udevadm trigger
	}

	debootstrap_ubuntu(){
		## Debootstrap ubuntu
		debootstrap "${codename}" "${mountpoint}"
		
		## Mount required dirs
		mount -t proc proc "${mountpoint}/proc"
		mount -t sysfs sys "${mountpoint}/sys"
		mount -B /dev "${mountpoint}/dev"
		mount -t devpts pts "${mountpoint}/dev/pts"
		
		## Copy hostid and resolv.conf to the new install
		cp /etc/hostid "${mountpoint}/etc/hostid"
		cp /etc/resolv.conf "${mountpoint}/etc/"

		## Set a hostname 
		echo "${hostname}" >"${mountpoint}/etc/hostname"
		echo "127.0.1.1       $hostname" >>"${mountpoint}/etc/hosts" # Spaces to match spacing in original file

		## Set default locale
		echo "LANG=${locale}" > "${mountpoint}/etc/default/locale"
		echo "LANGUAGE=${locale}" >> "${mountpoint}/etc/default/locale"
		echo "LC_ALL=${locale}" >> "${mountpoint}/etc/default/locale"

		## Reset canmount and mount keystore, copy keyfile to the dataset in the new install and set permissions
		zfs set canmount=on "${root_pool_name}/keystore"
		zfs mount "${root_pool_name}/keystore"
		cp "${keyfile}" "${mountpoint}/etc/zfs/key"
		chmod 000 "${mountpoint}${keyfile}"
		
		## Copy APT sources to new install and set it to https
		cp /etc/apt/sources.list.d/ubuntu.sources "${mountpoint}/etc/apt/sources.list.d/ubuntu.sources"
		sed -i 's|http://|https://|g' "${mountpoint}/etc/apt/sources.list.d/ubuntu.sources"
		
		## Update repository cache, generate locale, upgrade all packages, install required packages and set timezone
		chroot "$mountpoint" /bin/bash -x <<-EOCHROOT
			## Generate locale
			locale-gen en_US.UTF-8 ${locale}

			## Update respository, upgrade all current packages and install required packages
			apt update
			apt upgrade -y
			apt install -y --no-install-recommends tzdata keyboard-configuration console-setup linux-generic
			
			## Set timezone
			ln -fs "/usr/share/zoneinfo/${timezone}" /etc/localtime

			## Set NTP server
			echo "NTP=pool.ntp.org" >> /etc/systemd/timesyncd.conf
		EOCHROOT
		
		## Install and enable required packages for ZFS
		chroot "${mountpoint}" /bin/bash -x <<-EOCHROOT
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
		echo "swap ${disk_id}-part${swap_part} /dev/urandom plain,swap,cipher=aes-xts-plain64:sha256,size=256" >>"${mountpoint}"/etc/crypttab
		echo /dev/mapper/swap none swap defaults 0 0 >>"${mountpoint}"/etc/fstab
	}

	install_zfsbootmenu(){
		## Format boot partition (EFI partition must be formatted as FAT32)
		mkfs.vfat -v -F32 "${disk_id}-part${boot_part}"
		sync
		sleep 2

		## Create fstab entry for boot partition
		cat <<-EOF >>"${mountpoint}/etc/fstab"
			$(blkid | grep -E "${disk}(p)?${boot_part}" | cut -d ' ' -f 2) /boot/efi vfat defaults 0 0
		EOF
		
		## Install ZFSBootMenu and configure EFI boot entries
		chroot "${mountpoint}" /bin/bash -x <<-EOCHROOT
			## Create and mount /boot/efi
			mkdir -p /boot/efi
			mount /boot/efi
			
			## Install packages to compile ZFSBootMenu
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

			## Set ZFSBootMenu parameters TODO: check if these are set correctly or chroot is needed again
			zfs set org.zfsbootmenu:commandline="quiet splash loglevel=0" "${root_pool_name}"
			zfs set org.zfsbootmenu:keysource="${root_pool_name}/keystore" "${root_pool_name}"
		EOCHROOT
	}

	install_refind(){
		## Install and configure rEFInd
		chroot "${mountpoint}" /bin/bash -x <<-EOCHROOT
			## Mount the efi variables filesystem
			mount -t efivarfs efivarfs /sys/firmware/efi/efivars

			## Install rEFInd
			DEBIAN_FRONTEND=noninteractive apt install -y refind

			## Set rEFInd timeout
			sed -i 's|^timeout .*|timeout $refind_timeout|' /boot/efi/EFI/refind/refind.conf
		EOCHROOT

		## Set ZFSBootMenu config for rEFInd
		cat <<-EOF > ${mountpoint}/boot/efi/EFI/ZBM/refind_linux.conf
			"Boot default"  "quiet loglevel=0 zbm.timeout=${zbm_timeout}"
			"Boot to menu"  "quiet loglevel=0 zbm.show"
		EOF
	}

	enable_tmpmount(){
		## Setup tmp.mount for ram-based /tmp
		chroot "${mountpoint}" /bin/bash -x <<-EOCHROOT
			cp /usr/share/systemd/tmp.mount /etc/systemd/system/
			systemctl enable tmp.mount
		EOCHROOT
	}

	config_netplan_yaml(){
		## Setup netplan yaml config to enable ethernet
		ethernet_name=$(basename "$(find /sys/class/net -maxdepth 1 -mindepth 1 -name "e*")")
		cat <<-EOF >"${mountpoint}/etc/netplan/01-${ethernet_name}.yaml"
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
		chroot "${mountpoint}" /bin/bash -x <<-EOCHROOT
			useradd "${username}" --create-home --groups adm,cdrom,dip,plugdev,sudo
			echo -e "${username}:${password}" | chpasswd
			chown -R "${username}":"${username}" "/home/${username}"
			chmod 700 "/home/${username}"
			chmod 600 "/home/${username}/."*
		EOCHROOT
	}

	install_ubuntu_server(){
		## Install distro bundle
		chroot "${mountpoint}" /bin/bash -x <<-EOCHROOT
			## Upgrade full system
			apt dist-upgrade -y

			## Install ubuntu server
			apt install -y ubuntu-server

			## Install additional packages
			apt install -y --no-install-recommends \
				openssh-server \
				nano
			
			## Remove non-ed25519 host keys
			rm /etc/ssh/ssh_host_ecdsa*
			rm /etc/ssh/ssh_host_rsa*

			## Add OpenSSH public key to authorized_keys file of user and set ownership and permissions
			mkdir -p /home/${username}/.ssh
			echo "${ssh_authorized_key}" > "/home/${username}/.ssh/authorized_keys"
			chown -R "${username}":"${username}" "/home/${username}/.ssh"
			chmod 700 "/home/${username}/.ssh"
			chmod 600 "/home/${username}/.ssh/authorized_keys"

			## Harden SSH by disabling root login, password login and X11Forwarding
			sed -i 's|#PermitRootLogin prohibit-password|PermitRootLogin no|g' /etc/ssh/sshd_config
			sed -i 's|#PasswordAuthentication yes|PasswordAuthentication no|g' /etc/ssh/sshd_config
			sed -i 's|X11Forwarding yes|X11Forwarding no|g' /etc/ssh/sshd_config

		EOCHROOT
	}

	uncompress_logs(){
		## Disable log gzipping as we already use compresion at filesystem level
		chroot "${mountpoint}" /bin/bash -x <<-EOCHROOT
			for file in /etc/logrotate.d/* ; do
				if grep -Eq "(^|[^#y])compress" "\${file}" ; then
					sed -i -r "s/(^|[^#y])(compress)/\1#\2/" "\${file}"
				fi
			done
		EOCHROOT
	}
	
	configs_with_user_interactions(){
		## Set keyboard configuration and console
		chroot "${mountpoint}" /bin/bash -x <<-EOCHROOT
			dpkg-reconfigure keyboard-configuration console-setup
		EOCHROOT
	}

	cleanup(){
		## Umount target and final cleanup
		umount -n -R "${mountpoint}"
		sync
		sleep 5
		umount -n -R "${mountpoint}" >/dev/null 2>&1
		
		zpool export "${root_pool_name}"
	}

	## Install steps
	get_install_inputs
	set_install_variables
	install_packages_live_environment 							# Install debootstrap/zfs/gdisk in live environment
	create_partitions											# Wipe disk and create boot/swap/zfs partitions
	create_pool_and_datasets 									# Create zpool, create datasets, mount datasets
	debootstrap_ubuntu
	create_swap
	install_zfsbootmenu
	install_refind
	enable_tmpmount
	config_netplan_yaml
	create_user
	install_ubuntu_server
	uncompress_logs
	configs_with_user_interactions
	#cleanup


	######################## TODO: test if this works
	chroot "${mountpoint}" /bin/bash -x <<-EOCHROOT
		add_authorized_key
		ssh_authorized_key="wrong key" 	# TODO remove after testing
		add_authorized_key				# TODO remove after testing
		clean_authorized_keys
		setup_remote_access
		set_refind_theme
	EOCHROOT

	########################

	cat <<-EOF

		Debootstrap installation of Ubuntu Server ${release} (${codename}) completed
		After rebooting into the new system, run ZoRRA to view available post-reboot options, such as:
		  - Setup remote access with authorized keys
		  - Auto-unlock storage pools
		  - Set rEFInd and ZBM timeouts
		  - Set a rEFInd theme
		
	EOF
}

if ${debootstrap_install}; then
	debootstrap_install
fi