#!/bin/bash
set -e

## Check for root priviliges
if [ "$(id -u)" -ne 0 ]; then
	echo "This command can only be run as root. Run with sudo or elevate to root."
	exit 1
fi

restore_from_backup(){
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
		echo "Getting datasets for full pool restore..."
		local send_datasets=$(${ssh_prefix} zfs list -H -o name -r "${send_dataset_base}" | sed -n "s|^$send_dataset_base/\([^/]*\).*|$send_dataset_base/\1|p" | sort -u)
		if [ -z "${send_datasets}" ]; then echo "Error: dataset '${send_dataset_base}' does not exist or no child datasets found to restore"; exit 1; fi
	else
		local send_datasets="${send_dataset_base}"
	fi

	## Send all datasets including children (-R flag) as a backup (-b flag) to receive dataset with verbosity on (-v flag)
	for send_dataset in ${send_datasets}; do
		## Get latest snapshot on sending side
		echo "Getting latest snapshot for '${send_dataset}'..."
		local latest_snapshot=$(${ssh_prefix} zfs list -H -t snap -o name -s creation "${send_dataset}" | tail -n 1)
		if [ -z "${latest_snapshot}" ]; then echo "Error: target '${send_dataset}' does not exist or no snapshots found to restore"; exit 1; fi

		## Set receive dataset
		local receive_dataset="${send_dataset#$send_pool/}"

		## Execute send/receive (pull)
		echo "Sending/receiving '${send_dataset}' into '${receive_dataset}'..."
		if ${ssh_prefix} zfs send -b -w -R "${latest_snapshot}" | zfs receive -v "${receive_dataset}"; then
			echo "Successfully send/received '${send_dataset}' into '${receive_dataset}'"
		else
			echo "Failed to send/receive '${send_dataset}' into '${receive_dataset}'"
			#exit 1
		fi
	done
	
	## Use change-key with -i flag to set parent as encryption root for all datasets in receive pool
	for dataset in $(zfs list -H -o name -r "${receive_pool}" | tail -n +2); do
		if [[ $(zfs get -H encryptionroot -o value "${dataset}") != "${receive_pool}" ]]; then
			if ! zfs load-key -L "file://${KEYFILE}" "${dataset}" &>/dev/null; then
				## Prompt for key
				while ! zfs load-key -L prompt "${dataset}"; do
					true
				done
			fi
			zfs change-key -l -i "${dataset}"
			echo "Encryption root of dataset '${dataset}' has been set to '${receive_pool}'"
		fi
	done

	## Show encryption root of all datasets
	echo "Encryption root has been set to '${receive_pool}' for all datasets:"
	zfs list -o name,encryptionroot -r "${receive_pool}"

	## Run zfs auto-unlock to make sure pool has keylocation set to keyfile and unlocks on boot
	zorra zfs auto-unlock "${receive_pool}"

	## Result
	echo "Successfully restored datasets from '${send_dataset_base}'"
}

