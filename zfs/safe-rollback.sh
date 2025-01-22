#!/bin/bash
set -e

## Check for root priviliges
if [ "$(id -u)" -ne 0 ]; then
   echo "This command can only be run as root. Run with sudo or elevate to root."
   exit 1
fi

## Get the absolute path to the current script directory
script_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"

# Source prompt_list
source "$script_dir/../lib/prompt-list.sh"

# Source change_from_to
source "$script_dir/../lib/change-from-to.sh"

# Source unmount_datasets
source "$script_dir/../lib/unmount-datasets.sh"

# Source overview_mountpoints and check_mountpoint_in_use
source "$script_dir/../lib/mountpoint-properties.sh"

# Source start_containers and stop_containers
source "$script_dir/../lib/start-stop-containers.sh"


select_snapshot() {
    ## Select dataset
	if [ -n "${allowed_datasets}" ]; then
        prompt_list dataset "${allowed_datasets}" "Please select a dataset to recursively clone"
    else
		echo "There are no datasets available to clone (root dataset and clones cannot be cloned)"
		exit 1
	fi
    
    echo

    ## Select snapshot
    local snapshot_options=$(grep "^${dataset}@" <<< "${allowed_snapshots}")
	if [ -n "${snapshot_options}" ]; then
        prompt_list dataset_snapshot "${snapshot_options}" "Please select a snapshot to clone"
    else
		echo "There are no snapshots available for dataset: ${dataset}"
		exit 1
	fi
}

recursive_rollback_to_clone() {
    ## Get input
    local dataset="${1%@*}"
    local snapshot="${1#*@}"

     ## Check that the dataset(s) are not in use by any processes (only checking parent is sufficient)
    check_mountpoint_in_use "${dataset}"

     ## Grep selected dataset + all child datasets
    local datasets=$(grep "^${dataset}" <<< "${allowed_datasets}")

    ## Check if specified snapshot is available for all datasets, throw error if a required snapshot does not exist
    local expected_snapshots=$(echo "$datasets" | awk -v snap="${snapshot}" '{print $1 "@" snap}')
    local missing_snapshots=$(comm -23 <(echo "${expected_snapshots}" | sort) <(echo "${allowed_snapshots}" | sort) | sort -r)
    if [[ -n "$missing_snapshots" ]]; then
        echo "Cannot execute a recursive rollback since the following snapshots are missing:"
        echo "${missing_snapshots}"
        exit 1
    fi

    ## Create a timestamp
    local timestamp=$(date +"%Y%m%dT%H%M%S")

    ## Determine renamed original and clone dataset names
    local dataset_rename="${dataset}_${timestamp}"
    local clone_dataset="${dataset}_${timestamp}_clone_${snapshot}"
    local datasets_rename="$(echo "$datasets" | sed "s|^$dataset|$dataset_rename|")"
    local datasets_clone_name="$(echo "$datasets" | sed "s|^$dataset|$clone_dataset|")"

    ## Get all datasets with a mountpoint that is a subdir of the mountpoint of the dataset
    local dataset_mountpoint=$(zfs get mountpoint -H -o value "${dataset}")
    local all_datasets_with_mountpoint=$(zfs list -H -o name,mountpoint,mounted -s name)
    local datasets_with_subdir_in_mountpoint=$(grep "${dataset_mountpoint}" <<< "${all_datasets_with_mountpoint}" | grep yes$ | awk '{print $1}')

    ## Get datasets that are a mount_child but not a dataset_child
    local datasets_mount_child_but_not_dataset_child=$(comm -23 <(echo "${datasets_with_subdir_in_mountpoint}" | sort) <(echo "${datasets}" | sort) | sort -r)

    ## Show datasets to clone for confirmation
	cat <<-EOF
	
		The following datasets will be renamed and set to 'canmount=off':
		$(change_from_to "${datasets}" "${datasets_rename}")
		
		The following clones will be created from snapshot ${snapshot}:
		$(change_from_to "${datasets}" "${datasets_clone_name}")
		(Mountpoint will be copied from the original dataset)
						
	EOF

    ## Show datasets that need to be temporarily unmounted
    if [ -n "${datasets_mount_child_but_not_dataset_child}" ]; then
		cat <<-EOF
			The following datasets will be temporarily unmounted to allow cloning:
			${datasets_mount_child_but_not_dataset_child}
			
		EOF
    fi
    
    ## Confirm to proceed
    read -p "Proceed? (y/n): " confirmation

    if [[ "$confirmation" == "y" ]]; then
        ## Re-check that the dataset(s) are not in use by any processes (only checking parent is sufficient)
        check_mountpoint_in_use "${dataset}"

        ## Unmount datasets that are a mount_child but not a dataset_child
        if [ -n "${datasets_mount_child_but_not_dataset_child}" ]; then
            unmount_datasets "${datasets_mount_child_but_not_dataset_child}"
        fi

        ## Unmount original datasets
        unmount_datasets "${dataset}"

        ## Set mountpoint for original datasets to disable 'inherit' property and set canmount=off to prevent automounting
        set_mount_properties(){
            local dataset
            for dataset in ${datasets}; do
                local mountpoint=$(zfs get -H -o value mountpoint "${dataset}")
                echo "Setting canmount=off and mountpoint to ${mountpoint} for ${dataset}"
                zfs set -u mountpoint="${mountpoint}" "${dataset}"
                zfs set -u canmount=off "${dataset}"
            done
        }
        set_mount_properties

        ## Define the clone parent dataset name
        local clone_base_dataset="${dataset}_${timestamp}_clone_${snapshot}"

        ## Clone all datasets
        clone_datasets(){
            local dataset_to_clone
            for dataset_to_clone in ${datasets}; do
                local clone_dataset="${clone_base_dataset}${dataset_to_clone#${dataset}}"
                local mountpoint=$(zfs get -H -o value mountpoint "${dataset_to_clone}")
                echo "Cloning ${dataset_to_clone}@${snapshot} to ${clone_dataset}"
                zfs clone -o mountpoint="${mountpoint}" "${dataset_to_clone}@${snapshot}" "${clone_dataset}"
            done
        }
        clone_datasets

        ## Mount all datasets
        echo "Mounting all datasets"
        zfs mount -a

        ## Rename original dataset
        echo "Renaming ${dataset} to ${dataset}_${timestamp}"
        zfs rename "${dataset}" "${dataset}_${timestamp}"

        ## Result
        echo
        echo "Rollback completed:"
        overview_mountpoints "${dataset_mountpoint}"
        exit 0
        
    else
        echo "Operation cancelled"
        exit 0
    fi
}

## Get allowed datasets and snapshots (do not allow cloning of clones or the root datset)
allowed_datasets=$(zfs list -H -o name -s name | awk -F'/' '!/_clone_/ && !/_[0-9]*T[0-9]*$/ && NF > 1') || true
allowed_snapshots=$(zfs list -H -t snapshot -o name -s creation | awk -F'/' '!/_clone_/ && !/_[0-9]*T[0-9]*$/ && NF > 1') || true

## Parse arguments
case $# in
    0)
		select_snapshot
		recursive_rollback_to_clone "${dataset_snapshot}"
        ;;
    1)
		if grep -Fxq "$1" <<< "${allowed_snapshots}"; then
			recursive_rollback_to_clone "$1"
		else
			echo "Error: cannot rollback to '$1' as it does not exist, is not a snapshot or is a snapshot of the root dataset"
			exit 1
		fi
        ;;
    *)
        echo "Error: wrong number of arguments for 'zorra zfs safe-rollback'"
        echo "Enter 'zorra --help' for command syntax"
        exit 1
        ;;
esac