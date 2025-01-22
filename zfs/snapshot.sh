#!/bin/bash
set -e

## Get the absolute path to the current script directory
script_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"

## Source start-stop-containers.sh
source "$script_dir/../lib/start-stop-containers.sh"

######### TODO: change to one variable that checks if run by systemd and no tag, sets variable to true, that is used everywhere else -> easier to read.
######### TODO: check no snapshot of the same time already exists, otherwise wait

snapshot(){
    ## Get datasets to snapshot and suffix
    local datasets="$1"
    local suffix="$2"

    ## Do not create snapshots when called by unattened upgrades, as it can spam snapshot creation
    ## Spamming leads to errors due to same timestamp
    if pstree -s $$ | grep -q "unattended-up"; then
        if [[ -f /var/run/zorra_zfs_last_apt_snapshot ]]; then
            last_apt_snapshot=$(cat /var/run/zorra_zfs_snapshot_spam_protect)
        fi

        timestamp=$(date +"%s")
        if (( timestamp < ( last_apt_snapshot + 60 ) )); then
            echo "Prevented unattended-upgrades apt-spamming: already created snapshot in the last 60 seconds"
            exit 0
        fi
        
        echo "${timestamp}" > /var/run/zorra_zfs_snapshot_spam_protect

        echo "Note: script is executed by unattended-upgrades, no spamming detected (yet)"
        #echo "Note: script is executed by unattended-upgrades, exiting to prevent spamming snapshots"
        
    fi

    ## If tag is 'systemd' set systemd var to true and determine retention policy suffix
    systemd=false
    if [[ "${suffix}" == systemd ]]; then
        systemd=true
        
        ## Set retention policy, defaulting to "daily"
        suffix="daily"
        if [[ $(date +%d) -eq 1 ]]; then
            suffix="monthly" # monthly on first day of month
        fi
    fi

    ## Stop any containers if script is run by systemd
    if ${systemd}; then
        stop_containers
    fi

    ## Loop over all datasets
    local dataset
    for dataset in ${datasets}; do
        ## Set snapshot name
        snapshot_name="${dataset}@$(date +"%Y%m%dT%H%M%S")${suffix:+-$suffix}"

        ## Create recursive snapshot of dataset
        if zfs snapshot -r "${snapshot_name}"; then
            echo "Successfully created recursive snapshot: ${snapshot_name}"
            
            ## Only on success: prune snapshots if script is run by systemd
            if ${systemd}; then
                "$script_dir/../lib/prune-snapshots.sh" "${dataset}" 
            fi
        else
            echo "Error: failed taking snapshot of dataset: ${dataset}"

            ## Send warning email if script is run by systemd
            if ${systemd}; then
                echo -e "Subject: Error taking snapshot by systemd\n\nSystemd could not take a recursive snapshot of dataset:\n${dataset}" | msmtp "${EMAIL_ADDRESS}"
            fi
        fi
    done

    ## Start any containers if script is run by systemd
    if ${systemd}; then
        ## Start any containers
        start_containers
    fi
}

## Get all existing datasets
existing_datasets=$(zfs list -H -o name)

## Loop through arguments
datasets=""
suffix=""
while [[ $# -gt 0 ]]; do
	case "$1" in
		--tag|-t)
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