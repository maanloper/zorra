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

select_dataset() {
    ## Select dataset
	if [ -n "${allowed_datasets}" ]; then
        echo
        prompt_list dataset "${allowed_datasets}" "Please select a dataset to recursively destroy"
    else
		echo "There are no datasets available to destroy"
		exit 1
	fi
}


recursive_destroy_dataset() {
	## Get input 
	dataset="$1"

    ## Check that the dataset(s) are not in use by any processes (only checking parent is sufficient)
    check_mountpoint_in_use "${dataset}"

    # Load datasets to destroy
	local datasets=$(grep "^${dataset}" <<< "${allowed_datasets}")

    # Show datasets that will be destroyed
	cat <<-EOF
		
		The following datasets will be destroyed:
		${datasets}
			
	EOF

    ## Get all datasets with a mountpoint that is a subdir of the mountpoint of the clone dataset
    local dataset_mountpoint=$(zfs get mountpoint -H -o value "${dataset}")
    local all_datasets_with_mountpoint=$(zfs list -H -o name,mountpoint,mounted -s name)
    local datasets_with_subdir_in_mountpoint=$(grep "${dataset_mountpoint}" <<< "${all_datasets_with_mountpoint}" | grep yes$ | awk '{print $1}')

    ## Get datasets that are a mount_child but not a dataset_child
    local datasets_mount_child_but_not_dataset_child=$(comm -23 <(echo "${datasets_with_subdir_in_mountpoint}" | sort) <(echo "${datasets}" | sort) | sort -r)

	## Show datasets that need to be temporarily unmounted
    if [ -n "${datasets_mount_child_but_not_dataset_child}" ]; then
		cat <<-EOF
			The following datasets will be temporarily unmounted to allow renaming:
			${datasets_mount_child_but_not_dataset_child}
			
		EOF
    fi

    ## First confirmmation
	echo "Destroying a dataset is irreversible, check what gets destroyed!"
    read -p "Proceed? (y/n): " confirmation
	if [[ "$confirmation" != "y" ]]; then
		echo "Operation cancelled"
		exit 0
	fi

	## Second confirmation
	echo
    read -p "Type destroy to proceed (destroy/n): " confirmation

    if [[ "$confirmation" == "destroy" ]]; then
        ## Re-check that the dataset(s) are not in use by any processes (only checking parent is sufficient)
        check_mountpoint_in_use "${dataset}"

        ## Check mount childs not in use
		for mount_child in ${datasets_mount_child_but_not_dataset_child}; do
        	check_mountpoint_in_use "${mount_child}"
		done

        # Recursively destroy parent dataset
        echo "Recursively destroying ${dataset}"
        zfs destroy -r "${dataset}"

        # Result
		echo
        echo "Destroy completed:"
		overview_mountpoints "${datasets}" "${original_dataset}"
        overview_mountpoints
        exit 0
    else
        echo "Operation cancelled"
        exit 0
    fi
}

## Get allowed datasets TODO: next to removing root dataset and mountpoint=none, remove rows with (mounted=yes AND mountpoint=/) (i.e. active OS)
allowed_datasets=$(zfs list -H -o name,mounted,mountpoint -s name | awk -F'/' 'NF > 2' | grep -v "none" | grep -v "yes.*/$" | awk '{print $1}') || true

## Parse arguments
case $# in
    0)
		select_dataset
		recursive_destroy_dataset "${dataset}"
        ;;
    1)
		if grep -Fxq "$1" <<< "${allowed_datasets}"; then
			recursive_destroy_dataset "$1"
		else
			echo "Error: cannot destroy '$1' as it does not exist or the root dataset"
			exit 1
		fi
        ;;
    *)
        echo "Error: wrong number of arguments for 'zorra zfs recursive-destroy'"
        echo "Enter 'zorra --help' for command syntax"
        exit 1
        ;;
esac