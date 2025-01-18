#!/bin/bash
set -e


safe_generate_initramfs(){
	## Check if keyfile exists, is a normal file and is larger than 0 bytes, as without it an unbootable intitramfs will be created!
	if [[ -f "${KEYFILE}" && -s "${KEYFILE}"  ]]; then
		## Reload systemd deamon to (re)load any mount units generated by zfs-mount-generator via /etc/zfs/zfs-list.cache/<poolname>
		systemctl daemon-reload

		## Update initramfs (ignoring warning about swap using keyfile)
		update-initramfs -c -k all 2>&1 | grep -v "cryptsetup: WARNING: Resume target swap uses a key file"
	else
		local keystore_dataset=$(zfs list -o name | grep keystore)
		cat <<-EOF

			The keystore (${keystore_dataset}) is not mounted. Generating a new initramfs will create an unbootable system!
			Make sure ${keystore_dataset} is mounted at '${KEYFILE}'.

		EOF
		exit 1
	fi
}