## This function fixes backup functionality with -R flag after a full pool restore (push send/receive)
fix_backup_functionality(){
	## Set send and receive pool
	backup_dataset="$1"
	local send_pool=$(echo "${backup_dataset}" | awk -F/ '{print $2}')
	local receive_pool=$(echo "${backup_dataset}" | awk -F/ '{print $1}')

	## Define backup_dataset
	local backup_dataset="${receive_pool}/${send_pool}"

	## Set ssh prefix if ssh host is specified
	if [ -n "$2" ]; then
		local ssh_host="$2"	
		if [ -n "$3" ]; then
			local ssh_port="-p $3"
		fi
		local ssh_prefix="ssh ${ssh_host} ${ssh_port}"
	fi

	## Rename receive_pool/send_pool to receive_pool/send_pool_TMP
	if ${ssh_prefix} zfs rename "${backup_dataset}" "${backup_dataset}_TMP"; then
		echo "Renamed ${backup_dataset} to ${backup_dataset}_TMP"
	else
		echo "Error: failed renaming ${backup_dataset} to ${backup_dataset}_TMP"
		exit 1
	fi


	## Send/receive only root dataset as full send (push)
	echo "Recreating root dataset on backup pool..."
	local latest_root_snapshot=$(zfs list -H -t snap -o name -s creation "${send_pool}" | tail -n 1)
	if zfs send -b -w "${latest_root_snapshot}" | ${ssh_prefix} zfs receive -v "${backup_dataset}"; then
		echo "Recreated root dataset '${backup_dataset}' on backup pool"
	else
		echo "Error: failed to send/receive '${latest_root_snapshot}' into '${backup_dataset}'"
		#exit 1
	fi

	## Rename all first-level datasets in _tmp dataset to original name
	echo "Renaming child datasets..."
	for dataset in $(${ssh_prefix} zfs list -H -o name -r "${backup_dataset}_TMP" | sed -n "s|^${backup_dataset}_TMP/\([^/]*\).*|${backup_dataset}_TMP/\1|p" | sort -u); do
		if ${ssh_prefix} zfs rename "${dataset}" "${dataset/${backup_dataset}_TMP/${backup_dataset}}"; then
			echo "Renamed ${dataset} to ${dataset/${backup_dataset}_TMP/${backup_dataset}}"
		else
			echo "Error: failed to rename ${dataset} to ${dataset/${backup_dataset}_TMP/${backup_dataset}}"
			#exit 1
		fi
	done

	## Destroy _tmp dataset
	echo "we get here??"
	${ssh_prefix} zfs destroy -r "${backup_dataset}_TMP"
	echo "Destroyed ${backup_dataset}_TMP"
	
	## Get all first-level datasets (since root dataset cannot be restored, after a full pool restore the (not restored) root dataset has no matching snapshots on backup pool)
	local send_datasets=$(zfs list -H -o name -r "${send_pool}" | sed -n "s|^${send_pool}/\([^/]*\).*|${send_pool}/\1|p" | sort -u)
	if [ -z "${send_datasets}" ]; then echo "Error: pool '${send_pool}' does not exist or has no child datasets to backup"; exit 1; fi

	## Send/receive all first-level datasets including children (-R flag) with verbosity on (-v flag)
	for send_dataset in ${send_datasets}; do
		## Get latest snapshot on sending side
		local latest_send_snapshot=$(zfs list -H -t snap -o name -s creation "${send_dataset}" | tail -n 1)
		if [ -z "${latest_send_snapshot}" ]; then echo "Error: target '${send_dataset}' does not exist or has no snapshots to backup"; exit 1; fi

		## Set receive dataset
		local receive_dataset="${receive_pool}/${send_dataset}"

		## Get latest snapshot on receiving side, set incremental if it exists
		local latest_receive_snapshot=$(${ssh_prefix} zfs list -H -t snap -o name -s creation "${receive_dataset}" | tail -n 1)
		if [ -n "${latest_receive_snapshot}" ]; then
			local incremental_snapshot="-I ${latest_receive_snapshot#*@}"
		else
			echo "No received snapshot found, executing a full send/receive..."
		fi

		## Execute send/receive (push)
		if zfs send -b -w -R ${incremental_snapshot} "${latest_send_snapshot}" | ${ssh_prefix} zfs receive -v "${receive_dataset}"; then
			echo "Successfully backed up '${latest_send_snapshot}' into '${receive_dataset}'"
		else
			echo "Failed to send/receive '${latest_send_snapshot}'$([ -n "${incremental_snapshot}" ] && echo " from incremental '${incremental_snapshot}'") into '${receive_dataset}'"
			#exit 1
		fi
	done
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
		--post-restore)
			post_restore=true
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
if ${post_restore}; then

	fix_backup_functionality "${backup_dataset}" "${ssh_host}" "${ssh_port}"
else
	restore_from_backup "${backup_dataset}" "${ssh_host}" "${ssh_port}"
fi