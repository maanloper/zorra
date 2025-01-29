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
	local receive_pool="$2"
	echo "backup_dataset: $backup_dataset"
	echo "receive_pool: $receive_pool"

	if [ -n "$3" ]; then
		local ssh_host="$3"	
		if [ -n "$4" ]; then
			local ssh_port="-p $4"
		fi
		local ssh_prefix="ssh ${ssh_host} ${ssh_port}"
	fi
	echo "ssh_prefix: $ssh_prefix"

	## Get base datasets, either local or over ssh
	base_datasets=$(${ssh_prefix} zfs list -H -o name -r "${backup_dataset}" | sed -n "s|^$backup_dataset/\\([^/]*\\).*|\\1|p" | sort -u) || exit 1
	echo "base_datasets: $base_datasets"

	## Get latest backup snapshot
	backup_snapshot=$(${ssh_prefix} zfs list -t snap -o name -s creation "${backup_dataset}" | tail -n 1 | awk -F@ '{print $2}') || exit 1
	echo "backup_snapshot: $backup_snapshot"

	## Send all base datasets (except root-dataset) with -R flag back (-b flag) to destination dataset
	for base_dataset in ${base_datasets}; do
		if ${ssh_prefix} zfs send -b -w -R "${backup_dataset}/${base_dataset}@${backup_snapshot}" | zfs receive -v "${receive_pool}/${base_dataset}"; then
			echo "Successfully send/received '${backup_dataset}/${base_dataset}@${backup_snapshot}' into '${receive_pool}/${base_dataset}'"
		else
			echo "Failed to send/receive '${backup_dataset}/${base_dataset}@${backup_snapshot}' into '${receive_pool}/${base_dataset}'"
		fi
	done

	## Use change-key with -i flag to set parent as encryption root
	for dataset in $(zfs list -H -o name -r "${receive_pool}" | tail -n +2); do
		if [[ $(zfs get -H encryptionroot -o value "${dataset}") != "${receive_pool}" ]]; then
			zfs load-key -L file:///etc/zfs/key/zfsroot.key "${dataset}"
			zfs change-key -l -i "${dataset}"
			echo "Encryption root of dataset '${dataset}' has been set to '${receive_pool}'"
		fi
	done

	exit 0

	echo "Encryption root has been set to '${receive_pool}' for all datasets:"
	zfs list -o name,encryptionroot -r "${receive_pool}"

	## Auto-unlock pool on boot
	zorra zfs auto-unlock "${receive_pool}"
}

## Set backup dataset and receiving pool
backup_dataset="$1"
receive_pool="$2"
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
restore_backup "${backup_dataset}" "${receive_pool}" "${ssh_host}" "${ssh_port}"