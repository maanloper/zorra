#!/bin/bash
set -e
set -x

## Check for root priviliges
if [ "$(id -u)" -ne 0 ]; then
   echo "This command can only be run as root. Run with sudo or elevate to root."
   exit 1
fi

## Default debootstrap-install settings
locale="en_US.UTF-8"
timezone="UTC"
boot_size="1G"
swap_size="4G"

## Get the absolute path to the current script directory
script_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"

## Source prompt_input
source "$script_dir/../lib/prompt-input.sh"

## Source prompt_list
source "$script_dir/../lib/prompt-list.sh"

## Source show_from_to
source "$script_dir/../lib/show-from-to.sh"

check_internet_connection(){
	if ! ping -c 1  cloudflare.com &>/dev/null; then
		echo "Your internet connection seems to be down"
		echo "An active internet connection is required to download the required components"
		echo "Assure you have internet connection with 'ping cloudflare.com' (or equivalent)"
	fi
}

get_install_inputs_disk_passphrase(){
	## Disk and encryption
	disk_from=$(ls -l /dev/disk/by-id | grep -vE "(part|\-swap|sr0)"| sort | awk '{print $9}')
	disk_to=$(ls -l /dev/disk/by-id | grep -vE "(part|\-swap|sr0)" | sort | awk '{gsub("../../", "", $11); print $11}')
	echo "Overview of available disks:"
	show_from_to "${disk_from}" "${disk_to}"
	prompt_input disk_name "Enter disk name (e.g. sda, nvme1, etc.)"
	prompt_input passphrase "Enter passphrase for disk encryption" confirm
}

