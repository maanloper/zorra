#!/bin/bash
set -e

## Check for root priviliges
if [ "$(id -u)" -ne 0 ]; then
	echo "This command can only be run as root. Run with sudo or elevate to root."
    exit 1
fi

## Get the absolute path to the current script directory
script_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"

# Source safe_generate_initramfs
source "$script_dir/../lib/safe-generate-initramfs.sh"

auto_unlock_pool(){
	## Get input
	local auto_unlock_pool_name="$1"

	## Import pool if needed
	if ! zpool list -H | grep -q "${auto_unlock_pool_name}"; then
		echo "Pool '${auto_unlock_pool_name}' not found, trying to import..."
		if ! zpool import -d /dev/disk/by-id "${auto_unlock_pool_name}" &>/dev/null; then
            echo "Error: cannot auto-unlock pool '${auto_unlock_pool_name}' as it does not exist"
            echo "Enter 'zorra --help' for command syntax"
            exit 1
		else
			echo "Successfully imported pool: ${auto_unlock_pool_name}"
		fi
	fi

	## Try to load key with existing keyfile, otherwise prompt for passphrae
	if [[ $(zfs get -H -o value keystatus "${auto_unlock_pool_name}") != "available" ]]; then
		if ! zfs load-key -L "file://${KEYFILE}" "${auto_unlock_pool_name}" &>/dev/null; then
			## Prompt for key
			while ! zfs load-key -L prompt "${auto_unlock_pool_name}"; do
				true
			done

			## Change keylocation (and thus key) to keyfile and set keyformat to passphrase
			zfs change-key -o keylocation="file://${KEYFILE}" -o keyformat=passphrase "${auto_unlock_pool_name}"
			echo "Changed key of '${auto_unlock_pool_name}' to 'file://${KEYFILE}'"
		fi
	fi

	## Mount all datasets
	zfs mount -a

	# Add pool to zfs-list cache
	mkdir -p /etc/zfs/zfs-list.cache/
	touch "/etc/zfs/zfs-list.cache/${auto_unlock_pool_name}"

	## Verify cache update (force cache update by resetting a pool property)
	while [ ! -s "/etc/zfs/zfs-list.cache/${auto_unlock_pool_name}" ]; do
		zfs set canmount=off "${ROOT_POOL_NAME}"
		sleep 1
	done
	echo "Added pool '${auto_unlock_pool_name}' to zfs-mount-generator list (/etc/zfs/zfs-list.cache/${auto_unlock_pool_name})"

	## Generate initramfs with check if key is available
	echo "Updating initramfs to auto-unlock pool on boot..."
	safe_generate_initramfs

	echo "Successfully setup auto-unlock for pool: ${auto_unlock_pool_name}"
}

## Parse arguments
case $# in
    1)
        auto_unlock_pool "$1"
        ;;
    *)
        echo "Error: wrong number of arguments for 'zorra zfs auto-unlock'"
        echo "Enter 'zorra --help' for command syntax"
        exit 1
        ;;
esac