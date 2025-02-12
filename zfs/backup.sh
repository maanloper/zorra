#!/bin/bash
set -e

## Check for root priviliges
if [ "$(id -u)" -ne 0 ]; then
	echo "This command can only be run as root. Run with sudo or elevate to root."
	exit 1
fi

validate_key(){
	## Check if disable_backups-file exists (triggered by key change)
	if [ -f /usr/local/zorra/disable_backups ]; then
		echo "Error: no backup created due to triggered by disable_backups-file"
		exit 1
	fi

	## Set send and receive pool
	local send_pool="$1"
	local receive_pool="$2"

	## Get latest local snapshot (a snapshot must be send to check crypt_keydata)
	latest_root_dataset_snapshot=$(zfs list -H -t snapshot -o name -s creation "${pool}" | tail -n 1)

	## Latest local crypt_keydata
	crypt_keydata_local="./crypt_keydata_${pool}_local"
	output=$(zfs send -w "${latest_root_dataset_snapshot}" | zstreamdump -d | awk '/end crypt_keydata/{exit}1')
	echo "$output" | sed -n '/crypt_keydata/,$p' | sed 's/^[ \t]*//' > "${crypt_keydata_local}"

	## Latest remote crypt_keydata
	crypt_keydata_remote="./crypt_keydata_${pool}_remote"
	output=$(zfs send -w "${latest_root_dataset_snapshot}" | zstreamdump -d | awk '/end crypt_keydata/{exit}1')
	echo "$output" | sed -n '/crypt_keydata/,$p' | sed 's/^[ \t]*//' > "${crypt_keydata_remote}"
	
	## Compare local and remote crypt_keydata
	if ! cmp -s ${crypt_keydata_local} ${crypt_keydata_remote}; then
		echo "Error: local and remote crypt_keydata are not equal"
		echo "Creating file '/usr/local/zorra/disable_backups' and exiting script"

		## Create file to disable further backup tries
		touch /usr/local/zorra/disable_backups

		## Send warning email
		echo -e "Subject: WARNING: keychange on ${pool}\n\nLocal and remote crypt_keydata are not equal\ncrypt_keydata_local:\n${crypt_keydata_local}\n\crypt_keydata_remote:\n${crypt_keydata_remote}" | msmtp "${EMAIL_ADDRESS}"

		## Stop execution
		exit 1
	fi
}

pull_backup_old(){
	## Set send and receive pool
	local send_pool="$1"
	local receive_pool="$2"

	## Set ssh prefix if ssh host is specified
	if [ -n "$3" ]; then
		local ssh_host="$3"
		if [ -n "$4" ]; then
			local ssh_port="-p $4"
		fi
		local ssh_prefix="ssh ${ssh_host} ${ssh_port}"
	fi

	## Get latest snapshot on sending side
	local latest_send_snapshot=$(${ssh_prefix} zfs list -H -t snap -o name -s creation "${send_pool}" 2>/dev/null | tail -n 1)
	if [ -z "${latest_send_snapshot}" ]; then echo "Error: target '${send_pool}' does not exist or has no snapshots to backup"; exit 1; fi

	## Set receive dataset
	local receive_dataset="${receive_pool}/${send_pool}"

	## Get latest snapshot on receiving side, set incremental if it exists
	local latest_receive_snapshot=$(zfs list -H -t snap -o name -s creation "${receive_dataset}" 2>/dev/null | tail -n 1 )
	if [ -n "${latest_receive_snapshot}" ]; then
		local incremental_snapshot="-I ${latest_receive_snapshot#*@}"
	else
		echo "No received snapshot found, executing a full send/receive..."
	fi

	## Execute send/receive (pull)
	if ${ssh_prefix} zfs send -w -R ${incremental_snapshot} "${latest_send_snapshot}" | zfs receive -v -o mountpoint=none "${receive_dataset}"; then
		echo "Successfully backed up '${latest_send_snapshot}' into '${receive_dataset}'"
	else
		echo "Error: failed to send/receive '${latest_send_snapshot}'$([ -n "${incremental_snapshot}" ] && echo " from incremental '${incremental_snapshot}'") into '${receive_dataset}'"
		#echo -e "Subject: Error backing up ${send_pool}\n\nFailed to create a backup of snapshot:\n${latest_send_snapshot}\n\nIncremental snapshot:\n${incremental_snapshot}\n\nReceive dataset:\n${receive_dataset}" | msmtp "${EMAIL_ADDRESS}"
		exit 1
	fi
}


