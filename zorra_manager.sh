#!/bin/bash
set -e

clear_authorized_keys(){
	## Clear dropbear authorized_keys file
	>${dropbear_authorized_keys}
	echo "Cleared all keys from ${dropbear_authorized_keys}"
}

add_authorized_key(){
	## Create dropbear authorized_keys dir if not exists and set permissions/owner
	mkdir -p $(dirname ${dropbear_authorized_keys})
	chown root:root $(dirname ${dropbear_authorized_keys})
	chmod 700 $(dirname ${dropbear_authorized_keys})

	## Add keys from user .ssh/authorized_keys or add a key manually to dropbear_authorized_keys
	if [[ -n "${ssh_user}" ]]; then
		cat "/home/${ssh_user}/.ssh/authorized_keys" >> ${dropbear_authorized_keys}
		echo "Added keys in /home/${ssh_user}/.ssh/authorized_keys to ${dropbear_authorized_keys}"
	elif [[ -n "${ssh_authorized_key}" ]]; then
		echo "${ssh_authorized_key}" >> ${dropbear_authorized_keys}
		echo "Added key to ${dropbear_authorized_keys}"
	fi
	echo "NOTE: to use the added keys, run 'zorra --setup-remote-access'"

	## Set permissions/owner of authorized_keys file
	chown root:root ${dropbear_authorized_keys}
	chmod 600 ${dropbear_authorized_keys}
}