get_install_inputs_hostname_username_password_sshkey(){
	## Ubuntu release
	ubuntu_releases=$(curl -s https://releases.ubuntu.com | grep -oP 'Ubuntu .*? \([^\)]+\)' | awk '!seen[$0]++' | sort)
	prompt_list ubuntu_release "${ubuntu_releases}" "Select Ubuntu release to install"
	codename=$(echo "${ubuntu_release}" | awk -F '[()]' '{print tolower($2)}' | awk '{print $1}')
	ubuntu_version=$(echo "${ubuntu_release}" | cut -c 1-12 | sed 's/ /_/g')
	
	## Hostname, username, password, SSH login
	prompt_input hostname "Enter hostname"
	prompt_input username "Enter username"
	prompt_input password "Enter password for user '${username}'" confirm
	prompt_input ssh_authorized_key "Enter OpenSSH key for key-based login into user '${username}'"
}

set_install_variables(){
	## Set mountpoint
	mountpoint="/mnt/zorra" # Temporary debootstrap mount location in live environment

	## Set disk parts
	boot_part="1"
	swap_part="2"
	pool_part="3"

	## Get disk_id
	if ${full_install}; then
		disk="/dev/${disk_name}"
		disk_id="/dev/disk/by-id/$(ls -al /dev/disk/by-id | grep ${disk_name} | awk '{print $9}' | head -n 1)"
	else
		disk_id=$(zpool status -P "${ROOT_POOL_NAME}" | awk '/dev\/disk/ {sub(/-part[0-9]+$/, "", $1); print $1}')
		disk=$(lsblk -r -p -o name,ID | grep "$(echo $disk_id | awk -F- '{print $NF}')$" | awk '{print $1}')
	fi

	## Set install_dataset name
	if [[ -z "${install_dataset}" ]]; then
		install_dataset="${ubuntu_version}" # Dataset name to install ubuntu server to
	fi

	## Export locales to prevent warnings about unset locales during debootstrapping
	export "LANG=${locale}"
	export "LANGUAGE=${locale}"
	export "LC_ALL=${locale}"
}

confirm_install_summary(){
	## Show summary and confirmation
	echo "Summary of install:"
	if ${full_install}; then
		echo "Install disk: ${disk} <- ALL data on this disk WILL be lost!"
	else
		echo "Install disk: ${disk} (${disk_id}) (no data will be deleted)"
	fi
	echo "Install dataset: ${ROOT_POOL_NAME}/ROOT/${install_dataset} "
	echo "Ubuntu release: ${ubuntu_release}"
	echo "Hostname: ${hostname}"
	echo "Username: ${username}"
	echo "SSH key: ${ssh_authorized_key}"
	if ${remote_access}; then
		echo "ZFSBootMenu Remote Access will be setup"
	fi	
	echo
	read -p "Proceed with installation? Press any key to proceed or CTRL+C to abort..." _
}

install_packages_live_environment(){
	## Install required packages in live environment TODO: curl is only used on live env to select release, which is before this step. Maybe do a package check there, to see if curl is installed?
	apt update
	apt install -y debootstrap gdisk zfsutils-linux curl
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

create_encrypted_pool(){
	## Generate hostid (used by ZFS for host-identification)
	zgenhostid -f 0x00bab10c

	## Put passphrase in keyfile on live environment
	mkdir -p $(dirname "${KEYFILE}")
	echo "${passphrase}" > "${KEYFILE}"

	## Create pool (with altroot mountpoint set at tmp mounpoint)
	zpool create -f  \
		-o ashift=12 \
		-O compression=zstd \
		-O acltype=posixacl \
		-O xattr=sa \
		-O normalization=formD \
		-O atime=off \
		-O encryption=aes-256-gcm \
		-O keylocation="file://${KEYFILE}" \
		-O keyformat=passphrase \
		-O canmount=off \
		-m none \
		"${ROOT_POOL_NAME}" "${disk_id}-part${pool_part}"
	
	sync
	sleep 2

	## Set ZFSBootMenu base commandline
	zfs set org.zfsbootmenu:commandline="loglevel=0" "${ROOT_POOL_NAME}"
}

create_root_dataset(){
	##### TODO: can all syncs/sleeps be removed???
	## Create ROOT dataset
	zfs create -o mountpoint=none -o canmount=off "${ROOT_POOL_NAME}"/ROOT
	sync
	sleep 2
}

create_and_mount_os_dataset(){
	## Create OS installation dataset
	zfs create -o mountpoint="${mountpoint}" -o canmount=noauto "${ROOT_POOL_NAME}/ROOT/${install_dataset}"
	sync
	zpool set bootfs="${ROOT_POOL_NAME}/ROOT/${install_dataset}" "${ROOT_POOL_NAME}"

	## Mount the install dataset
	zfs mount "${ROOT_POOL_NAME}/ROOT/${install_dataset}"
	sync
	sleep 2

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

	## Copy APT sources to new install, replace live environment-codename with install-codename and replace http with https
	cp /etc/apt/sources.list.d/ubuntu.sources "${mountpoint}/etc/apt/sources.list.d/ubuntu.sources"
	live_environment_codename=$(lsb_release -a | awk '/Codename/ {print $2}')
	sed -i "s|${live_environment_codename}|${codename}|g" "${mountpoint}/etc/apt/sources.list.d/ubuntu.sources"
	sed -i 's|http://|https://|g' "${mountpoint}/etc/apt/sources.list.d/ubuntu.sources"

	## Remove deprated APT source
	rm -f "${mountpoint}/etc/apt/sources.list"

	## Set unattended-upgrades to also install updates for normal packages
	sudo sed -i 's|//\([[:space:]]*"${distro_id}:${distro_codename}-updates";\)|\1|' /etc/apt/apt.conf.d/50unattended-upgrades
	
	## Update repository cache, generate locale, upgrade all packages, install required packages and set timezone
	chroot "$mountpoint" /bin/bash -x <<-EOCHROOT
		## Generate locale
		locale-gen en_US.UTF-8 ${locale}

		## Update respository, upgrade all current packages and install required packages
		apt update
		apt upgrade -y
		apt install -y --no-install-recommends linux-generic

		## Set timezone
		ln -fs "/usr/share/zoneinfo/${timezone}" /etc/localtime

		## Set NTP server
		echo "NTP=pool.ntp.org" >> /etc/systemd/timesyncd.conf
	EOCHROOT
}

setup_swap(){
	## Setup swap partition, using AES encryption with keysize 256 bits
	echo "swap ${disk_id}-part${swap_part} /dev/urandom plain,swap,cipher=aes-xts-plain64:sha256,size=256" >>"${mountpoint}"/etc/crypttab
	echo /dev/mapper/swap none swap defaults 0 0 >>"${mountpoint}"/etc/fstab
}

format_boot_partition(){
	## Format boot partition (EFI partition must be formatted as FAT32)
	mkfs.vfat -v -F32 "${disk_id}-part${boot_part}"
	sync
	sleep 2
}

setup_boot_partition(){
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

install_refind(){
	## Install and configure rEFInd
	chroot "${mountpoint}" /bin/bash -x <<-EOCHROOT
		## Mount the efi variables filesystem
		mount -t efivarfs efivarfs /sys/firmware/efi/efivars

		## Install rEFInd
		DEBIAN_FRONTEND=noninteractive apt install -y refind
	EOCHROOT
}

create_refind_zfsbootmenu_config(){
	## Set ZFSBootMenu config for rEFInd
	cat <<-EOF > ${mountpoint}/boot/efi/EFI/zbm/refind_linux.conf
		"Boot default"  "quiet loglevel=0 zbm.timeout=-1"
		"Boot to menu"  "quiet loglevel=0 zbm.show"
	EOF
}

install_zfs(){	
	## Install and enable required packages for ZFS
	chroot "${mountpoint}" /bin/bash -x <<-EOCHROOT
		## Install packages
		apt install -y dosfstools zfs-initramfs zfsutils-linux

		## Add root pool to monitored list of zfs-mount-generator
		mkdir -p /etc/zfs/zfs-list.cache
		touch "/etc/zfs/zfs-list.cache/${ROOT_POOL_NAME}"

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
		#echo "Fix for zfs-mount-generator (re)applied (/etc/zfs/fix-zfs-mount-generator)"
	EOF

	## Make the fix executable
	chmod 700 "${mountpoint}/etc/zfs/fix-zfs-mount-generator"

	## Have the fix run after APT is done, to make sure the fix keeps being applied
	cat <<-EOF > "${mountpoint}/etc/apt/apt.conf.d/80fix-zfs-mount-generator"
		DPkg::Post-Invoke {"if [ -x /etc/zfs/fix-zfs-mount-generator ]; then /etc/zfs/fix-zfs-mount-generator; fi"};
	EOF
}

create_keystore_dataset_and_keyfile(){
	## Remove keyfile from live environment
	rm -fr $(dirname "${KEYFILE}")

	## Create keystore dataset
	zfs create -o mountpoint="$(dirname $KEYFILE)" "${ROOT_POOL_NAME}/keystore"

	## Put passphrase in keyfile in keystore dataset
	echo "${passphrase}" > "${KEYFILE}"
	chmod 000 "${KEYFILE}"

	## Set ZFSBootMenu keysource
	zfs set org.zfsbootmenu:keysource="${ROOT_POOL_NAME}/keystore" "${ROOT_POOL_NAME}"
}

mount_keystore_in_chroot(){
	chroot "${mountpoint}" /bin/bash -x <<-EOCHROOT
		## Mount the keystore
		zfs mount "${ROOT_POOL_NAME}/keystore"

		## Update initramfs to include key
		update-initramfs -c -k all
	EOCHROOT
}

enable_tmpmount(){
	## Setup tmp.mount for ram-based /tmp
	cp /usr/share/systemd/tmp.mount "${mountpoint}/etc/systemd/system/"
	chroot "${mountpoint}" /bin/bash -x <<-EOCHROOT
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
	EOCHROOT
}

install_openssh_server(){
	chroot "${mountpoint}" /bin/bash -x <<-EOCHROOT
		## Install OpenSSH
		apt install -y --no-install-recommends \
			openssh-server
		
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
		sed -i 's|#ClientAliveInterval 0|#ClientAliveInterval 3600|g' /etc/ssh/sshd_config
	EOCHROOT
}
	
copy_ssh_host_key(){
	## Copy ssh_host_* keys from current config to prevent SSH-fingerprint warnings
	cp /etc/ssh/ssh_host_* "${mountpoint}/etc/ssh"
}

install_additional_packages(){
	chroot "${mountpoint}" /bin/bash -x <<-EOCHROOT
		## Install additional packages
		apt install -y --no-install-recommends \
			nano
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

	## Set unattended-upgrades to use syslog instead of own logs
	echo "Unattended-Upgrade::SyslogEnable true;" > "${mountpoint}/etc/apt/apt.conf.d/52unattended-upgrades-local"
}
	
install_zorra(){
	## Copy ZoRRA to new install
	mkdir -p "${mountpoint}/usr/local/zorra"
	cp -r /usr/local/zorra "${mountpoint}/usr/local"

	## Create symlink in /usr/local/bin TODO: does this work, or must this be done in chroot?
	ln -s /usr/local/zorra/zorra "${mountpoint}/usr/local/bin/zorra"
}

zorra_setup_auto_snapshot_and_prune(){
	## Install prerequisite package
	chroot "${mountpoint}" /bin/bash -x <<-EOCHROOT
		apt install -y psmisc
	EOCHROOT
	
	## Set APT to take a snapshot before execution
	cat <<-EOF > "${mountpoint}/etc/apt/apt.conf.d/80zorra-zfs-snapshot"
		DPkg::Pre-Invoke {"if [ -x /usr/local/bin/zorra ]; then /usr/local/bin/zorra zfs snapshot --tag apt; fi"};
	EOF

	## Create systemd service and timer files to take nightly snapshot of all pools (and prune snapshots according to retention policy)
	cat <<-EOF > "${mountpoint}/etc/systemd/system/zorra_snapshot_and_prune.service"
		[Unit]
		Description=Run zorra zfs snapshot and prune snapshots

		[Service]
		Type=oneshot
		ExecStart=/usr/local/bin/zorra zfs snapshot --tag systemd
		ExecStart=/usr/local/bin/zorra zfs prune-snapshots
	EOF
	cat <<-EOF > "${mountpoint}/etc/systemd/system/zorra_snapshot_and_prune.timer"
		[Unit]
		Description=Timer for zorra_snapshot_and_prune.service

		[Timer]
		OnCalendar=*-*-* 00:00:00
		Persistent=true

		[Install]
		WantedBy=timers.target
	EOF
	chroot "${mountpoint}" /bin/bash -x <<-EOCHROOT
		systemctl enable zorra_snapshot_and_prune.timer
	EOCHROOT
}

zorra_always_install(){
	chroot "${mountpoint}" /bin/bash -x <<-EOCHROOT
		## Install ZFSBootMenu
		zorra zfsbootmenu update

		## Setup msmtp
		zorra setup msmtp --test

		## Setup pool health monitoring
		zorra zfs monitor-status
	EOCHROOT
}

zorra_only_on_full_install(){
	chroot "${mountpoint}" /bin/bash -x <<-EOCHROOT
		## Set rEFInd timeout and theme
		zorra refind set-timeout
		zorra refind set-theme

		## Set zfsbootmenu to default to boot to zfsbootmenu interface
		zorra zfsbootmenu set-timeout

		## Set zfs_arc_max to default zorra-value
		zorra zfs set-arc-max
	EOCHROOT
}

zorra_setup_remote_access(){
	chroot "${mountpoint}" /bin/bash -x <<-EOCHROOT
		## Install ZFSBootMenu remote access with ssh-key of user for login
		zorra zfsbootmenu remote-access --add-authorized-key user:${username}
	EOCHROOT
}

zorra_remote_access_copy_ssh_host(){
	## Copy dropbear ssh_host_* keys from current OS to prevent SSH-fingerprint warnings
	rm -f "${mountpoint}/etc/dropbear/ssh_host_"*
	cp /etc/dropbear/ssh_host_* "${mountpoint}/etc/dropbear"

	chroot "${mountpoint}" /bin/bash -x <<-EOCHROOT
		generate-zbm
	EOCHROOT
}

configs_with_user_interaction(){
	## Set keyboard configuration and console
	chroot "${mountpoint}" /bin/bash -x <<-EOCHROOT
		dpkg-reconfigure keyboard-configuration console-setup
	EOCHROOT
}

cleanup(){
	## Unmount temp mountpoint
	umount -n -R "${mountpoint}"
	sync
	sleep 5
	umount -n -R "${mountpoint}" >/dev/null 2>&1

	## Set mountpoint of OS dataset to /
	zfs set -u mountpoint=/ "${ROOT_POOL_NAME}/ROOT/${install_dataset}"

	## Export pool
	if ${full_install}; then
		zpool export "${ROOT_POOL_NAME}"
	fi
}

debootstrap_install(){
	## Install steps

	check_internet_connection
	if ${full_install}; then
		get_install_inputs_disk_passphrase
	fi
	get_install_inputs_hostname_username_password_sshkey
	set_install_variables
	confirm_install_summary
	install_packages_live_environment
	if ${full_install}; then
		create_partitions
		create_encrypted_pool
		create_root_dataset
	fi
	create_and_mount_os_dataset
	debootstrap_ubuntu
	setup_swap
	if ${full_install}; then
		format_boot_partition
	fi
	setup_boot_partition
	install_refind
	if ${full_install}; then
		create_refind_zfsbootmenu_config
	fi
	install_zfs
	if ${full_install}; then
		create_keystore_dataset_and_keyfile
	fi
	mount_keystore_in_chroot
	enable_tmpmount
	config_netplan_yaml
	create_user
	install_ubuntu_server
	install_openssh_server
	if ${on_dataset_install}; then
		copy_ssh_host_key
	fi
	install_additional_packages
	disable_log_compression
	install_zorra
	zorra_setup_auto_snapshot_and_prune
	zorra_always_install
	if ${full_install}; then
		zorra_only_on_full_install
	fi
	if ${remote_access}; then
		zorra_setup_remote_access
		if ${on_dataset_install}; then
		zorra_remote_access_copy_ssh_host
		fi
	fi
	configs_with_user_interaction
	#cleanup

	cat <<-EOF

		Debootstrap installation of ${ubuntu_release} completed
		After rebooting into the new system, run 'zorra --help' to view available post-reboot options, such as:
		  - Setup remote access with authorized keys
		  - Auto-unlock storage pools
		  - Set rEFInd and ZBM timeouts
		  - Set a rEFInd theme
		
	EOF
}

full_install=true
on_dataset_install=false
remote_access=false
while [[ $# -gt 0 ]]; do
	case "$1" in
		--on-dataset)
			full_install=false
			on_dataset_install=true
            if ! grep -q "${ROOT_POOL_NAME}/ROOT/$2" <<< "$(zfs list -o name)"; then
			    install_dataset="$2"
                shift 1
            else
                echo "Error: dataset '$2' already exists"
                echo "Enter 'zorra --help' for command syntax"
                exit 1
            fi
        ;;
		--remote-access)
			remote_access=true
        ;;
		*)
			echo "Error: unrecognized argument '$1' for 'zorra debootstrap-install'"
			echo "Enter 'zorra --help' for command syntax"
			exit 1
		;;
	esac
	shift 1
done

debootstrap_install
