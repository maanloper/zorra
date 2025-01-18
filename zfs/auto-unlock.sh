#!/bin/bash
set -e

auto_unlock_pool(){
	## Import pool if needed
	if ! zpool list -H | grep -q "${auto_unlock_pool_name}"; then
		zpool import -f "${auto_unlock_pool_name}"
	fi

	## Try to load key with existing keyfile, otherwise prompt for passphrae
	if [[ $(zfs get -H -o value keystatus "${auto_unlock_pool_name}") != "available" ]]; then
		if ! zfs load-key -L "file://${KEYFILE}" "${auto_unlock_pool_name}" &>/dev/null; then
			zfs load-key -L prompt "${auto_unlock_pool_name}"
		fi
	fi

	## Change key to keyfile one and set required options
	zfs change-key -l -o keylocation="file://${KEYFILE}" -o keyformat=passphrase "${auto_unlock_pool_name}"

	# Add pool to zfs-list cache TODO: also needed in zorra_install???
	mkdir -p /etc/zfs/zfs-list.cache/
	touch "/etc/zfs/zfs-list.cache/${auto_unlock_pool_name}"

	## Verify cache update (resets a pool property to force update of cache files)
	while [ ! -s "/etc/zfs/zfs-list.cache/${auto_unlock_pool_name}" ]; do
		zfs set keylocation="file://${KEYFILE}" "${auto_unlock_pool_name}"
		sleep 1
	done

	## Generate initramfs with check if keystore is mounted
	safe_generate_initramfs

	echo "Successfully setup auto unlock for pool: ${auto_unlock_pool_name}"
}