clean_authorized_keys() {
	if [ -f "${dropbear_authorized_keys}" ]; then
		# Process each line in the authorized_keys file
		TEMP_FILE=$(mktemp)
		while read -r key; do
			# Skip empty lines or comments
			[[ -z "${key}" || "${key}" =~ ^# ]] && echo "${key}" >> "${TEMP_FILE}" && continue

			# Validate the key using ssh-keygen
			if echo "${key}" | ssh-keygen -l -f /dev/stdin &>/dev/null; then
				echo "${key}" >> "${TEMP_FILE}"
			else
				echo "Invalid key removed from ${dropbear_authorized_keys}: ${key}"
			fi
		done < "${dropbear_authorized_keys}"

		# Remove duplicates while preserving order
		awk '!seen[$0]++' "${TEMP_FILE}" > "${dropbear_authorized_keys}"
		rm -f "${TEMP_FILE}"
	fi
}

setup_remote_access() {
	check_valid_authorized_key() {
		## Check if authorized_keys file exists and has at least one valid OpenSSH key
		key_available=false
		if [ -f "${dropbear_authorized_keys}" ]; then
			while read -r key; do
				if echo "${key}" | ssh-keygen -l -f /dev/stdin &>/dev/null; then
					# At least one key has been found, continue function
					key_available=true
					break
				fi
			done < ${dropbear_authorized_keys}
		fi

		## Exit if a valid key was found
		if ! ${key_available}; then
			cat <<-EOF

			=============================================================================
			No keys found in ${dropbear_authorized_keys}. 
			Without a public key, no SSH connection can be established with ZBM over SSH
			Use --add-authorized-key [add:<public_ssh_key> | user:<user>] to add a key
			=============================================================================

			EOF
			exit 1
		fi

		echo "Successfully checked a valid authorized key in ${dropbear_authorized_keys}"
	}

	install_required_packages{
		## Install dracut-network, dropbear and (depracated) isc-dhcp-client for 'dhclient' command required by dracut network-legacy module
		## The network-legacy module is required because ZBM disallows dracut systemd module
		apt install -y dracut-network dropbear isc-dhcp-client

		## Disable dropbear (OpenSSH already installed for base system SSH)
		systemctl stop dropbear
		systemctl disable dropbear

		echo "Successfully installed dracut-network dropbear isc-dhcp-client"
	}

	git_clone_dracut_crypt_ssh_module(){
		## Clone dracut-crypt-ssh
		rm -fr /tmp/dracut-crypt-ssh/
		rm -fr /usr/lib/dracut/modules.d/60crypt-ssh
		git -C /tmp clone 'https://github.com/dracut-crypt-ssh/dracut-crypt-ssh.git'
		mkdir -p /usr/lib/dracut/modules.d/60crypt-ssh
		cp /tmp/dracut-crypt-ssh/modules/60crypt-ssh/{50-udev-pty.rules,dropbear-start.sh,dropbear-stop.sh,module-setup.sh} /usr/lib/dracut/modules.d/60crypt-ssh/
		
		## Set global variable
		global modulesetup="/usr/lib/dracut/modules.d/60crypt-ssh/module-setup.sh"

		## Comment out references to /helper/ folder in module-setup.sh. Components not required for ZFSBootMenu.
		sed -i \
			-e '/#/! s|inst "$moddir"/helper/console_auth /bin/console_auth|#&|' \
			-e '/#/! s|inst "$moddir"/helper/console_peek.sh /bin/console_peek|#&|' \
			-e '/#/! s|inst "$moddir"/helper/unlock /bin/unlock|#&|' \
			-e '/#/! s|inst "$moddir"/helper/unlock-reap-success.sh /sbin/unlock-reap-success|#&|' \
			"${modulesetup}"

		echo "Successfully cloned dracut-crypt-ssh module"
	}
	
	config_dracut_network(){
		# Setup DHCP connection
		mkdir -p /etc/cmdline.d
		echo "rd.neednet=1 ip=${remote_access_dhcp}" > /etc/cmdline.d/dracut-network.conf

		# Set hostname when booted as ZBM waiting for remote connection
		if ! grep -q "fqdn.fqdn" "/usr/lib/dracut/modules.d/35network-legacy/dhclient.conf"; then
			cat <<-EOF >>/usr/lib/dracut/modules.d/35network-legacy/dhclient.conf
				
				send fqdn.fqdn "${remote_access_hostname}";
			EOF
		fi

		echo "Successfully configured dracut-network module with ip: ${remote_access_dhcp} and fqdn: ${remote_access_hostname}"
	}
	
	add_remote_session_welcome_message(){
		## Add remote session welcome message (banner.txt)
		cat <<-EOF >/etc/zfsbootmenu/dracut.conf.d/banner.txt
			Enter "ZBM" to start ZFSBootMenu.
		EOF
		chmod 755 /etc/zfsbootmenu/dracut.conf.d/banner.txt

		dropbear_start_sh="/usr/lib/dracut/modules.d/60crypt-ssh/dropbear-start.sh"
		if ! grep -q "banner.txt" "${dropbear_start_sh}"; then
			sed -i 's|/sbin/dropbear -s -j -k -p ${dropbear_port} -P /tmp/dropbear.pid|& -b /etc/banner.txt|' "${dropbear_start_sh}"
		fi
	
		## Change cryptssh module setup to have banner.txt copied into initramfs
		if ! grep -q "banner.txt" "${modulesetup}"; then
			sed -i '$ s|^}||' "${modulesetup}"
			cat <<-EOF >>${modulesetup}
					## Copy dropbear welcome message
					inst /etc/zfsbootmenu/dracut.conf.d/banner.txt /etc/banner.txt
				}
			EOF
		fi

		echo "Successfully set ZFSBootMenu welcome message"
	}

	create_dropbear_host_keys(){
		## Create dropbear hostkeys if default keys are still there, no keys are available, or specified to recreate
		if ${recreate_dropbear_host_keys} || ls /etc/dropbear/dropbear* &>/dev/null || ! ls /etc/dropbear/ssh_host* &>/dev/null; then
			rm -f /etc/dropbear/{dropbear*,ssh_host_*}
			ssh-keygen -t ed25519 -m PEM -f /etc/dropbear/ssh_host_ed25519_key -N ""

			echo "Successfully created dropbear host key"
		fi
	}
	
	config_dropbear(){
		## Set the required modules, optional items, ssh_host_key and authorized_keys for dropbear
		cat <<-EOF >/etc/zfsbootmenu/dracut.conf.d/dropbear.conf
			## Enable dropbear ssh server and pull in network configuration args
			##The default configuration will start dropbear on TCP port 222.

			## Modules and optional items
			#add_dracutmodules+=" crypt-ssh network-legacy "
			add_dracutmodules+=" crypt-ssh "
			install_optional_items+=" /etc/cmdline.d/dracut-network.conf "

			## Copy generated host key for consistent access
			dropbear_ed25519_key="/etc/dropbear/ssh_host_ed25519_key"

			##Access is by authorized keys only. No password.
			##By default, the list of authorized keys is taken from /root/.ssh/authorized_keys on the host.
			##A custom authorized_keys location can also be specified with the dropbear_acl variable.
			dropbear_acl="${dropbear_authorized_keys}"
		EOF

		echo "Successfully configured dropbear"
	}

	## Setup remote access steps
	install_required_packages
	git_clone_dracut_crypt_ssh_module
	config_dracut_network
	add_remote_session_welcome_message
	create_dropbear_host_keys
	config_dropbear
	generate-zbm
	set_zbm_timeout
	set_refind_timeout

	echo "Successfully created ZFSBootMenu image"
}

set_refind_theme(){
	if [[ "${refind_theme}" == "none" ]]; then
		## Remove theme
		rm -fr /boot/efi/EFI/refind/themes/*
		sed -i "/^include themes\//d" /boot/efi/EFI/refind/refind.conf
		echo "Removed rEFInd theme"
	else
		## Set and clear themes dir
		mkdir -p /boot/efi/EFI/refind/themes
		rm -fr /boot/efi/EFI/refind/themes/*
		git -C /boot/efi/EFI/refind/themes clone ${refind_theme}

		## Include theme
		sed -i "/^include themes\//d" /boot/efi/EFI/refind/refind.conf
		echo "include themes/${refind_theme_config}" >> /boot/efi/EFI/refind/refind.conf

		echo "Successfully set rEFInd theme ${refind_theme}"
	fi
}

set_zbm_timeout(){
	## Update ZFSBootMenu timer if required
	sed -i "s|zbm.timeout=-\?[0-9]*|zbm.timeout=${zbm_timeout}|" /boot/efi/EFI/ZBM/refind_linux.conf
	echo "Successfully set zbm.timeout=${zbm_timeout}"
}

set_refind_timeout(){
	## Update ZFSBootMenu timer if required
	sed -i "s|^timeout .*|timeout ${refind_timeout}|" /boot/efi/EFI/refind/refind.conf
	echo "Successfully set rEFInd bootscreen timeout ${refind_timeout}"
}



## Program order
if ${clear_authorized_keys}; then
	clear_authorized_keys
fi

if ${add_authorized_key}; then
	add_authorized_key
fi

if ${setup_remote_access}; then
	clean_authorized_keys
	setup_remote_access
fi

if ${set_refind_theme}; then
	set_refind_theme
fi

if ${set_zbm_timeout}; then
	set_zbm_timeout
fi

if ${set_refind_timeout}; then
	set_refind_timeout
fi

echo