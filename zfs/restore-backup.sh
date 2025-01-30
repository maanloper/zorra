#!/bin/bash
set -e

## Check for root priviliges
if [ "$(id -u)" -ne 0 ]; then
    echo "This command can only be run as root. Run with sudo or elevate to root."
    exit 1
fi

restore_backup(){
	## Set send dataset and pool, receive dataset and pool
	local send_dataset_base="$1"
	local send_pool=$(echo "${send_dataset_base}" | awk -F/ '{print $1}')
	local receive_pool=$(echo "${send_dataset_base}" | awk -F/ '{print $2}')

	## Set ssh prefix if ssh host is specified
	if [ -n "$2" ]; then
		local ssh_host="$2"	
		if [ -n "$3" ]; then
			local ssh_port="-p $3"
		fi
		local ssh_prefix="ssh ${ssh_host} ${ssh_port}"
	fi

	## If restoring full pool get all first-level subdirectories, since root dataset cannot be restored
	if [[ "${send_dataset_base}" == "${send_pool}/${receive_pool}" ]]; then
		local send_datasets=$(${ssh_prefix} zfs list -H -o name -r "${send_dataset_base}" | sed -n "s|^$send_dataset_base/\([^/]*\).*|$send_dataset_base/\1|p" | sort -u)
		if [ -z "${send_datasets}" ]; then echo "Error: dataset '${send_dataset_base}' does not exist or no child datasets found to restore"; exit 1; fi
	else
		local send_datasets="${send_dataset_base}"
	fi

	## Send all datasets including children (-R flag) as a backup (-b flag) to receive dataset
	for send_dataset in ${send_datasets}; do
		## Get latest snapshot on sending side
		latest_snapshot=$(${ssh_prefix} zfs list -t snap -o name -s creation "${send_dataset}" | tail -n 1)
		if [ -z "${latest_snapshot}" ]; then echo "Error: target '${send_dataset}' does not exist or no snapshots found to restore"; exit 1; fi

		## Set receive dataset
		receive_dataset="${send_dataset#$send_pool}"
		
		if ${ssh_prefix} zfs send -b -w -R "${latest_snapshot}" | zfs receive -v "${receive_dataset}"; then
			echo "Successfully send/received '${latest_snapshot}' into '${receive_dataset}'"
		else
			echo "Failed to send/receive '${latest_snapshot}' into '${receive_dataset}'"
		fi
	done
	
	## Use change-key with -i flag to set parent as encryption root for all datasets in receive pool
	for dataset in $(zfs list -H -o name -r "${receive_pool}" | tail -n +2); do
		if [[ $(zfs get -H encryptionroot -o value "${dataset}") != "${receive_pool}" ]]; then
			zfs load-key -L file:///etc/zfs/key/zfsroot.key "${dataset}"
			zfs change-key -l -i "${dataset}"
			echo "Encryption root of dataset '${dataset}' has been set to '${receive_pool}'"
		fi
	done

	## Sh
	echo "Encryption root has been set to '${receive_pool}' for all datasets:"
	zfs list -o name,encryptionroot -r "${receive_pool}"

	## Auto-unlock pool on boot
	zorra zfs auto-unlock "${receive_pool}"
}

## Set backup dataset and receiving pool
backup_dataset="$1"
shift 1

## Get any arguments
while [[ $# -gt 0 ]]; do
	case "$1" in
		--ssh)
			ssh_host="$2"
            shift 1
        ;;
		-p)
			ssh_port="$2"
            shift 1
        ;;
		*)
            echo "Error: unrecognized argument '$1' for 'zorra zfs restore-backup'"
            echo "Enter 'zorra --help' for command syntax"
            exit 1
		;;
	esac
	shift 1
done

## Run code
restore_backup "${backup_dataset}" "${ssh_host}" "${ssh_port}"