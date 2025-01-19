#!/bin/bash

## Get the absolute path to the current script directory
script_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"

## Source start-stop-containers.sh
source "$script_dir/../lib/start-stop-containers.sh"

## Set flag if script is run by systemd
#if ; then systemd=true; else systemd=false; fi

snapshot(){
    ## Set pools to snapshot
    local datasets="$1"

    ## Stop any containers if script is run by systemd
    if [ -n "$INVOCATION_ID" ]; then
        stop_containers
    fi

    ## Set retention policy, defaults to daily
    retention_policy="daily"
    if [[ $(date +%d) -eq 19 && -n "$INVOCATION_ID" ]]; then
        ## Set retention policy to monthly if first day of the month and script is executed by systemd
        retention_policy="monthly" 
    fi

    for dataset in ${datasets}; do
        ## Set snapshot name
        snapshot_name="${dataset}@$(date +"%Y%m%dT%H%M%S")-${retention_policy}"

        ## Create recursive snapshot of root dataset
        if zfs snapshot -r "${snapshot_name}"; then
            echo "Successfully created recursive snapshot '${snapshot_name#*@}' for '${snapshot_name%@*}'"
            
            ## Prune snapshots if script is run by systemd
            if [ -n "$INVOCATION_ID" ]; then
                "$script_dir/../lib/prune-snapshots.sh" "${dataset}"
            fi
        else
            echo "Error: failed taking snapshot of ${dataset}"

            ## Send warning email if script is run by systemd
            if [ -n "$INVOCATION_ID" ]; then
                echo -e "Subject: Error taking snapshot by systemd\n\nSystemd could not take a snapshot of:\n${dataset}" | msmtp "${EMAIL_ADDRESS}"
            fi
        fi
    done

    ## Start any containers if script is run by systemd
    if [ -n "$INVOCATION_ID" ]; then
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















