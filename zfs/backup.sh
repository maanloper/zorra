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

pull_backup(){
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
	if ${ssh_prefix} zfs send -b -w -R ${incremental_snapshot} "${latest_send_snapshot}" | zfs receive -v -o mountpoint=none "${receive_dataset}"; then
		echo "Successfully backed up '${latest_send_snapshot}' into '${receive_dataset}'"
	else
		echo "Error: failed to send/receive '${latest_send_snapshot}'$([ -n "${incremental_snapshot}" ] && echo " from incremental '${incremental_snapshot}'") into '${receive_dataset}'"
		#echo -e "Subject: Error backing up ${send_pool}\n\nFailed to create a backup of snapshot:\n${latest_send_snapshot}\n\nIncremental snapshot:\n${incremental_snapshot}\n\nReceive dataset:\n${receive_dataset}" | msmtp "${EMAIL_ADDRESS}"
		exit 1
	fi
}

########## -b flag creates "assert" problem
########## sending clone does not work now. Need to have a check in if dataset does not exist yet, if there is an 'origin' set, 
#			and then use that as the snapshot for the send, and receive in proper dataset,
#			while also setting origin=<snapshot> on receiving side?
# EG: zfs send -w -p droppi/vaultwarden_20250206T210325@20250206T155402-oioi | zfs receive -v -o origin=droppi/vaultwarden_20250206T210325@20250206T155402-oioi -u rpool/droppi/vaultwarden_20250206T210325_clone_20250206T155402-oioi
# does also not work??
########## remove -d flag, write code for backup_dataset?

pull_backup_v2(){
	## Set send and receive pool
	local source_pool="$1"
	local backup_pool="$2"

	source_pool="droppi"
	backup_pool="rpool"

	## Get source snapshots (name, guid) and extract source datasets from it
	source_snapshots_name_guid=$(${ssh_prefix} zfs list -H -t all -o name,guid  -s name -s creation -r "${source_pool}")
	source_datasets=$(echo "${source_snapshots_name_guid}" | grep -v @ | awk '{print $1}')

	## Get backup snapshots (name, guid) and extract guid and backup datasets from it
	#backup_root_dataset="${backup_pool}/${source_pool}"
	backup_snapshots_name_guid=$(zfs list -H -t all -o name,guid  -s name -s creation -r "${backup_pool}/${source_pool}" 2>/dev/null)
	backup_snapshots_guid=$(echo "${backup_snapshots_name_guid}" | awk '{print $2}')
	backup_datasets=$(echo "${backup_snapshots_name_guid}" | grep -v @ | awk '{print $1}')

	## Loop over source datasets
	for source_dataset in ${source_datasets}; do
		## Get guid for snapshots of for current dataset
		source_dataset_snapshots_guid=$(echo "${source_snapshots_name_guid}" | grep "^${source_dataset}@" | awk '{print $2}')
		
		## Get latest matching snapshot guid between source dataset snapshots and backup snapshots
		latest_backup_snapshot_guid=$(grep -Fx -f <(echo "${source_dataset_snapshots_guid}") <(echo "${backup_snapshots_guid}") | tail -n 1)
		
		## Check if a matching backup snapshot guid was found
		if [[ -n "${latest_backup_snapshot_guid}" ]]; then
			## Get latest backup snapshot
			latest_backup_snapshot=$(echo "${backup_snapshots_name_guid}" | grep "${latest_backup_snapshot_guid}" | awk '{print $1}')
		else
			## If current dataset is root dataset remove -d flag to create backup_pool/source_pool without errors
			d_flag="-d"
			if [[ "${source_dataset}" == "${source_pool}" ]]; then
				d_flag=""
			fi
			
			## Execute a full send of oldest source snapshot
			oldest_source_snapshot=$(echo "${source_snapshots_name_guid}" | grep "^${source_dataset}@" | awk '{print $1}' | head -n 1)
			echo "oldest_source_snapshot: $oldest_source_snapshot"
			${ssh_prefix} zfs send -w -p "${oldest_source_snapshot}" | zfs receive -v ${d_flag} -o mountpoint=none "${backup_pool}/${source_pool}"

			## Set latest backup snapshot to snapshot send above
			latest_backup_snapshot="${backup_pool}/${oldest_source_snapshot}"
			echo "latest_backup_snapshot: $latest_backup_snapshot"
		fi
		
		## Get latest source snapshot
		latest_source_snapshot=$(echo "${source_snapshots_name_guid}" | grep "^${source_dataset}@" | awk '{print $1}' | tail -n 1)
		
		## If name of source dataset has changed rename backup dataset
		if [[ "${latest_backup_snapshot%@*}" != "${backup_pool}/${latest_source_snapshot%@*}" ]]; then
			echo "Renaming ${latest_backup_snapshot%@*} to ${backup_pool}/${latest_source_snapshot%@*}"
			zfs rename "${latest_backup_snapshot%@*}" "${backup_pool}/${latest_source_snapshot%@*}"
		fi
		
		## If newer snapshot is available execute incremental send
		if [[ "${latest_source_snapshot#*@}" != "${latest_backup_snapshot#*@}" ]]; then
			${ssh_prefix} zfs send -w -p -I "${latest_backup_snapshot#*@}" "${latest_source_snapshot}" | zfs receive -v -o mountpoint=none -d "${backup_pool}/${source_pool}"	
		fi
		echo
	done

}

## Set backup dataset and receiving pool
send_pool="$1"
receive_pool="$2"
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
	validate_key "${send_pool}" "${receive_pool}"
fi

pull_backup "${send_pool}" "${receive_pool}" "${ssh_host}" "${ssh_port}"
