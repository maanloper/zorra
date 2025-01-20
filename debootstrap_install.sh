#!/bin/bash
set -e

## Default debootstrap-install settings TODO: moved to .env, update vars in here to CAPS
locale="en_US.UTF-8"										# New install language setting
timezone="UTC"												# New install timezone setting
boot_size="1G"												# Size of boot partition
swap_size="4G"												# Size of swap partition

## TODO: these values are also needed in debootstrap install. How to do this?
refind_timeout="3"
zbm_timeout="-1"


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
		echo
		echo "Summary of installation:"
		echo "Ubuntu codename: ${codename}"
		echo "Installation disk: ${disk_name} <- ALL data on this disk WILL be lost!"
		echo "Hostname: ${hostname}"
		echo "Username: ${username}"
		echo "SSH key: ${ssh_authorized_key}"
		echo
		read -p "Proceed with installation? Press enter to proceed or CTRL+C to abort..." _
	}

	install_packages_live_environment(){
		## Install required packages in live environment
		apt update
		apt install -y debootstrap gdisk zfsutils-linux curl
	}

	set_install_variables(){
		## Set general variables
		mountpoint="/mnt" # Temporary debootstrap mount location in live environment
		disk="/dev/${disk_name}"
		disk_id=/dev/disk/by-id/$(ls -al /dev/disk/by-id | grep ${disk_name} | awk '{print $9}' | head -n 1)
		boot_part="1"
		swap_part="2"
		pool_part="3"

		## Set install_dataset name by extracting release (e.g. 24.04) from Ubuntu wiki TODO: needs different source, ubuntu wiki is too slow/fails
		release=$(curl -s https://wiki.ubuntu.com/Releases | awk -v search="$codename" 'tolower($0) ~ tolower(search) {print prev} {prev=$0}' | grep -Eo '[0-9]{2}\.[0-9]{2}' | head -n 1)
		install_dataset="ubuntu_server_${release}" # Dataset name to install ubuntu server to

		## Export locales to prevent warnings about unset locales during installation while chrooted TODO: check if this works or needed to set /etc/default/locale DOES NOT WORK!
		export "LANG=${locale}"
		export "LANGUAGE=${locale}"
		export "LC_ALL=${locale}"
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
		mkdir -p $(dirname "${KEYFILE}")
		echo "${passphrase}" > "${KEYFILE}"

		## Create zpool
		zpool create -f -o ashift=12 \
			-O compression=zstd \
			-O acltype=posixacl \
			-O xattr=sa \
			-O normalization=formD \
			-O atime=off \
			-O encryption=aes-256-gcm \
			-O keylocation="file://${KEYFILE}" \
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
		zfs create -o mountpoint=$(dirname $KEYFILE) -o canmount=off "${root_pool_name}/keystore"
		
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
		cp "${KEYFILE}" "${mountpoint}$(dirname $KEYFILE)"
		chmod 000 "${mountpoint}${KEYFILE}"
		
		## Copy APT sources to new install and set it to https #TODO: is this not already installed with debootstrap?? And only sed-command needed?
		cp /etc/apt/sources.list.d/ubuntu.sources "${mountpoint}/etc/apt/sources.list.d/ubuntu.sources"
		sed -i 's|http://|https://|g' "${mountpoint}/etc/apt/sources.list.d/ubuntu.sources"

		## Remove deprated APT source
		rm -f /etc/apt/sources.list
		
		## Update repository cache, generate locale, upgrade all packages, install required packages and set timezone
		chroot "$mountpoint" /bin/bash -x <<-EOCHROOT
			## Generate locale
			locale-gen en_US.UTF-8 ${locale}

			## Update respository, upgrade all current packages and install required packages
			apt update
			apt upgrade -y
			#apt install -y --no-install-recommends tzdata keyboard-configuration console-setup linux-generic #TODO already in ubunut debootstrap i think?
			apt install -y --no-install-recommends linux-generic

			## Set timezone
			ln -fs "/usr/share/zoneinfo/${timezone}" /etc/localtime

			## Set NTP server
			echo "NTP=pool.ntp.org" >> /etc/systemd/timesyncd.conf
		EOCHROOT
		
		## Install and enable required packages for ZFS
		chroot "${mountpoint}" /bin/bash -x <<-EOCHROOT
			## Install packages
			apt install -y dosfstools zfs-initramfs zfsutils-linux

			## Add root pool to monitored list of zfs-mount-generator
			touch "/etc/zfs/zfs-list.cache/${root_pool_name}"

			## Create exports.d dir to prevent 'failed to lock /etc/exports.d/zfs.exports.lock: No such file or directory'-warnings
			mkdir -p /etc/exports.d
			
			## Enable ZFS services TODO: is this needed? or are they enabled by default?
			systemctl enable zfs.target
			systemctl enable zfs-import-cache
			systemctl enable zfs-mount
			systemctl enable zfs-import.target
			
			## Set UMASK to prevent leaking of zfsroot.key in initramfs to users on the system
			echo "UMASK=0077" > /etc/initramfs-tools/conf.d/umask.conf
		EOCHROOT

		
		## Fix zfs-mount-generator bug with keyfile pointing to keystore that is mounted within root pool creating infinite systemd zfs-load-key-rpool.service loop
		cat <<-EOF > "${mountpoint}/etc/zfs/fix-zfs-mount-generator"
			#!/bin/bash

			## zfs-load-key-rpool.service needs keyfile to unlock
			## which is stored in keystore
			## which needs needs to be unlocked
			## which needs zfs-load-key-rpool.service
			## ... infinite loop ...

			## Fix: comment out \${keymountdep} to prevent it being executed in zfs-load-key-rpool.service leading to infinite loop
			sed -i '/^\\\${keymountdep}/s/^/#/' /usr/lib/systemd/system-generators/zfs-mount-generator
			echo "Fix for zfs-mount-generator applied (/etc/zfs/fix-zfs-mount-generator)"
		EOF

		## Make the fix executable
		chmod 700 "${mountpoint}/etc/zfs/fix-zfs-mount-generator"

		## Have the fix run after APT is done, to make sure the fix keeps being applied
		cat <<-EOF > "${mountpoint}/etc/apt/apt.conf.d/80-fix-zfs-mount-generator"
			DPkg::Post-Invoke {"if [ -x /etc/zfs/fix-zfs-mount-generator ]; then /etc/zfs/fix-zfs-mount-generator; fi"};
		EOF
	}

	create_swap(){
		## Setup swap partition, using AES encryption with keysize 256 bits
		echo "swap ${disk_id}-part${swap_part} /dev/urandom plain,swap,cipher=aes-xts-plain64:sha256,size=256" >>"${mountpoint}"/etc/crypttab
		echo /dev/mapper/swap none swap defaults 0 0 >>"${mountpoint}"/etc/fstab
	}

	setup_boot_partition(){
		## Format boot partition (EFI partition must be formatted as FAT32)
		mkfs.vfat -v -F32 "${disk_id}-part${boot_part}"
		sync
		sleep 2

		## Create fstab entry for boot partition
		cat <<-EOF >>"${mountpoint}/etc/fstab"
			$(blkid | grep -E "${disk}(p)?${boot_part}" | cut -d ' ' -f 2) /boot/efi vfat defaults 0 0
		EOF

		chroot "${mountpoint}" /bin/bash -x <<-EOCHROOT
			## Create and mount /boot/efi
			mkdir -p /boot/efi
			mount /boot/efi
		EOCHROOT
	}
	
	install_zfsbootmenu(){
		## Install ZFSBootMenu
		chroot "${mountpoint}" /bin/bash -x <<-EOCHROOT
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
			
			## Git clone ZFSBootMenu
			mkdir -p /usr/local/src/zfsbootmenu
			git -C /usr/local/src/zfsbootmenu clone https://github.com/zbm-dev/zfsbootmenu.git

			## Make ZFSBootMenu using dracut
			make -C /usr/local/src/zfsbootmenu core dracut
			
			## Update ZBM configuration file
			sed \
				-e 's|ManageImages:.*|ManageImages: true|' \
				-e 's|ImageDir:.*|ImageDir: /boot/efi/EFI/zbm|' \
				-e 's|Versions:.*|Versions: 2|' \
				-e '/^Components:/,/^[^[:space:]]/ s|Enabled:.*|Enabled: true|' \
				-e '/^EFI:/,/^[^[:space:]]/ s|Enabled:.*|Enabled: false|' \
				-i /etc/zfsbootmenu/config.yaml
			
			## Generate the ZFSBootMenu components
			update-initramfs -c -k all 2>&1 | grep -v "cryptsetup: WARNING: Resume target swap uses a key file"
			generate-zbm

			## Set ZFSBootMenu parameters
			zfs set org.zfsbootmenu:commandline="loglevel=0" "${root_pool_name}"
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
		cat <<-EOF > ${mountpoint}/boot/efi/EFI/zbm/refind_linux.conf
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
			useradd "${username}" --shell /bin/bash --create-home --groups adm,cdrom,dip,plugdev,sudo
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

	disable_log_compression(){
		## Disable log gzipping as ZFS already compresses the data
		chroot "${mountpoint}" /bin/bash -x <<-EOCHROOT
			for file in /etc/logrotate.d/* ; do
				if grep -Eq "(^|[^#y])compress" "\${file}" ; then
					sed -i -r "s/(^|[^#y])(compress)/\1#\2/" "\${file}"
				fi
			done
		EOCHROOT
	}
	
	setup_zorra_on_new_install(){
		## Copy ZoRRA to new install
		mkdir -p "${mountpoint}/usr/local/zorra"
		cp ./ "${mountpoint}/usr/local/zorra/"

		## Create symlink in /usr/local/bin TODO: does this work, or must this be done in chroot?
		ln -s /usr/local/zorra/zorra "${mountpoint}/usr/local/bin/zorra"

		## Set APT to take a snapshot before executing any steps
		cat <<-EOF > "${mountpoint}/etc/apt/apt.conf.d/80-take-snapshot"
			DPkg::Pre-Invoke {"if [ -x /usr/local/bin/zorra ]; then /usr/local/bin/zorra zfs snapshot --tag apt; fi"};
		EOF

		## Create systemd service and timer files to take nightly snapshot of all pools
		## Snapshot will be pruned according to the retention policy only after a successfull snapshot
		cat <<-EOF > "${mountpoint}/etc/systemd/system/zorra_zfs_snapshot.service"
			[Unit]
			Description=Run zorra zfs snapshot

			[Service]
			Type=oneshot
			ExecStart=/usr/local/bin/zorra zfs snapshot
		EOF
		cat <<-EOF > "${mountpoint}/etc/systemd/system/zorra_zfs_snapshot.timer"
			[Unit]
			Description=Timer for zorra_zfs_snapshot.service

			[Timer]
			OnCalendar=*-*-* 00:00:00
			Persistent=true

			[Install]
			WantedBy=timers.target
		EOF
	}

	configs_with_user_interaction(){
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
	install_packages_live_environment
	set_install_variables
	create_partitions
	create_pool_and_datasets
	debootstrap_ubuntu
	create_swap
	setup_boot_partition
	install_zfsbootmenu
	install_refind
	enable_tmpmount
	config_netplan_yaml
	create_user
	install_ubuntu_server
	disable_log_compression
	setup_zorra_on_new_install
	configs_with_user_interaction
	#cleanup

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