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


select_clone(){
    ## Select dataset
	if [ -n "${allowed_clone_datasets}" ]; then
        prompt_list clone_dataset "${allowed_clone_datasets}" "Please select a clone to recursively undo the rollback of"
    else
		echo "There are no clones available for an undo-rollback"
		exit 1
	fi
}


undo_recursive_rollback() {
    ## Get input
    local clone_dataset="$1"

    ## Check that the dataset(s) are not in use by any processes (only checking parent is sufficient)
    check_mountpoint_in_use "${clone_dataset}"

	## Get the original parent dataset
	local original_dataset=$(echo "${clone_dataset}" | sed 's/_clone_[^/]*\(\/\|$\)/\1/')

	## Grep selected clone dataset + all clone child datasets
    local clone_datasets=$(grep "^${clone_dataset}" <<< "${clone_datasets}")

    # Show clones to destroy and datasets to restore for confirmation
    local all_original_datasets=$(zfs list -H -o name -s name | awk -F'/' '!/_clone_/ && NF > 1')
    local original_datasets=$(grep "^${original_dataset}" <<< "${all_original_datasets}")
    local original_datasets_rename=$(echo "${original_datasets}" | sed 's/_[0-9]*T[0-9]*//')

	## Show datasets to destroy and restore
	cat <<-EOF
	
		The following datasets will be restored:
		$(change_from_to "${original_datasets}" "${original_datasets_rename}")
		
		The following clones will be destroyed:
		${clone_datasets}
						
	EOF

    ## Get all datasets with a mountpoint that is a subdir of the mountpoint of the clone dataset
    local clone_dataset_mountpoint=$(zfs get mountpoint -H -o value "${clone_dataset}")
    local all_datasets_with_mountpoint=$(zfs list -H -o name,mountpoint,mounted -s name)
    local datasets_with_subdir_in_mountpoint=$(grep "${clone_dataset_mountpoint}" <<< "${all_datasets_with_mountpoint}" | grep yes$ | awk '{print $1}')

    ## Get datasets that are a mount_child but not a dataset_child
    local datasets_mount_child_but_not_dataset_child=$(comm -23 <(echo "${datasets_with_subdir_in_mountpoint}" | sort) <(echo "${clone_datasets}" | sort) | sort -r)

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
        check_mountpoint_in_use "${clone_dataset}"

        ## Unmount datasets that are a mount_child but not a dataset_child
        if [ -n "${datasets_mount_child_but_not_dataset_child}" ]; then
            unmount_datasets "${datasets_mount_child_but_not_dataset_child}"
        fi

        ## Unmount clone datasets
        unmount_datasets "${clone_datasets}"

        ## Rename original parent dataset back to original name
		local original_dataset_rename=$(echo "${original_dataset}" | sed 's/_[0-9]*T[0-9]*//')
        echo "Renaming ${original_dataset} to ${original_dataset_rename}"
        zfs rename "${original_dataset}" "${original_dataset_rename}"

		## Set canmount=on and mountpoint to inherit if mountpoint = dataset
	    set_mount_properties(){
            local dataset
            for dataset in ${original_datasets_rename}; do
				## Set canmount=on for all datasets
				echo "Setting canmount=on for ${dataset}"
				zfs set -u canmount=on "${dataset}"

				## Set mountpoint to 'inherit' if mountpoint = dataset
                local mountpoint=$(zfs get -H -o value mountpoint "${dataset}")
				if [[ "${mountpoint}" == "/${dataset}" ]]; then
                	echo "Setting mountpoint to 'inherit' for ${dataset} since mountpoint=dataset"
					zfs inherit mountpoint "${dataset}"
				fi
            done
        }
        set_mount_properties

        ## Recursively destroy clone dataset
        echo "Recursively destroying ${clone_dataset}"
        zfs destroy -r "${clone_dataset}"

        ## Mount all datasets
        echo "Mounting all datasets"
        zfs mount -a

        ## Result
		echo
        echo "Undo rollback completed:"
        overview_mountpoints "${clone_dataset_mountpoint}"
        exit 0

    else
        echo "Operation cancelled"
        exit 0
    fi

}

## Get clones and allowed clones datasets
clone_datasets=$(zfs list -H -t snapshot -o clones | tr ',' '\n' | grep -v "^-" | grep "_clone_") || true
allowed_clone_datasets=$(echo "${clone_datasets}" | grep -E '_clone_[^/]*$') || true

## Parse arguments
case $# in
    0)
		select_clone
		undo_recursive_rollback "${clone_dataset}"
        ;;
    1)
		if grep -Fxq "$1" <<< "${allowed_clone_datasets}"; then
			undo_recursive_rollback "$1"
		else
			echo "Error: cannot rollback to '$1' as it does not exist or is the root dataset"
			exit 1
		fi
        ;;
    *)
        echo "Error: wrong number of arguments for 'zorra zfs safe-rollback'"
        echo "Enter 'zorra --help' for command syntax"
        exit 1
        ;;
esac