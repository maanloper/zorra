#!/bin/bash
set -e

## Check for root priviliges
if [ "$(id -u)" -ne 0 ]; then
   echo "This command can only be run as root. Run with sudo or elevate to root."
   exit 1
fi

## Get the absolute path to the current script directory
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

## Get .env
source	${script_dir}/../../.env

# Path to dropbear authorized_keys file
dropbear_authorized_keys="/etc/dropbear/authorized_keys"

clear_authorized_keys(){
	## Clear dropbear authorized_keys file
	if [ -f "${dropbear_authorized_keys}" ]; then
		>${dropbear_authorized_keys}
		echo "Cleared all keys from ${dropbear_authorized_keys}"
	fi
}

add_authorized_key(){
	# Get input
	local ssh_user="$1"
	local ssh_authorized_key="$2"

	## Create dropbear authorized_keys dir if not exists and set permissions/owner
	mkdir -p $(dirname ${dropbear_authorized_keys})
	chown root:root $(dirname ${dropbear_authorized_keys})
	chmod 700 $(dirname ${dropbear_authorized_keys})

	## Add keys from user .ssh/authorized_keys or add a key manually to dropbear_authorized_keys
	if [[ -n "${ssh_user}" ]]; then
		# Ensure the authorized_keys file of the user exists
		local user_authorized_keys="/home/${ssh_user}/.ssh/authorized_keys"
		if [[ ! -f "${user_authorized_keys}" ]]; then
			echo "Error: authorized_keys file of '${ssh_user}' not found at '${user_authorized_keys}'"
			exit 1
		fi

		cat "${user_authorized_keys}" >> ${dropbear_authorized_keys}
		echo "Added keys in ${user_authorized_keys} to ${dropbear_authorized_keys}"

	elif [[ -n "${ssh_authorized_key}" ]]; then
		echo "${ssh_authorized_key}" >> ${dropbear_authorized_keys}
		echo "Added key to ${dropbear_authorized_keys}"
	fi

	## Set permissions/owner of authorized_keys file
	chown root:root ${dropbear_authorized_keys}
	chmod 600 ${dropbear_authorized_keys}
}

clean_authorized_keys(){
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

setup_remote_access(){
	check_valid_authorized_key(){
		## Check if authorized_keys file exists and has at least one valid OpenSSH key
		key_available=false
		if [ -f "${dropbear_authorized_keys}" ]; then
			while read -r key; do
				if echo "${key}" | ssh-keygen -l -f /dev/stdin &>/dev/null; then
					# At least one vali key has been found, break out of loop
					key_available=true
					break
				fi
			done < ${dropbear_authorized_keys}
		fi

		## Exit if no valid key was found
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
	}

	install_required_packages(){
		## Install dracut-network, dropbear and (depracated) isc-dhcp-client for 'dhclient' command required by dracut network-legacy module
		## The network-legacy module is required because ZBM disallows dracut systemd module
		apt install -y --no-install-recommends \
			dracut-network \
			dropbear \
			isc-dhcp-client
			# TODO: check if dropbear-bin is sufficient

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
		modulesetup="/usr/lib/dracut/modules.d/60crypt-ssh/module-setup.sh"

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
		echo "rd.neednet=1 ip=${REMOTE_ACCESS_DHCP}" > /etc/cmdline.d/dracut-network.conf

		# Set hostname when booted as ZBM waiting for remote connection
		sed -i "/^send/ s|.*|send host-name \"$(hostname)\";|" /usr/lib/dracut/modules.d/35network-legacy/dhclient.conf

		#if ! grep -q "send host-name" "/usr/lib/dracut/modules.d/35network-legacy/dhclient.conf"; then
		#	cat <<-EOF >>/usr/lib/dracut/modules.d/35network-legacy/dhclient.conf
		#		
		#		send host-name "$(hostname)";
		#	EOF
		#fi

		echo "Successfully configured dracut-network module with ${REMOTE_ACCESS_DHCP} and hostname: $(hostname)"
	}
	
	add_remote_session_welcome_message(){
		## Add remote session welcome message (banner.txt)
		cat <<-EOF >/etc/zfsbootmenu/dracut.conf.d/banner.txt
			Enter "zbm" to start ZFSBootMenu.
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
			ssh-keygen -t ed25519 -m PEM -f /etc/dropbear/ssh_host_ed25519_key -N "" -C "ZFSBootMenu of $(hostname)"

			echo "Successfully created dropbear host key"
		fi
	}
	
	config_dropbear(){
		## Set the required modules, optional items, ssh_host_key and authorized_keys for dropbear
		cat <<-EOF >/etc/zfsbootmenu/dracut.conf.d/dropbear.conf
			## Enable dropbear ssh server and pull in network configuration args
			##The default configuration will start dropbear on TCP port 222.

			## Modules and optional items
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
	check_valid_authorized_key
	install_required_packages
	git_clone_dracut_crypt_ssh_module
	config_dracut_network
	add_remote_session_welcome_message
	create_dropbear_host_keys
	config_dropbear
	generate-zbm # Generate new ZFSBootMenu image with updated configs/keys/etc.

	echo "Successfully setup ZFSBootMenu remote access"
}


## Loop through arguments
while [[ $# -gt 0 ]]; do
	case "$1" in
		--recreate-host-keys)
			recreate_dropbear_host_keys=true
		;;
		--clear-authorized-keys)
			clear_authorized_keys
		;;
		--add-authorized-key)
			if [[ "${2}" == add:* ]]; then
				key="${2#*:}"
				if [[ -n "${key}" ]]; then
					add_authorized_key "" "${key}"
				fi
			elif [[ "${2}" == user:* ]]; then
				user="${2#*:}"
				if id "${user}" &>/dev/null; then
					add_authorized_key "${user}" ""
				else
					echo "Error: user '${user}' does not exist"
					exit 1
				fi
			else
				echo "Error: unrecognized argument '$1' for 'zorra refind set theme'"
				echo "Enter 'zorra --help' for usage"
				exit 1
			fi
			shift 1
		;;
		*)
			echo "Error: unrecognized argument '$1' for 'zorra zfsbootmenu set remote-access'"
			echo "Enter 'zorra --help' for usage"
			exit 1
		;;
	esac
	shift 1
done

## Exceute steps
clean_authorized_keys
setup_remote_access
