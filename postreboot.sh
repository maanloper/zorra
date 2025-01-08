apt install -y dracut-crypt-ssh

config_dracut_crypt_ssh_module(){
	git -C /tmp clone 'https://github.com/dracut-crypt-ssh/dracut-crypt-ssh.git'
	mkdir /usr/lib/dracut/modules.d/60crypt-ssh
	cp /tmp/dracut-crypt-ssh/modules/60crypt-ssh/* /usr/lib/dracut/modules.d/60crypt-ssh/
	rm /usr/lib/dracut/modules.d/60crypt-ssh/Makefile
	
	##Comment out references to /helper/ folder in module-setup.sh. Components not required for ZFSBootMenu.
	sed -i \\
		-e 's,  inst "\$moddir"/helper/console_auth /bin/console_auth,  #inst "\$moddir"/helper/console_auth /bin/console_auth,' \\
		-e 's,  inst "\$moddir"/helper/console_peek.sh /bin/console_peek,  #inst "\$moddir"/helper/console_peek.sh /bin/console_peek,' \\
		-e 's,  inst "\$moddir"/helper/unlock /bin/unlock,  #inst "\$moddir"/helper/unlock /bin/unlock,' \\
		-e 's,  inst "\$moddir"/helper/unlock-reap-success.sh /sbin/unlock-reap-success,  #inst "\$moddir"/helper/unlock-reap-success.sh /sbin/unlock-reap-success,' \\
		"$modulesetup"
}
config_dracut_crypt_ssh_module

setup_dracut_network(){
	##setup network	
	mkdir -p /etc/cmdline.d
	
	remoteaccess_dhcp_ver(){
		dhcpver="\$1"
		echo "ip=\${dhcpver:-default} rd.neednet=1" > /etc/cmdline.d/dracut-network.conf
	}
	
	##Dracut network options: https://github.com/dracutdevs/dracut/blob/master/modules.d/35network-legacy/ifup.sh
	case "$remoteaccess_ip_config" in
		dhcp | dhcp,dhcp6 | dhcp6)
			remoteaccess_dhcp_ver "$remoteaccess_ip_config"
		;;
		static)
			echo "ip=$remoteaccess_ip:::$remoteaccess_netmask:::none rd.neednet=1 rd.break" > /etc/cmdline.d/dracut-network.conf
		;;
		*)
			echo "Remote access IP option not recognised."
			exit 1
		;;
	esac
	
	echo "send fqdn.fqdn \"$remoteaccess_hostname\";" >> /usr/lib/dracut/modules.d/35network-legacy/dhclient.conf
}
setup_dracut_network

add_welcome_message(){
	##add remote session welcome message
	cat <<-EOF >/etc/zfsbootmenu/dracut.conf.d/banner.txt
		Welcome to the ZFSBootMenu initramfs shell. Enter "zfsbootmenu" or "zbm" to start ZFSBootMenu.
	EOF
	chmod 755 /etc/zfsbootmenu/dracut.conf.d/banner.txt
	
	sed -i 's,  /sbin/dropbear -s -j -k -p \${dropbear_port} -P /tmp/dropbear.pid,  /sbin/dropbear -s -j -k -p \${dropbear_port} -P /tmp/dropbear.pid -b /etc/banner.txt,' /usr/lib/dracut/modules.d/60crypt-ssh/dropbear-start.sh
	
	##Copy files into initramfs
	sed -i '$ s,^},,' "$modulesetup"
		echo "  ##Copy dropbear welcome message" | tee -a "$modulesetup"
		echo "  inst /etc/zfsbootmenu/dracut.conf.d/banner.txt /etc/banner.txt" | tee -a "$modulesetup"
		echo "}" | tee -a "$modulesetup"
}
add_welcome_message

create_host_keys(){
##create host keys
mkdir -p /etc/dropbear
for keytype in rsa ecdsa ed25519; do
#dropbearkey -t "\${keytype}" -f "/etc/dropbear/ssh_host_\${keytype}_key"
ssh-keygen -t "\${keytype}" -m PEM -f "/etc/dropbear/ssh_host_\${keytype}_key" -N ""
##-t key type
##-m key format
##-f filename
##-N passphrase
done
}
create_host_keys

##Set ownership of initramfs authorized_keys
sed -i '/inst "\${dropbear_acl}"/a \\  chown root:root "\${initdir}/root/.ssh/authorized_keys"' "$modulesetup"

config_dropbear(){
cat <<-EOF >/etc/zfsbootmenu/dracut.conf.d/dropbear.conf
## Enable dropbear ssh server and pull in network configuration args
##The default configuration will start dropbear on TCP port 222.
##This can be overridden with the dropbear_port configuration option.
##You do not want the server listening on the default port 22.
##Clients that expect to find your normal host keys when connecting to an SSH server on port 22 will
##   refuse to connect when they find different keys provided by dropbear.

add_dracutmodules+=" crypt-ssh network-legacy "
install_optional_items+=" /etc/cmdline.d/dracut-network.conf "

## Copy system keys for consistent access
dropbear_rsa_key="/etc/dropbear/ssh_host_rsa_key"
dropbear_ecdsa_key="/etc/dropbear/ssh_host_ecdsa_key"
dropbear_ed25519_key="/etc/dropbear/ssh_host_ed25519_key"

##Access is by authorized keys only. No password.
##By default, the list of authorized keys is taken from /root/.ssh/authorized_keys on the host.
##A custom authorized_keys location can also be specified with the dropbear_acl variable.
##You can add your remote user key to a user authorized_keys file from a remote machine's terminal using:
##"ssh-copy-id -i ~/.ssh/id_rsa.pub $user@{IP_ADDRESS or FQDN of the server}"
##Then amend/uncomment the dropbear_acl variable to match:
#dropbear_acl="/home/${user}/.ssh/authorized_keys"
##Remember to "sudo generate-zbm" on the host after adding the remote user key to the authorized_keys file.

##Note that login to dropbear is "root" regardless of which authorized_keys is used.
EOF

systemctl stop dropbear
systemctl disable dropbear
}
config_dropbear

##Increase ZFSBootMenu timer to allow for remote connection
sed -i 's,zbm.timeout=$timeout_zbm_no_remote_access,zbm.timeout=$timeout_zbm_remote_access,' /boot/efi/EFI/ubuntu/refind_linux.conf

generate-zbm --debug

/bin/bash /tmp/remote_zbm_access.sh

sed -i 's,#dropbear_acl,dropbear_acl,' /etc/zfsbootmenu/dracut.conf.d/dropbear.conf
mkdir -p /home/"$user"/.ssh
chown "$user":"$user" /home/"$user"/.ssh
touch /home/"$user"/.ssh/authorized_keys
chmod 644 /home/"$user"/.ssh/authorized_keys
chown "$user":"$user" /home/"$user"/.ssh/authorized_keys
#hostname -I
echo "Zfsbootmenu remote access installed. Connect as root on port 222 during boot: \"ssh root@{IP_ADDRESS or FQDN of zfsbootmenu} -p 222\""
echo "Your SSH public key must be placed in \"/home/$user/.ssh/authorized_keys\" prior to reboot or remote access will not work."
echo "You can add your remote user key using the following command from the remote user's terminal if openssh-server is active on the host."
echo "\"ssh-copy-id -i ~/.ssh/id_rsa.pub $user@{IP_ADDRESS or FQDN of the server}\""
echo "Run \"sudo generate-zbm\" after copying across the remote user's public ssh key into the authorized_keys file."
