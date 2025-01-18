#!/bin/bash

## Get the absolute path to the current script directory
script_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"

## Source start_stop_containers
source "$script_dir/../lib/start_stop_containers.sh"

## Set flag if script is run by systemd
systemd=false
if [[ $(ps -o comm= -p $(ps -o ppid= -p $$)) == "systemd" ]]; then
    systemd=true
fi


snapshot(){
    ## Set pools to snapshot
    local pools="$1"

    ## Stop any containers if script is run by systemd
    if ${systemd}; then
        stop_containers
    fi

    ## Set retention policy, defaults to daily
    retention_policy="daily"
    if [[ $(date +%d) -eq 1 && ${systemd} -eq 1 ]]; then
        ## Set retention policy to monthly if first day of the month and script is executed by systemd
        retention_policy="monthly" 
    fi

    for pool in ${pools}; do
        ## Set snapshot name
        snapshot_name="${pool}@$(date +"%Y%m%dT%H%M%S")-${retention_policy}"

        ## Create recursive snapshot of root dataset
        snapshot_error=$(zfs snapshot -r -o :retention_policy="${retention_policy}" "${snapshot_name}" 2>&1)
        if [[ $? -eq 0 ]]; then
            echo "Successfully created snapshot: ${snapshot_name}"
        else
            echo "Error: failed taking snapshot of ${pool} with error: ${snapshot_error}"

            ## Send email if snapshot was taken by systemd
            if ${systemd}; then
                echo -e "Subject: Error taking snapshot by systemd\n\nError:\n${snapshot_error}" | msmtp "${EMAIL_ADDRESS}"
            fi
        fi
    done


    ## Start any containers if script is run by systemd
    if ${systemd}; then
        ## Start any containers
        start_containers

        ## Prune snapshots
        /usr/local/bin/prune_snapshots.sh
    fi
}









## Parse arguments
case $# in
    0)
		## Loop over all pools
        snapshot "$(zpool list -H -o name)"
        ;;
    1)
        ## Snapshot specific pool
        snapshot "$1"
        ;;
    *)
        echo "Error: wrong number of arguments for 'zorra zfssnapshot'"
        echo "Enter 'zorra --help' for usage"
        exit 1
        ;;
esac















