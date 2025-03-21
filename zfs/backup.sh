#!/bin/bash
set -e

validate_key(){
	## Get source dataset, backup snapshot and ssh prefix
	local source_dataset="$1"
	local backup_snapshot="$2"
	local ssh_prefix="$3"

	## Set source snapshot
	local source_snapshot="${source_dataset}@${backup_snapshot#*@}"

	## Source snapshot crypt_keydata
	#local crypt_keydata_source=$(${ssh_prefix} zfs send -w -p "${source_snapshot}" | zstreamdump -d | awk '/end crypt_keydata/{exit}1' | sed -n '/crypt_keydata/,$p' | sed 's/^[ \t]*//')
	crypt_keydata_source=""
	time while IFS= read -r line; do
		crypt_keydata_source+="${line}"$'\n'
		if [[ "${line}" == *"end crypt_keydata"* ]]; then
			pkill -P $$ ssh;
			crypt_keydata_source=$(sed -n '/crypt_keydata/,$ {s/^[ \t]*//; p}' <<< "${crypt_keydata_source}")
			break;
		fi;
	done < <(${ssh_prefix} zfs send -w -p "${source_snapshot}" | zstream dump -v)

	## Backup snapshot crypt_keydata
	#local crypt_keydata_backup=$(zfs send -w -p "${backup_snapshot}" | zstreamdump -d | awk '/end crypt_keydata/{exit}1' | sed -n '/crypt_keydata/,$p' | sed 's/^[ \t]*//')
	crypt_keydata_backup=""
	time while IFS= read -r line; do
		crypt_keydata_backup+="${line}"$'\n'
		if [[ "${line}" == *"end crypt_keydata"* ]]; then
			pkill -P $$ zfs;
			crypt_keydata_backup=$(sed -n '/crypt_keydata/,$ {s/^[ \t]*//; p}' <<< "${crypt_keydata_backup}")
			break;
		fi;
	done < <(zfs send -w -p "${backup_snapshot}" | zstream dump -v)

	## Compare local and remote crypt_keydata
	if cmp -s <(echo "${crypt_keydata_source}") <(echo "${crypt_keydata_backup}"); then
		return 0
	else
		return 1
	fi
}

pull_backup(){
	## Set source and backup pool and ssh prefix
	local source_pool="$1"
	local backup_pool="$2"
	local ssh_host="$3"
	local ssh_port="$4"

	## Set ssh prefix if ssh host is specified
	if [ -n "${ssh_host}" ]; then
		local ssh_prefix="ssh ${ssh_host}"
		if [ -n "${ssh_port}" ]; then
			ssh_prefix+=" -p ${ssh_port}"
		fi
	fi

	## Get source snapshots and extract source datasets from it (first native datasets, then clones)
	local source_snapshots=$(${ssh_prefix} zfs list -H -t all -o name,guid,origin,type -r "${source_pool}")
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
			if ! validate_key "${source_dataset}" "${latest_backup_snapshot}" "${ssh_prefix}"; then
				if [[ -n ${no_key_validation} ]]; then
					echo "No-key-validation flag set: ignoring crypt_keydata mismatch for '${source_dataset}'"
				else
					echo "Error: local and remote crypt_keydata are not equal for '${source_dataset}', skipping backup"

					## Send warning email
					#echo -e "Subject: WARNING: keychange on ${pool}\n\nSource and backup crypt_keydata are not equal\nAll backups have been disabled\n\ncrypt_keydata_source:\n${crypt_keydata_source}\n\ncrypt_keydata_backup:\n${crypt_keydata_backup}" | msmtp "${EMAIL_ADDRESS}"

					## Skip backup of dataset
					continue
				fi
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
			no_key_validation=true
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