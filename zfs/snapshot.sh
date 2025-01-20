#!/bin/bash
set -e

#TODO: add option for 'zorra zfs snapshot [pool] [--tag tag]'

## Get the absolute path to the current script directory
script_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"

## Source start-stop-containers.sh
source "$script_dir/../lib/start-stop-containers.sh"

snapshot(){
    ## Get datasets to snapshot and suffix
    local datasets="$1"
    local suffix="$2"

    ## Stop any containers if script is run by systemd
    if [ -n "${INVOCATION_ID}" ]; then
        stop_containers
    fi

    ## Only set automatic retention policy when run by systemd
    if [ -n "${INVOCATION_ID}" ]; then
        local retention_policy="daily" # default policy
        if [[ $(date +%d) -eq 1 && -n "$INVOCATION_ID" ]]; then
            ## Set retention policy to monthly if first day of the month and script is executed by systemd
            retention_policy="monthly" 
        fi
        suffix="${retention_policy}"
    fi

    ## Loop over all datastes
    for dataset in ${datasets}; do
        ## Set snapshot name
        snapshot_name="${dataset}@$(date +"%Y%m%dT%H%M%S")${suffix:+-$suffix}"

        ## Create recursive snapshot of root dataset
        if zfs snapshot -r "${snapshot_name}"; then
            echo "Successfully created recursive snapshot: ${snapshot_name}"
            
            ## Only on success: prune snapshots if script is run by systemd
            if [ -n "$INVOCATION_ID" ]; then
                "$script_dir/../lib/prune-snapshots.sh" "${dataset}"
            fi
        else
            echo "Error: failed taking snapshot of dataset: ${dataset}"

            ## Send warning email if script is run by systemd
            if [ -n "$INVOCATION_ID" ]; then
                echo -e "Subject: Error taking snapshot by systemd\n\nSystemd could not take a recursive snapshot of dataset:\n${dataset}" | msmtp "${EMAIL_ADDRESS}"
            fi
        fi
    done

    ## Start any containers if script is run by systemd
    if [ -n "$INVOCATION_ID" ]; then
        ## Start any containers
        start_containers
    fi
}


existing_datasets=$(zfs list -H -o name)
datasets=()

## Loop through arguments
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
            if grep -Fx "$1" <<< "${existing_datasets}"; then
                datasets+=("$1")
            else
                echo "Error: cannot snapshot dataset '$1' as it does not exist"
                echo "Enter 'zorra --help' for command syntax"
                exit 1
            fi
		;;
	esac
	shift 1
done

snapshot "${datasets}" "${suffix}"








