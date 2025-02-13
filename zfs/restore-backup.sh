#!/bin/bash
set -e

## Check for root priviliges
if [ "$(id -u)" -ne 0 ]; then
	echo "This command can only be run as root. Run with sudo or elevate to root."
	exit 1
fi

restore_backup(){
	## Set backup dataset and ssh prefix
	local backup_dataset_base="$1"
	local ssh_prefix="$2"

	## Set backup and source pool and source dataset
	local backup_pool=$(echo "${backup_dataset_base}" | awk -F/ '{print $1}')
	local source_pool=$(echo "${backup_dataset_base}" | awk -F/ '{print $2}')
	local source_dataset_base=${backup_dataset_base#${backup_pool}/}

	## Get backup snapshots (name, guid) and extract guid from it
	local backup_snapshots=$(zfs list -H -t all -o name,guid,origin,type -s creation -r "${backup_dataset_base}" 2>/dev/null)
	local backup_datasets=$(echo "${backup_snapshots}" | grep "filesystem$" | awk '{print $1}')
	if [[ -z "${backup_datasets}" ]]; then
		echo "No datasets found to restore, please check the specified dataset"
		exit 1
	fi

	## Check if parent dataset exists on source, otherwise create it
	local source_dataset_base=${backup_dataset_base#${backup_pool}/}
	if ! ${ssh_prefix} sudo zfs list -H "${source_dataset_base}" &>/dev/null; then
		echo "Parent dataset does not exist on source, creating '${source_dataset_base}'"
		${ssh_prefix} sudo zfs create -p "${source_dataset_base}"
	fi

	## Loop over backup datasets
	for backup_dataset in ${backup_datasets}; do
		## Do not restore root dataset (impossible)
		if [[ "${backup_dataset}" == "${backup_pool}/${source_pool}" ]]; then
			continue
		fi

		## Get origin for backup dataset
		local backup_dataset_origin=$(echo "${backup_snapshots}" | awk -v ds="${backup_dataset}" '$1 == ds && $4 == "filesystem" {print $3}')

		## Set source dataset by stripping backup pool
		source_dataset=${backup_dataset#${backup_pool}/}

		## Backup dataset is not a clone
		if [[ "${backup_dataset_origin}" == "-" ]]; then
			## Get oldest backup snapshot to use for initial full send
			local oldest_backup_snapshot=$(echo "${backup_snapshots}" | grep "^${backup_dataset}@" | awk '{print $1}' | head -n 1)

			## Execute a full send
			sudo zfs send -w -p "${oldest_backup_snapshot}" | ${ssh_prefix} sudo zfs receive -v "${source_dataset}"

			## Set latest source snapshot to the above restored snapshot
			local latest_source_snapshot="${oldest_backup_snapshot}"

		## Backup dataset is a clone
		else
			## Set origin property and latest source snapshot to backup dataset origin with backup pool stripped
			local origin_property="-o origin=${backup_dataset_origin#${backup_pool}/}"
			local latest_source_snapshot="${backup_dataset_origin}"
		fi

		## Get latest backup snapshot
		local latest_backup_snapshot=$(echo "${backup_snapshots}" | grep "^${backup_dataset}@" | awk '{print $1}' | tail -n 1)
		
		## If newer snapshot is available execute incremental send
		if [[ "${latest_backup_snapshot#*@}" != "${latest_source_snapshot#*@}" ]]; then
			echo "is this the error?"
			sudo zfs send -w -p -I "${latest_source_snapshot}" "${latest_backup_snapshot}" | ${ssh_prefix} sudo zfs receive -v ${origin_property} "${source_dataset}"
		else
			echo "No new snapshots to restore for '${source_dataset}'"
		fi
		echo
	done
	
	## Use change-key with -i flag to set parent as encryption root for all datasets on source (executed after restore loop to not interrupt send/receive)
	source_keyfile=$(${ssh_prefix} "sudo grep '^KEYFILE=' /usr/local/zorra/.env | cut -d'=' -f2-")
	for dataset in ${backup_datasets}; do
		## Root dataset cannot inherit encryption root
		if [[ "${backup_dataset}" == "${backup_pool}/${source_pool}" ]]; then
			continue
		fi

		## Try to load key with keyfile on source
		if ! ${ssh_prefix} sudo zfs load-key -L "file://${source_keyfile}" "${backup_dataset}" &>/dev/null; then
			## Prompt for key
			while ! ${ssh_prefix} sudo zfs load-key -L prompt "${backup_dataset}"; do
				true
			done
		fi

		## Set parent as encryption root on source
		${ssh_prefix} sudo zfs change-key -i "${backup_dataset}"
		echo "Encryption root of dataset '${backup_dataset}' has been set to '${source_pool}'"
	done

	## Mount all datasets on source
	${ssh_prefix} sudo zfs mount -a

	## Show encryption root of all datasets on source
	echo "Encryption root has been set to '${source_pool}' for all datasets:"
	${ssh_prefix} zfs list -o name,encryptionroot -r "${source_pool}"

	## Result
	echo "Successfully restored datasets from '${backup_dataset_base}'"
}

## Set backup dataset and receiving pool
backup_dataset_base="$1"
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

cat<<-EOF

To restore a full pool or dataset from backup, the following requirements MUST be met:
  - The datasets to restore must NOT exist on the source pool
  - For remote restore: the ssh-user MUST remporarily have ALL zfs permissions for the SOURCE pool
    Use 'zorra zfs allow <user> <pool> --all' on the source server for temporarily allowing all permissions 
    After restore of backup, restore permissions with 'zorra zfs allow <user> <pool> --restore')

ONLY proceed if all the above requirements are met to prevent dataloss!

EOF

read -p "Proceed? (y/n): " confirm
if [[ "${confirm}" != y ]]; then
	echo "Operation cancelled"
	exit 1
fi

## Set ssh prefix if ssh host is specified
if [ -n "${ssh_host}" ]; then
	ssh_prefix="ssh ${ssh_host}"
	if [ -n "${ssh_port}" ]; then
		ssh_prefix+=" -p ${ssh_port}"
	fi
fi

## Run code
restore_backup "${backup_dataset_base}" "${ssh_prefix}"