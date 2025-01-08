#!/bin/bash

export REMOTE_ACCESS_DHCP="dhcp,dhcp6" # Set which DHCP to use
export USER="droppi" # TODO: sync with main script

## Create dir and file for authorized keys
create_authorized_keys_file(){
	read -p "Do you want to add a key to the authorized_keys file? (y/n): " add_key
	if [[ "${add_key}" == "y" ]]; then
		read -r -p "Add a key to add to /home/"${USER}"/.ssh/authorized_keys: " authorized_key

		mkdir -p /home/"${USER}"/.ssh
		chown "${USER}":"${USER}" /home/"${USER}"/.ssh
		chmod 700 /home/"${USER}"/.ssh

		echo "${authorized_key}" >> /home/"${USER}"/.ssh/authorized_keys
		chown "${USER}":"${USER}" /home/"${USER}"/.ssh/authorized_keys
		chmod 600 /home/"${USER}"/.ssh/authorized_keys
	fi
}
create_authorized_keys_file

## Install dracut-network and dropbear, disable dropbear (OpenSSH already installed for base system SSH)
apt install -y dracut-network dropbear
systemctl stop dropbear
systemctl disable dropbear

modulesetup="/usr/lib/dracut/modules.d/60crypt-ssh/module-setup.sh"

config_dracut_crypt_ssh_module(){
	## Clone dracut-crypt-ssh
	git -C /tmp clone 'https://github.com/dracut-crypt-ssh/dracut-crypt-ssh.git'
	mkdir /usr/lib/dracut/modules.d/60crypt-ssh
	cp /tmp/dracut-crypt-ssh/modules/60crypt-ssh/* /usr/lib/dracut/modules.d/60crypt-ssh/ # no -r flag to not copy helper directory
	rm /usr/lib/dracut/modules.d/60crypt-ssh/Makefile
	
	## Comment out references to /helper/ folder in module-setup.sh. Components not required for ZFSBootMenu.
	sed -i \
		-e 's|\(inst "$moddir"/helper/console_auth /bin/console_auth\)|#\1|' \
		-e 's|\(inst "$moddir"/helper/console_peek.sh /bin/console_peek\)|#\1|' \
		-e 's|\(inst "$moddir"/helper/unlock /bin/unlock\)|#\1|' \
		-e 's|\(inst "$moddir"/helper/unlock-reap-success.sh /sbin/unlock-reap-success\)|#\1|' \
		"${modulesetup}"
}
config_dracut_crypt_ssh_module

setup_dracut_network(){
	## Setup network	
	mkdir -p /etc/cmdline.d
	echo "rd.neednet=1 ip=${REMOTE_ACCESS_DHCP}" > /etc/cmdline.d/dracut-network.conf
	#echo "send fqdn.fqdn \"$remoteaccess_hostname\";" >> /usr/lib/dracut/modules.d/35network-legacy/dhclient.conf
}
setup_dracut_network

add_remote_session_config(){
	## Add remote session welcome message (banner.txt)
	cat <<-EOF >/etc/zfsbootmenu/dracut.conf.d/banner.txt
		Enter "zbm" to start ZFSBootMenu.
	EOF
	chmod 755 /etc/zfsbootmenu/dracut.conf.d/banner.txt
	sed -i 's|\(/sbin/dropbear -s -j -k -p ${dropbear_port} -P /tmp/dropbear.pid\)|\1 -b /etc/banner.txt|' /usr/lib/dracut/modules.d/60crypt-ssh/dropbear-start.sh
	
	## Change config to have banner.txt copied into initramfs
	sed -i '$ s,^},,' "${modulesetup}"
	cat <<-EOF >>${modulesetup}
		  ## Copy dropbear welcome message
		  inst /etc/zfsbootmenu/dracut.conf.d/banner.txt /etc/banner.txt
		}
	EOF
}
add_welcome_message

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