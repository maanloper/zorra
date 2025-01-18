#!/bin/bash
set -e

## Get the absolute path to the current script directory
script_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"

# Source safe_generate_initramfs
source "$script_dir/../lib/safe_generate_initramfs.sh"

# Source prompt_input
source "$script_dir/../lib/prompt_input.sh"

change_key(){
	## Make sure all pools have current key loaded
	pools=$(zpool list -H -o name)
	for pool in ${pools}; do
		## Try to load key with existing keyfile, otherwise prompt for passphrase
		if [[ $(zfs get -H -o value keystatus "${pool}") != "available" ]]; then
			if ! zfs load-key -L "file://${keyfile}" "${pool}" &>/dev/null; then
				echo "Cannot automatically unlock pool '${pool}', please manually enter your passphrase"
				zfs load-key -L prompt "${pool}"
			fi
		fi
	done

	## Prompt for new passphrase
	prompt_input new_passphrase "new passphrase" confirm

	## Change passphrase in keyfile
	echo "${new_passphrase}" > "${keyfile}"

	## Change keyfile for all pools
	for pool in ${pools}; do
		zfs change-key -l -o keylocation="file://${keyfile}" -o keyformat=passphrase "${pool}"
	done

	## ## Generate initramfs with check if keystore is mounted for current OS
	echo "Updating password for current OS..."
	safe_generate_initramfs
	echo "Updated password for current OS"

	## Generate initramfs for all other OS under root_pool_name/ROOT/
	mountpoint=/tmp/os_mnt
	mkdir -p "${mountpoint}"
	for dataset in $(zfs list -H -o name,mounted ${root_pool_name}/ROOT -r | grep "${root_pool_name}/ROOT/.*no$" | awk '{print $1}'); do
		echo "Updating password in ${dataset}..."
		
		## Set mountpoint of OS to tmp mountpoint and mount
		zfs set mountpoint="${mountpoint}" "${dataset}"
		zfs mount "${dataset}"
	
		## Mount system files in required mountpoints
		mount -t proc proc "${mountpoint}/proc"
		mount -t sysfs sys "${mountpoint}/sys"
		mount -B /dev "${mountpoint}/dev"
		mount -t devpts pts "${mountpoint}/dev/pts"

		## Make a tmp copy of keyfile to dataset
		cp "${keyfile}" "${mountpoint}${keyfile}"
		
		## Create new initramfs only if keyfile is loaded
		chroot "${mountpoint}" /bin/bash <<-EOCHROOT
			if [[ -f "${keyfile}" && -s "${keyfile}"  ]]; then
				## Update initramfs (ignoring warning about swap using keyfile)
				update-initramfs -c -k all 2>&1 | grep -v "cryptsetup: WARNING: Resume target swap uses a key file"
			fi
		EOCHROOT

		## Remove tmp copy of keyfile
		rm "${mountpoint}${keyfile}"

		## Unmount everything from the tmp mountpoint and reset mountpoint to '/'
		umount -n -R "${mountpoint}"
		zfs set -u mountpoint=/ "${dataset}"
		
		echo "Updated password in ${dataset}"
	done
	rm -r "${mountpoint}"

	echo "Successfully changed key for all pools"
}