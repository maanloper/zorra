#!/bin/bash
set -e

remote_access_dhcp="dhcp,dhcp6" # Set which DHCP versions to use


# Initialize variables
add_authorized_key=""
user=""
public_ssh_key=""

## Loop through arguments
while [[ $# -gt 0 ]]; do
	case "$1" in
		--add-authorized-key)
  			add_authorized_key=true
			shift
			if [[ "$1" == *"add:"* ]]; then
				public_ssh_key="${1#*:}"
   			elif [[ "$1" == *"user:"* ]]; then
				user="${1#*:}"
			else
   				echo "Missing/wrong input parameters for --add-authorized-key"
   				exit 1
			fi
   			shift
		;;
	esac
done
echo "add_authorized_key is set to: $add_authorized_key"
echo "User is set to: $user"
echo "Public SSH Key is set to: $public_ssh_key"





## Create dir and file for authorized keys
create_authorized_keys_file(){
	## Create dropbear dir if not exist and set permissions/owner
 	mkdir -p /etc/dropbear
	chown root:root /etc/dropbear
	chmod 700 /etc/dropbear

 	## Add keys from user .ssh/authorized_keys or add a key manually to /etc/dropbear/authorized_keys
 	echo
	read -p "Enter 'load' to load a user's authorized_keys to the authorized_keys file or 'add' to manually add a key. (load/add): " keys_file_menu
	if [[ "${keys_file_menu}" == "load" ]]; then
 		read -p "Enter username to load keys from: " user	
		cat "/home/${user}/.ssh/authorized_keys" >> /etc/dropbear/authorized_keys
  		echo "Added keys in /home/${user}/.ssh/authorized_keys to /etc/dropbear/authorized_keys"
	elif [[ "${keys_file_menu}" == "add" ]]; then
		read -r -p "Enter the key to add to /etc/dropbear/authorized_keys: " authorized_key
		echo "${authorized_key}" >> /etc/dropbear/authorized_keys
  		echo "Added key to /etc/dropbear/authorized_keys"
	else
 		echo "Invalid choice, exiting script"
   		exit 1
	fi

 	## Set permissions/owner of authorized_keys file
  	chown root:root /etc/dropbear/authorized_keys
	chmod 600 /etc/dropbear/authorized_keys
}

echo "Without a public key, no SSH connection can be established with ZBM over SSH"
echo "Make sure the /etc/dropbear/authorized_keys file contains your SSH public key"
echo "WARNING: all public keys in authorized_keys will be able to access ZBM over SSH!"
if [[ " $* " == *" --add-authorized-key "* ]]; then
    create_authorized_keys_file
else


## Install dracut-network and dropbear, disable dropbear (OpenSSH already installed for base system SSH)
apt install -y dracut-network dropbear
systemctl stop dropbear
systemctl disable dropbear

modulesetup="/usr/lib/dracut/modules.d/60crypt-ssh/module-setup.sh"

git_clone_dracut_crypt_ssh_module(){
	## Clone dracut-crypt-ssh
 	rm -fr /tmp/dracut-crypt-ssh/
	git -C /tmp clone 'https://github.com/dracut-crypt-ssh/dracut-crypt-ssh.git'
	mkdir -p /usr/lib/dracut/modules.d/60crypt-ssh
	cp /tmp/dracut-crypt-ssh/modules/60crypt-ssh/{50-udev-pty.rules,dropbear-start.sh,dropbear-stop.sh,module-setup.sh} /usr/lib/dracut/modules.d/60crypt-ssh/
	
	## Comment out references to /helper/ folder in module-setup.sh. Components not required for ZFSBootMenu.
	sed -i \
		-e '/#/! s|inst "$moddir"/helper/console_auth /bin/console_auth|#&|' \
		-e '/#/! s|inst "$moddir"/helper/console_peek.sh /bin/console_peek|#&|' \
		-e '/#/! s|inst "$moddir"/helper/unlock /bin/unlock|#&|' \
		-e '/#/! s|inst "$moddir"/helper/unlock-reap-success.sh /sbin/unlock-reap-success|#&|' \
		"${modulesetup}"
}
git_clone_dracut_crypt_ssh_module

setup_dracut_network(){
	## Setup network	
	mkdir -p /etc/cmdline.d
	echo "rd.neednet=1 ip=${remote_access_dhcp}" > /etc/cmdline.d/dracut-network.conf
	#echo "send fqdn.fqdn \"$remoteaccess_hostname\";" >> /usr/lib/dracut/modules.d/35network-legacy/dhclient.conf
}
setup_dracut_network

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
 
	## Change config to have banner.txt copied into initramfs
 	if ! grep -q "banner.txt" "${modulesetup}"; then
		sed -i '$ s|^}||' "${modulesetup}"
		cat <<-EOF >>${modulesetup}
			  ## Copy dropbear welcome message
			  inst /etc/zfsbootmenu/dracut.conf.d/banner.txt /etc/banner.txt
			}
		EOF
  	fi
}
add_remote_session_welcome_message

create_host_keys(){
	##create host keys
	rm /etc/dropbear/dropbear*
	ssh-keygen -t ed25519 -m PEM -f /etc/dropbear/ssh_host_ed25519_key -N ""
}
create_host_keys

## Set ownership of initramfs authorized_keys TODO: CHECK AFTER NEW INSTALL IF "CHOWN 0:0 ..."" IS ALREADY IN CONFIG
#sed -i '/inst "${dropbear_acl}"/a \  chown root:root "${initdir}/root/.ssh/authorized_keys"' "$modulesetup"

config_dropbear(){
	cat <<-EOF >/etc/zfsbootmenu/dracut.conf.d/dropbear.conf
		## Enable dropbear ssh server and pull in network configuration args
		##The default configuration will start dropbear on TCP port 222.

		## Modules and optional items
		add_dracutmodules+=" crypt-ssh network-legacy "
		install_optional_items+=" /etc/cmdline.d/dracut-network.conf "

		## Copy generated key for consistent access
		dropbear_ed25519_key="/etc/dropbear/ssh_host_ed25519_key"

		##Access is by authorized keys only. No password.
		##By default, the list of authorized keys is taken from /root/.ssh/authorized_keys on the host.
		##A custom authorized_keys location can also be specified with the dropbear_acl variable.
		dropbear_acl="/home/${USER}/.ssh/authorized_keys"
	EOF
}
config_dropbear

##Increase ZFSBootMenu timer to allow for remote connection
#sed -i 's,zbm.timeout=$timeout_zbm_no_remote_access,zbm.timeout=$timeout_zbm_remote_access,' /boot/efi/EFI/ubuntu/refind_linux.conf

generate-zbm --debug
