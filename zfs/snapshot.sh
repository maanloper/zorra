#!/bin/bash

## Get the absolute path to the current script directory
script_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"

## Source start-stop-containers.sh
source "$script_dir/../lib/start-stop-containers.sh"

## Source prune-snapshots.sh
source "$script_dir/../lib/prune-snapshots.sh"

## Set flag if script is run by systemd
systemd=false
if [[ $(ps -o comm= -p $(ps -o ppid= -p $$)) == "systemd" ]]; then
    systemd=true
fi

snapshot(){
    ## Set pools to snapshot
    local datasets="$1"

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

    for dataset in ${datasets}; do
        ## Set snapshot name
        snapshot_name="${dataset}@$(date +"%Y%m%dT%H%M%S")-${retention_policy}"

        ## Create recursive snapshot of root dataset
        snapshot_error=$(zfs snapshot -r -o :retention_policy="${retention_policy}" "${snapshot_name}" 2>&1)
        if [[ $? -eq 0 ]]; then
            echo "Successfully created recursive snapshot '${snapshot_name#*@}' for '${snapshot_name%@*}'"
            prune_snapshot "${dataset}"
        else
            echo "Error: failed taking snapshot of ${dataset} with error: ${snapshot_error}"
            echo "Make sure the current user has permission to set the 'userprop' property"

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
    fi
}


## Parse arguments
case $# in
    0)
		## Loop over all pools
        snapshot "$(zpool list -H -o name)"
        ;;
    1)
        ## Snapshot specific pool/dataset
        snapshot "$1"
        ;;
    *)
        echo "Error: wrong number of arguments for 'zorra zfs snapshot'"
        echo "Enter 'zorra --help' for usage"
        exit 1
        ;;
esac















