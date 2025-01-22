#!/bin/bash
set -e

## Set lockfile to prevent multiple instances trying to create a snapshot simultaniously
LOCKFILE="/run/lock/zorra_zfs_snapshot.lock"
LOCKFD=200
exec {LOCKFD}>"$LOCKFILE"

## Try to acquire an exclusive non-blocking lock
while ! flock -n $LOCKFD; do
    echo "Failed to acquire lock, sleeping for 1 seconds..."
    sleep 1
done

## TODO TEMP
sleep 10 # just to stall it temporarily

## Get the absolute path to the current script directory
script_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"

## Source start-stop-containers.sh
source "$script_dir/../lib/start-stop-containers.sh"

######### TODO: change to one variable that checks if run by systemd and no tag, sets variable to true, that is used everywhere else -> easier to read.

snapshot(){
    ## Get datasets to snapshot and suffix
    local datasets="$1"
    local suffix="$2"

    ## Stop any containers if script is run by systemd
    if [ -n "${INVOCATION_ID}" ]; then
        stop_containers
    fi

    ## Only set automatic retention policy when run by systemd and no tag is specified
    local retention_policy
    if [ -z "${suffix}" ] && [ -n "${INVOCATION_ID}" ]; then
        retention_policy="daily" # default policy
        if [[ $(date +%d) -eq 1 ]]; then
            ## Set retention policy to monthly if first day of the month and script is executed by systemd
            retention_policy="monthly" 
        fi
    fi

    ## Loop over all datasets
    local dataset
    for dataset in ${datasets}; do
        ## Set snapshot name
        snapshot_name="${dataset}@$(date +"%Y%m%dT%H%M%S")${suffix:+-$suffix}${retention_policy:+-$retention_policy}"

        ## Create recursive snapshot of dataset
        if zfs snapshot -r "${snapshot_name}"; then
            echo "Successfully created recursive snapshot: ${snapshot_name}"
            
            ## Only on success: prune snapshots if script is run by systemd
            if [ -n "${INVOCATION_ID}" ]; then
                "$script_dir/../lib/prune-snapshots.sh" "${dataset}"
            fi
        else
            echo "Error: failed taking snapshot of dataset: ${dataset}"

            ## Send warning email if script is run by systemd
            if [ -n "${INVOCATION_ID}" ]; then
                echo -e "Subject: Error taking snapshot by systemd\n\nSystemd could not take a recursive snapshot of dataset:\n${dataset}" | msmtp "${EMAIL_ADDRESS}"
            fi
        fi
    done

    ## Start any containers if script is run by systemd
    if [ -n "${INVOCATION_ID}" ]; then
        ## Start any containers
        start_containers
    fi
}

## Get all existing datasets
existing_datasets=$(zfs list -H -o name)

## Loop through arguments
suffix=""
datasets=""
while [[ $# -gt 0 ]]; do
	case "$1" in
		-t|--tag)
            if [[ -n "$2" ]]; then
			    suffix="$2"
                shift 1
            else
                echo "Error: missing tag for 'zorra zfs snapshot --tag <tag>'"
                echo "Enter 'zorra --help' for command syntax"
                exit 1
            fi
        ;;
		*)
            if grep -Fxq "$1" <<< "${existing_datasets}"; then
                #datasets+=("$1")
                datasets+="
                $1"
            else
                echo "Error: cannot snapshot dataset '$1' as it does not exist"
                exit 1
            fi
		;;
	esac
	shift 1
done

## Set datasets to root dataset of all pools when no datasets are specified
if [[ -z "${datasets}" ]]; then
    datasets="$(zpool list -H -o name)"
fi

## Call function to create snapshot of datasets
snapshot "${datasets}" "${suffix}"