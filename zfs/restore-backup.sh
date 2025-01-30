#!/bin/bash
set -e

## Check for root priviliges
if [ "$(id -u)" -ne 0 ]; then
    echo "This command can only be run as root. Run with sudo or elevate to root."
    exit 1
fi

restore_backup(){
	## Set backup dataset, receive pool and ssh
	local backup_dataset="$1"
	local backup_pool=$(echo "${backup_dataset}" | awk -F/ '{print $1}')
	local receive_dataset="$2"
	local receive_pool=$(echo "${receive_dataset}" | awk -F/ '{print $1}')
	echo "backup_dataset $backup_dataset"
	echo "backup_pool $backup_pool"
	echo "receive_dataset $receive_dataset"
	echo "receive_pool $receive_pool"

	if [ -n "$3" ]; then
		local ssh_host="$3"	
		if [ -n "$4" ]; then
			local ssh_port="-p $4"
		fi
		local ssh_prefix="ssh ${ssh_host} ${ssh_port}"
	fi

	## Set base datasets
	if [[ "${receive_dataset}" == "${receive_pool}" ]]; then
		## If receive dataset = receive pool (i.e. restoring full pool), get base datasets
		backup_datasets=$(${ssh_prefix} zfs list -H -o name -r "${backup_dataset}" | awk -F/ -v prefix="${backup_pool}/" '{if ($2 != "") print prefix$2}' | sort -u)
		if [ -z "${backup_datasets}" ]; then echo "No datasets found to restore"; exit 1; fi
	else
		backup_datasets="${backup_dataset}"
	fi
	echo "backup_datasets $backup_datasets"

	## Get latest backup snapshot
	backup_snapshot=$(${ssh_prefix} zfs list -t snap -o name -s creation "${backup_dataset}" | tail -n 1 | awk -F@ '{print $2}')
	if [ -z "${backup_snapshot}" ]; then echo "No snapshots found to restore"; exit 1; fi

	## Send all base datasets (except root-dataset) with -R flag back (-b flag) to destination dataset
	for backup_dataset in ${backup_datasets}; do
		if [[ "${receive_dataset}" == "${receive_pool}" ]]; then
			rec_dataset="${receive_pool}/${backup_dataset#$backup_pool/}"
		else
			rec_dataset="${receive_dataset}"
		fi
		echo "rec_dataset $rec_dataset"
		echo "backup_dataset@backup_snapshot ${backup_dataset}@${backup_snapshot}"
		exit 0

		if ${ssh_prefix} zfs send -b -w -R "${backup_dataset}@${backup_snapshot}" | zfs receive -v "${rec_dataset}"; then
			echo "Successfully send/received '${backup_dataset}@${backup_snapshot}' into '${rec_dataset}'"
		else
			echo "Failed to send/receive '${backup_dataset}@${backup_snapshot}' into '${rec_dataset}'"
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
receive_dataset="$2"
shift 2

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
restore_backup "${backup_dataset}" "${receive_dataset}" "${ssh_host}" "${ssh_port}"