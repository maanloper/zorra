#!/bin/bash
set -e

## Function to destroy snapshot and report any failures
destroy_snapshot(){
	local snapshot="$1"
	local snapshot_age="$2"

	## Destroy the snapshot
	if zfs destroy "${snapshot}"; then
		echo "Successfully pruned  ${snapshot_age} days old snapshot: ${snapshot}"
	else
        echo "Error: failed destroying snapshot '${snapshot}' of age ${snapshot_age} days"
		echo -e "Subject: Error destroying snapshot\n\nSnapshot:\n${snapshot}\n\nAge:${snapshot_age}" | msmtp "${EMAIL_ADDRESS}"
		return 1
	fi
}

find_snapshots_to_prune(){
	## Get dataset to prune
	local dataset="$1"

	## Get current date in seconds since epoch
	local current_date=$(date +%s)

	## Loop through all snapshots
	local i=0
	local snapshot
	local creation
	local clones
	while read -r snapshot creation clones; do
		## Skip if snapshot has clones
		if [[ "${clones}" != "-" ]]; then
			echo "Skipped pruning snapshot '${snapshot}' because it has clones"
			continue
		fi

		## Get retention policy from snapshot name
		local retention_policy="${snapshot##*-}"

		## Calculate the snapshot's age in days
		local snapshot_age=$(( (current_date - creation) / 86400 ))

		## Prune daily snapshots older than daily retention
		if [[ "${retention_policy}" == "daily" && "${snapshot_age}" -gt "${SNAPSHOT_DAILY_RETENTION}" ]]; then
			destroy_snapshot "${snapshot}" "${snapshot_age}" && ((i+=1))

		## Prune monthly snapshots older than monthly retention
		elif [[ "${retention_policy}" == "monthly" && "${snapshot_age}" -gt "${SNAPSHOT_MONTHLY_RETENTION}" ]]; then
			destroy_snapshot "${snapshot}" "${snapshot_age}" && ((i+=1))

		## Prune all other snapshots older than global retention
		elif [[ "$snapshot_age" -gt "${SNAPSHOT_OTHER_RETENTION}" ]]; then
			destroy_snapshot "${snapshot}" "${snapshot_age}" && ((i+=1))
		fi
	done < <(zfs list -H -p -o name,creation,clones -t snapshot -r ${dataset})

	## Report on result
	if [[ "${i}" -gt 0 ]];then
		echo "Succesfully pruned ${i} snapshots"
	else
		echo "No snapshots pruned"
	fi
}


## Parse arguments
case $# in
    1)
        ## Prune specific dataset
        find_snapshots_to_prune "$1"
        ;;
    *)
        echo "Error: wrong number of arguments for 'prune-snapshots'"
        echo "Enter 'zorra --help' for command syntax"
        exit 1
        ;;
esac