#!/bin/bash

## Set flag if script is run by systemd
systemd=false
if [[ $(ps -o comm= -p $(ps -o ppid= -p $$)) == "systemd" ]]; then
    systemd=true
fi

## Function to destroy snapshot and report any failures
destroy_snapshot(){
	snapshot="$1"
	snapshot_age="$2"

	## Prune the snapshot
	destroy_error=$(zfs destroy "${snapshot}" 2>&1)
	if [[ $? -eq 0 ]]; then
		echo "Destroyed ${snapshot_age} days old snapshot: ${snapshot}"
	else
        echo "Error: failed destroying snapshot '${snapshot}' of age '${snapshot_age}' with error: ${destroy_error}"
		
		## Send email if script is run by systemd
		if ${systemd}; then
			echo -e "Subject: Error taking snapshot by systemd\n\nError:\n${snapshot_error}" | msmtp "${EMAIL_ADDRESS}"
		fi
		return 1
	fi
}

prune_snapshots(){
	## Get dataset to prune
	dataset="$1"

	## Get current date in seconds since epoch
	current_date=$(date +%s)

	## Loop through all snapshots
	i=0
	while read -r snapshot creation; do
		## Get retention policy from snapshot name
		retention_policy="${snapshot##*-}"

		## Calculate the snapshot's age in days
		snapshot_age=$(( (current_date - creation) / 86400 ))

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
	done < <(zfs list -H -p -o name,creation -t snapshot -r ${dataset})

	## Report on result
	echo "Script pruned ${i} snapshots"
}


## Parse arguments
case $# in
    1)
        ## Prune specific dataset
        prune_snapshots "$1"
        ;;
    *)
        echo "Error: wrong number of arguments for 'prune-snapshots'"
        echo "Enter 'zorra --help' for usage"
        exit 1
        ;;
esac