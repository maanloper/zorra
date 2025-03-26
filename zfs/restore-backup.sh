#!/bin/bash
set -e

## Check for root priviliges
if [ "$(id -u)" -ne 0 ]; then
	echo "This command can only be run as root. Run with sudo or elevate to root."
	exit 1
fi

restore_backup(){
	cat<<-EOF

	To restore datasets from backup, the following requirements must be met:
	- The source pool must exist
	- The datasets to restore must not exist on the source pool
	- For remote restore:
	    - The ssh-user must have zfs send and hold permissions for the SOURCE pool
	    - The ssh-user must temporarily have full sudo access on SOURCE server
	      Enter 'visudo' and add to the end of the sudoers-file:
	      <ssh_user> ALL=(ALL:ALL) NOPASSWD: ALL
	    - The authorized_keys file of ssh-user must not restrict commands

	After inital restore of datasets, the backup functionality must be re-enabled
	for the restored datasets by running the same command with '--sync-encryption'

	NOTE: After restore of backup, remove the entry in the sudoers-file as it is a security risk!
	      Also reset any command restrictions in the authorized_keys file

	ONLY proceed if all the above requirements are met to prevent dataloss!

	EOF

	read -p "Proceed? (y/n): " confirm
	if [[ "${confirm}" != y ]]; then
		echo "Operation cancelled"
		exit 1
	fi

	## Set backup dataset and ssh arguments
	local backup_dataset_base="$1"
	local ssh_host="$2"
	local ssh_port="$3"

	## Set ssh prefix if ssh host is specified
	if [ -n "${ssh_host}" ]; then
		local ssh_prefix="ssh ${ssh_host}"
		if [ -n "${ssh_port}" ]; then
			ssh_prefix+=" -p ${ssh_port}"
		fi
	fi

	## Set backup and source pool and source dataset
	local backup_pool=$(echo "${backup_dataset_base}" | awk -F/ '{print $1}')
	local source_pool=$(echo "${backup_dataset_base}" | awk -F/ '{print $2}')
	local source_dataset_base=${backup_dataset_base#${backup_pool}/}

	## Get backup snapshots and extract backup datasets from it (first native datasets, then clones)
	local backup_snapshots=$(zfs list -H -t all -o name,guid,origin,type -r "${backup_dataset_base}" 2>/dev/null)
	local backup_datasets=$(echo "${backup_snapshots}" | awk '$3 == "-" && $4 == "filesystem" {print $1}')
	backup_datasets+=$(echo; echo "${backup_snapshots}" | awk '$3 != "-" && $4 == "filesystem" {print $1}')

	## Check if any datasets are available to restore
	if [[ -z "${backup_datasets}" ]]; then
		echo "No datasets found to restore, please check the specified dataset"
		exit 1
	fi

	## Check if parent dataset exists on source, otherwise create it
	local source_parent_dataset=$(dirname ${source_dataset_base})
	if [[ "${source_parent_dataset}" != "." ]] && ! ${ssh_prefix} sudo zfs list -H "${source_parent_dataset}" &>/dev/null; then
		echo "Parent dataset does not exist on source, creating '${source_parent_dataset}'"
		${ssh_prefix} sudo zfs create -p "${source_parent_dataset}"
	fi

	## Loop over backup datasets
	for backup_dataset in ${backup_datasets}; do
		## Do not restore root dataset (impossible)
		if [[ "${backup_dataset}" == "${backup_pool}/${source_pool}" ]]; then
			continue
		fi

		## Get origin for backup dataset
		local backup_dataset_origin=$(echo "${backup_snapshots}" | awk -v ds="${backup_dataset}" '$1 == ds && $4 == "filesystem" {print $3}')
		local origin_property=""

		## Set source dataset by stripping backup pool
		local source_dataset=${backup_dataset#${backup_pool}/}

		## Backup dataset is not a clone
		if [[ "${backup_dataset_origin}" == "-" ]]; then
			## Get oldest backup snapshot to use for initial full send
			local oldest_backup_snapshot=$(echo "${backup_snapshots}" | grep "^${backup_dataset}@" | awk '{print $1}' | head -n 1)

			## Execute a full send, receiving unmounted (while suppressing nvlist_lookup_string error message)
			echo "Receiving full stream of ${oldest_backup_snapshot} into ${source_dataset}"
			exit_code=0
			error=$(zfs send -w -p -b "${oldest_backup_snapshot}" | ${ssh_prefix} sudo zfs receive -u "${source_dataset}" 2>&1) || exit_code=$?
			if [[ ${exit_code} -ne 0 && ! "${error}" =~ "nvlist_lookup_string" ]]; then
				echo "${error}"
				exit 1
			fi

			## Set latest source snapshot to the above restored snapshot
			local latest_source_snapshot="${oldest_backup_snapshot}"

		## Backup dataset is a clone
		else
			## Check if origin still exists, otherwise skip restore
			if ! zfs list -H "${backup_dataset_origin}" &>/dev/null; then
				echo "Skipped restoring '${backup_dataset}' since origin '${backup_dataset_origin}' no longer exists"
				continue
			fi

			## Set origin property and latest source snapshot to backup dataset origin with backup pool stripped
			origin_property="-o origin=${backup_dataset_origin#${backup_pool}/}"
			local latest_source_snapshot="${backup_dataset_origin}"
		fi

		## Get latest backup snapshot
		local latest_backup_snapshot=$(echo "${backup_snapshots}" | grep "^${backup_dataset}@" | awk '{print $1}' | tail -n 1)
		
		## If newer snapshot is available execute incremental send, receiving unmounted (while suppressing nvlist_lookup_string error message)
		if [[ "${latest_backup_snapshot#*@}" != "${latest_source_snapshot#*@}" ]]; then
			echo "Receiving incremental stream from ${latest_source_snapshot} to ${latest_backup_snapshot} into ${source_dataset}"
			exit_code=0
			error=$(zfs send -w -p -b -I "${latest_source_snapshot}" "${latest_backup_snapshot}" | ${ssh_prefix} sudo zfs receive ${origin_property} -u "${source_dataset}" 2>&1) || exit_code=$?
				if [[ ${exit_code} -ne 0 && ! "${error}" =~ "nvlist_lookup_string" ]]; then
					echo "${error}"
					exit 1
				fi
		else
			echo "No new snapshots to restore for '${source_dataset}'"
		fi
	done

	## Use change-key with -i flag to set parent as encryption root for all datasets on source (executed after restore loop to not interrupt send/receive)
	local source_keylocation=$(${ssh_prefix} sudo zfs get -H -o value keylocation "${source_pool}")
	for backup_dataset in ${backup_datasets}; do
		## Set source dataset and origin of backup dataset
		local source_dataset=${backup_dataset#${backup_pool}/}
		local backup_dataset_origin=$(echo "${backup_snapshots}" | awk -v ds="${backup_dataset}" '$1 == ds && $4 == "filesystem" {print $3}')

		## Root dataset and clones cannot inherit encryption root
		if [[ "${source_dataset}" == "${source_pool}" || "${backup_dataset_origin}" != "-" ]]; then
			echo "Skipped setting encryption root on '${backup_dataset}' since it is the root dataset or a clone"
			continue
		fi

		## Try to load key with keyfile on source
		if ! ${ssh_prefix} sudo zfs load-key -L "${source_keylocation}" "${source_dataset}" &>/dev/null; then
			## Prompt for key
			echo "Keyfile cannot automatically unlock '${backup_dataset}', enter key manually below"
			while ! ${ssh_prefix} -t sudo zfs load-key -L prompt "${source_dataset}"; do
				true
			done
		fi

		## Set parent as encryption root on source
		echo "Setting encryption root of dataset '${source_dataset}' to inherited"
		${ssh_prefix} sudo zfs change-key -i "${source_dataset}"
	done

	## Mount datasets
	echo "Mounting all restored datasets..."
	${ssh_prefix} sudo zfs mount -a

	## Show datasets on source
	echo
	echo "Overview of datasets on source server after restore:"
	${ssh_prefix} zorra zfs list

	## Result
	cat<<-EOF
	Successfully restored datasets from '${backup_dataset_base}'

	Check if any unwanted datasets were restored, destroy them using 'zorra zfs destroy'

	After verifying the restore was successfull, re-enable backups by running the same commmand with '--sync-encryption'
	EOF
}

sync_encryption(){
	## Set backup dataset and ssh arguments
	local backup_dataset_base="$1"
	local ssh_host="$2"
	local ssh_port="$3"

	## Set ssh prefix if ssh host is specified
	if [ -n "${ssh_host}" ]; then
		local ssh_prefix="ssh ${ssh_host}"
		if [ -n "${ssh_port}" ]; then
			ssh_prefix+=" -p ${ssh_port}"
		fi
	fi

	## Set backup and source pool and source dataset
	local backup_pool=$(echo "${backup_dataset_base}" | awk -F/ '{print $1}')
	local source_pool=$(echo "${backup_dataset_base}" | awk -F/ '{print $2}')
	local source_dataset_base=${backup_dataset_base#${backup_pool}/}

	## Create snapshot on source
	${ssh_prefix} zorra zfs snapshot "${source_dataset_base}" -t post-restore

	## Pull new snapshot with --skip-key-validation flag (needed because of 'change-key -i')
	echo "Backing up postrestore snapshot with '--skip-key-validation' to restore backup functionality..."
	zorra zfs backup "${source_pool}" "${backup_pool}" --ssh "${ssh_host}" -p "${ssh_port}" --skip-key-validation

	## Show datasets on source
	echo
	echo "Overview of datasets on source server after restore:"
	${ssh_prefix} zorra zfs list

	## Result
	cat<<-EOF
	Successfully re-enabled backups for '${backup_dataset_base}'

	NOTE: Remember to remove the entry in the sudoers file on SOURCE server using 'visudo'
	      Leaving it in is a security risk!

	      Remember to reset any temporarily removed authorized_keys command restrictions on SOURCE server
	      
	EOF
}

## Set backup dataset and receiving pool
backup_dataset_base="$1"
shift 1

## Get any arguments
sync_encryption=false
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
		--sync-encryption)
			sync_encryption=true
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
if ${sync_encryption}; then
	sync_encryption "${backup_dataset_base}" "${ssh_host}" "${ssh_port}"
else
	restore_backup "${backup_dataset_base}" "${ssh_host}" "${ssh_port}"
fi