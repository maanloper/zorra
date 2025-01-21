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

# Source prompt_input
source "$script_dir/../lib/prompt-input.sh"

change_key(){
	## Make sure all pools have current key loaded
	local pools=$(zpool list -H -o name)
	for pool in ${pools}; do
		## Try to load key with existing keyfile, otherwise prompt for passphrase
		if [[ $(zfs get -H -o value keystatus "${pool}") != "available" ]]; then
			if ! zfs load-key -L "file://${KEYFILE}" "${pool}" &>/dev/null; then
				echo "Cannot automatically unlock pool '${pool}', please manually enter your passphrase"
				zfs load-key -L prompt "${pool}"
			fi
		fi
	done

	## Prompt for new passphrase
	while true; do
		prompt_input new_passphrase "Enter new passphrase" confirm

		## Check minimum length of passphrase
		if (( ${#new_passphrase} >= 8 )); then
			break
		else
			echo "Passphrase too short, must be at least 8 characters (OpenZFS requirement)"
		fi
	done

	## Change passphrase in keyfile
	echo "${new_passphrase}" > "${KEYFILE}"

	## Change keyfile for all pools
	for pool in ${pools}; do
		zfs change-key -l -o keylocation="file://${KEYFILE}" -o keyformat=passphrase "${pool}"
		echo "Successfully changed key for: ${pool}"
	done

	## Generate initramfs for current OS with check if key is available
	echo "Updating initramfs for current OS..."
	safe_generate_initramfs

	## Generate initramfs for all other OS under root_pool_name/ROOT/
	local tmp_mountpoint=/tmp/os_mnt
	mkdir -p "${tmp_mountpoint}"
	local dataset
	for dataset in $(zfs list -H -o name,mounted ${ROOT_POOL_NAME}/ROOT -r | grep "${ROOT_POOL_NAME}/ROOT/.*no$" | awk '{print $1}'); do
		echo "Updating initramfs in ${dataset}..."
		
		## Set mountpoint of OS to tmp mountpoint and mount
		zfs set mountpoint="${tmp_mountpoint}" "${dataset}"
		zfs mount "${dataset}"
	
		## Mount system files in required mountpoints
		mount -t proc proc "${tmp_mountpoint}/proc"
		mount -t sysfs sys "${tmp_mountpoint}/sys"
		mount -B /dev "${tmp_mountpoint}/dev"
		mount -t devpts pts "${tmp_mountpoint}/dev/pts"

		## Make a tmp copy of keyfile to dataset
		cp "${KEYFILE}" "${tmp_mountpoint}${KEYFILE}"
		
		## Create new initramfs only if keyfile is loaded
		chroot "${tmp_mountpoint}" /bin/bash <<-EOCHROOT
			if [[ -f "${KEYFILE}" && -s "${KEYFILE}"  ]]; then
				## Update initramfs (ignoring warning about swap using keyfile)
				update-initramfs -c -k all 2>&1 | grep -v "cryptsetup: WARNING: Resume target swap uses a key file"
			fi
		EOCHROOT

		## Remove tmp copy of keyfile
		rm "${tmp_mountpoint}${KEYFILE}"

		## Unmount everything from the tmp mountpoint and reset mountpoint to '/'
		umount -n -R "${tmp_mountpoint}"
		zfs set -u mountpoint=/ "${dataset}"
	done
	rm -r "${tmp_mountpoint}"

	echo "Successfully changed key for all pools and operating systems"
}

## Check no arguments are passed
if [[ $# -gt 0 ]]; then
	echo "Error: no arguments allowed for 'zorra zfs change-key'"
	echo "Enter 'zorra --help' for command syntax"
	exit 1
fi

## Run function
change_key