#!/bin/bash
set -e

get_crypt_keydata(){
	local snapshot="$1"
	local ssh_prefix="$2"

	## Add stdbuf to ssh_prefix if exists
	if [ -n "${ssh_prefix}" ]; then
		ssh_prefix="stdbuf -oL ${ssh_prefix}"
	fi

	## Create file descriptor for zfs send and store PID
	exec {zfs_send_fd}< <(exec ${ssh_prefix} stdbuf -oL zfs send -w -p "${snapshot}")
	local zfs_send_pid=$!

	## Create file descriptor for zstream dump and store PID
	exec {zstream_dump_fd}< <(exec stdbuf -oL zstream dump -v <&"${zfs_send_fd}")
	local zstream_dump_pid=$!

	## Read zstream dump, only recording crypt_keydata, then killing zfs send/zstream dump PID's
	local crypt_keydata=( )
	reading=false
	while IFS= read -r line; do
		if ! ${reading} && [[ "${line}" =~ ^[[:space:]]*crypt_keydata = \(embedded nvlist\)$ ]]; then
			reading=true
		fi
		if ${reading}; then
			crypt_keydata+=( "$(awk '{$1=$1};1' <<< "${line}")" )
			if [[ "${line}" =~ "(end crypt_keydata)" ]]; then
				kill "${zfs_send_pid}" "${zstream_dump_pid}" &>/dev/null
				wait "${zfs_send_pid}" "${zstream_dump_pid}"
				printf '%s\n' "${crypt_keydata[@]}"
				return 0
			fi
		fi
	done <&"${zstream_dump_fd}"
}

validate_key(){
	## Get source dataset, backup snapshot and ssh prefix
	local source_dataset="$1"
	local backup_snapshot="$2"
	local ssh_prefix="$3"

	## Set source snapshot
	local source_snapshot="${source_dataset}@${backup_snapshot#*@}"

	## Get crypt_keydata
	local crypt_keydata_source=$(get_crypt_keydata "${source_snapshot}" "${ssh_prefix}")
	local crypt_keydata_backup=$(get_crypt_keydata "${backup_snapshot}")

	## Compare source and backup crypt_keydata
	if [[ -n ${crypt_keydata_source} && "${crypt_keydata_source}" == "${crypt_keydata_backup}" ]]; then
		return 0
	else
		echo "Error: source and backup crypt_keydata are not equal for '${source_dataset}', creating file '/var/tmp/zorra_crypt_keydata_mismatch'"

		## Create file to stop any future backups
		touch /var/tmp/zorra_crypt_keydata_mismatch

		## Send warning email
		echo -e "Subject: WARNING: keychange for ${source_dataset}\n\nSource and backup crypt_keydata are not equal\n\ncrypt_keydata_source:\n${crypt_keydata_source}\n\ncrypt_keydata_backup:\n${crypt_keydata_backup}" | msmtp "${EMAIL_ADDRESS}"
		
		## Exit script
		exit 0
	fi
}