pull_backup(){
	## Set send and receive pool
	local source_pool="$1"
	local backup_pool="$2"

	#source_pool="droppi"
	#backup_pool="rpool"

	## Get source snapshots (name, guid) and extract source datasets from it
	local source_snapshots=$(${ssh_prefix} zfs list -H -t all -o name,guid,origin,type -s name -s creation -r "${source_pool}")
	local source_datasets=$(echo "${source_snapshots}" | grep "filesystem$" | awk '{print $1}')

	## Get backup snapshots (name, guid) and extract guid and backup datasets from it
	local backup_snapshots=$(zfs list -H -t all -o name,guid,origin,type -s name -s creation -r "${backup_pool}/${source_pool}" 2>/dev/null)
	local backup_snapshots_guid=$(echo "${backup_snapshots}" | awk '{print $2}')

	## Loop over source datasets
	for source_dataset in ${source_datasets}; do
		## Get guid for snapshots of current dataset, skip if no snapshots found
		local source_dataset_snapshots_guid=$(echo "${source_snapshots}" | grep "^${source_dataset}@" | awk '{print $2}')
		if [[ -z "${source_dataset_snapshots_guid}" ]]; then
			echo "Skipping '${source_dataset}' since it has no snapshots to send"
			continue
		fi

		## Get source origin for dataset
		local source_dataset_origin=$(echo "${source_snapshots}" | awk -v ds="$source_dataset" '$1 == ds && $4 == "filesystem" {print $3}')
		
		## Get latest matching snapshot guid between source dataset snapshots and backup snapshots
		local latest_backup_snapshot_guid=$(grep -Fx -f <(echo "${source_dataset_snapshots_guid}") <(echo "${backup_snapshots_guid}") | tail -n 1)

		## No backup dataset found and source dataset is not a clone
		if [[ -z "${latest_backup_snapshot_guid}" && "${source_dataset_origin}" == "-" ]]; then
			## Get oldest source snapshot to use for initial full send
			local oldest_source_snapshot=$(echo "${source_snapshots}" | grep "^${source_dataset}@" | awk '{print $1}' | head -n 1)

			## Execute a full send
			${ssh_prefix} zfs send -w -p "${oldest_source_snapshot}" | zfs receive -v -o mountpoint=none "${backup_pool}/${source_dataset}"

			## Set latest backup snapshot to just sent snapshot
			local latest_backup_snapshot="${oldest_source_snapshot}"

		## No backup dataset found and source dataset is a clone
		elif [[ -z "${latest_backup_snapshot_guid}" && "${source_dataset_origin}" != "-" ]]; then
			## Set origin property and incremental base to source dataset origin
			local origin_property="-o origin=${backup_pool}/${source_dataset_origin}"
			local latest_backup_snapshot="${source_dataset_origin}"

		## Backup dataset found
		elif [[ -n "${latest_backup_snapshot_guid}" ]]; then
			## Get latest backup snapshot and backup dataset
			local latest_backup_snapshot=$(echo "${backup_snapshots}" | grep "${latest_backup_snapshot_guid}" | awk '{print $1}')
			local backup_dataset="${latest_backup_snapshot%@*}"

			## Get backup origin for dataset
			local backup_dataset_origin=$(echo "${backup_snapshots}" | awk -v ds="$backup_dataset" '$1 == ds && $4 == "filesystem" {print $3}')

			## If source and backup origin are not equal, source must have been promoted
			if [[ "${backup_dataset_origin}" != "-" && "${backup_dataset_origin}" != "${backup_pool}/${source_dataset_origin}" ]]; then
				echo "Promoting ${backup_dataset}"
				zfs promote "${backup_dataset}"
			fi

			## If name of source dataset has changed rename backup dataset
			if [[ "${backup_dataset}" != "${backup_pool}/${source_dataset}" ]]; then
				echo "Renaming ${backup_dataset} to ${backup_pool}/${source_dataset}"
				zfs rename "${backup_dataset}" "${backup_pool}/${source_dataset}"

				## Refresh backup snapshots list to prevent trying to rename child datasets
				backup_snapshots=$(zfs list -H -t all -o name,guid,origin,type -s name -s creation -r "${backup_pool}/${source_pool}" 2>/dev/null)
				local latest_backup_snapshot=$(echo "${backup_snapshots}" | grep "${latest_backup_snapshot_guid}" | awk '{print $1}')
			fi
		else
			echo "Error determining how to process source dataset '${source_dataset}'"
		fi

		## Get latest source snapshot
		local latest_source_snapshot=$(echo "${source_snapshots}" | grep "^${source_dataset}@" | awk '{print $1}' | tail -n 1)
		
		## If newer snapshot is available execute incremental send
		if [[ "${latest_backup_snapshot#*@}" != "${latest_source_snapshot#*@}" ]]; then
			${ssh_prefix} zfs send -w -p -I "${latest_backup_snapshot#${backup_pool}/}" "${latest_source_snapshot}" | zfs receive -v ${origin_property} -o mountpoint=none "${backup_pool}/${source_dataset}"	
		fi

		echo
	done

}

## Set backup dataset and receiving pool
source_pool="$1"
backup_pool="$2"
shift 2

## Init args
validate_key=false

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
		--no-key-validation)
			validate_key=false
 		;;
		*)
 			echo "Error: unrecognized argument '$1' for 'zorra zfs backup'"
 			echo "Enter 'zorra --help' for command syntax"
 			exit 1
		;;
	esac
	shift 1
done

## Run code
if ${validate_key}; then
	validate_key "${source_pool}" "${backup_pool}"
fi

pull_backup "${source_pool}" "${backup_pool}" "${ssh_host}" "${ssh_port}"