pull_backup(){
	## Set source and backup pool and ssh prefix
	local source_pool="$1"
	local backup_pool="$2"
	local ssh_host="$3"
	local ssh_port="$4"

	## Delete lockfile for pool if no-key-validation flag is set to re-enable backups 
	if ${no_key_validation}; then	
		rm -f /var/tmp/zorra_crypt_keydata_mismatch
	fi

	## Stop script if a crypt_keydata mismatch has been detected before
	if [[ -f /var/tmp/zorra_crypt_keydata_mismatch ]]; then
		echo "File '/var/tmp/zorra_crypt_keydata_mismatch' detected, skipping backups for '${source_pool}'"
		exit 0
	fi

	## Set ssh prefix if ssh host is specified
	if [ -n "${ssh_host}" ]; then
		local ssh_prefix="ssh ${ssh_host}"
		if [ -n "${ssh_port}" ]; then
			ssh_prefix+=" -p ${ssh_port}"
		fi
	fi
	
	## Get source snapshots and extract source datasets from it (first native datasets, then clones)
	local source_snapshots=$(${ssh_prefix} zfs list -H -t all -o name,guid,origin,type -r "${source_pool}")
	if [[ -z "${source_snapshots}" ]]; then
		echo "Error: cannot retrieve source snapshots for '${source_pool}', skipping backup"

		## Send warning email and exit
		echo -e "Subject: Backup error for ${source_pool}\n\nCannot retrieve source snapshots for:\n${source_pool}" | msmtp "${EMAIL_ADDRESS}"
		exit 0
	fi
	local source_datasets=$(echo "${source_snapshots}" | awk '$3 == "-" && $4 == "filesystem" {print $1}')
	source_datasets+=$(echo; echo "${source_snapshots}" | awk '$3 != "-" && $4 == "filesystem" {print $1}')

	## Get backup snapshots (name, guid) and extract guid from it
	local backup_snapshots=$(zfs list -H -t all -o name,guid,origin,type -r "${backup_pool}/${source_pool}" 2>/dev/null)
	local backup_snapshots_guid=$(echo "${backup_snapshots}" | awk '{print $2}')

	## Check if root dataset exists on backup pool, otherwise create it
	if ! grep -q "^${backup_pool}/${source_pool}[^/]" <<< "${backup_snapshots}"; then
		echo "Root dataset does not exist, creating '${backup_pool}/${source_pool}'"
		zfs create -p -o canmount=off -o mountpoint=none "${backup_pool}/${source_pool}"
	fi

	## Loop over source datasets
	for source_dataset in ${source_datasets}; do
		## Never backup root dataset (causes errors after restore)
		if [[ "${source_dataset}" == "${source_pool}" ]]; then
			continue
		fi

		## Skip datasets that contain "nobackup"
		if [[ "${source_dataset}" =~ "nobackup" ]]; then
			echo "Skipped backing up '${source_dataset}' due to 'nobackup' in dataset name"
			continue
		fi

		## Get guid for snapshots of current dataset, skip if no snapshots found
		local source_dataset_snapshots_guid=$(echo "${source_snapshots}" | grep "^${source_dataset}@" | awk '{print $2}')
		if [[ -z "${source_dataset_snapshots_guid}" ]]; then
			echo "Skipped backing up '${source_dataset}' since it has no snapshots to send"
			continue
		fi

		## Get origin for source dataset
		local source_dataset_origin=$(echo "${source_snapshots}" | awk -v ds="${source_dataset}" '$1 == ds && $4 == "filesystem" {print $3}')
		local origin_property=""
		
		## Get latest matching snapshot guid between source dataset snapshots and backup snapshots
		local latest_backup_snapshot_guid=$(grep -Fx -f <(echo "${source_dataset_snapshots_guid}") <(echo "${backup_snapshots_guid}") | tail -n 1)

		## No backup dataset found and source dataset is not a clone
		if [[ -z "${latest_backup_snapshot_guid}" && "${source_dataset_origin}" == "-" ]]; then
			## Get oldest source snapshot to use for initial full send
			local oldest_source_snapshot=$(echo "${source_snapshots}" | grep "^${source_dataset}@" | awk '{print $1}' | head -n 1)

			## Execute a full send
			${ssh_prefix} zfs send -w -p "${oldest_source_snapshot}" | zfs receive -v -o canmount=off "${backup_pool}/${source_dataset}"

			## Set latest backup snapshot to the above backed up snapshot
			local latest_backup_snapshot="${oldest_source_snapshot}"

		## No backup dataset found and source dataset is a clone
		elif [[ -z "${latest_backup_snapshot_guid}" && "${source_dataset_origin}" != "-" ]]; then
			## Set origin property and latest backup snapshot to source dataset origin
			origin_property="-o origin=${backup_pool}/${source_dataset_origin}"
			local latest_backup_snapshot="${source_dataset_origin}"

		## Backup dataset found (set latest_backup_snapshot and promote/rename of datasets)
		elif [[ -n "${latest_backup_snapshot_guid}" ]]; then
			## Get latest backup snapshot and backup dataset
			local latest_backup_snapshot=$(echo "${backup_snapshots}" | grep "${latest_backup_snapshot_guid}" | awk '{print $1}')
			local backup_dataset="${latest_backup_snapshot%@*}"

			## Validate crypt_keydata of dataset
			if ${skip_key_validation}; then
				echo "Skip-key-validation flag set, skipping key validation for '${source_dataset}'"
			else
				validate_key "${source_dataset}" "${latest_backup_snapshot}" "${ssh_prefix}"
			fi

			## Get origin for backup dataset
			local backup_dataset_origin=$(echo "${backup_snapshots}" | awk -v ds="${backup_dataset}" '$1 == ds && $4 == "filesystem" {print $3}')

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
				backup_snapshots=$(zfs list -H -t all -o name,guid,origin,type -r "${backup_pool}/${source_pool}" 2>/dev/null)
				latest_backup_snapshot=$(echo "${backup_snapshots}" | grep "${latest_backup_snapshot_guid}" | awk '{print $1}')
			fi
		else
			echo "Error determining how to process source dataset '${source_dataset}'"

			## Send warning email
			echo -e "Subject: Backup error for ${source_dataset}\n\nError determining how to process source dataset:\n${source_dataset}" | msmtp "${EMAIL_ADDRESS}"
			continue
		fi

		## Get latest source snapshot
		local latest_source_snapshot=$(echo "${source_snapshots}" | grep "^${source_dataset}@" | awk '{print $1}' | tail -n 1)
		
		## If newer snapshot is available execute incremental send
		if [[ "${latest_backup_snapshot#*@}" != "${latest_source_snapshot#*@}" ]]; then
			${ssh_prefix} zfs send -w -p -I "${latest_backup_snapshot#${backup_pool}/}" "${latest_source_snapshot}" | zfs receive -v ${origin_property} -o canmount=off "${backup_pool}/${source_dataset}"
		else
			echo "No new snapshots to back up for '${source_dataset}'"
		fi
	done
}

## Set backup dataset and receiving pool
source_pool="$1"
backup_pool="$2"
shift 2

## Get any arguments
skip_key_validation=false
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
		--skip-key-validation)
			skip_key_validation=true
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
pull_backup "${source_pool}" "${backup_pool}" "${ssh_host}" "${ssh_port}"