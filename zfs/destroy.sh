#!/bin/bash
set -e

## Check for root priviliges
if [ "$(id -u)" -ne 0 ]; then
   echo "This command can only be run as root. Run with sudo or elevate to root."
   exit 1
fi

## Get the absolute path to the current script directory
script_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"

## Source prompt_list
source "$script_dir/../lib/prompt-list.sh"

## Source unmount_datasets
source "$script_dir/../lib/unmount-datasets.sh"

## Source overview_mountpoints
source "$script_dir/../lib/overview-mountpoints.sh"

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

    ## Load datasets to destroy
	local datasets=$(grep "^${dataset}" <<< "${allowed_datasets}")

    ## Show datasets that will be destroyed
	cat <<-EOF
		
		The following datasets will be destroyed:
		$(echo -e "\e[01;31m${datasets}\e[0m")
		
	EOF

    ## Check if any of the datasets are mounted
    local unmount_required=false
    for dataset in ${datasets}; do
        if zfs get -H -o value mounted droppi | grep "yes"; then
            unmount_required=true
        fi
    done

    if ${unmount_required}; then
        ## Get all datasets with a mountpoint that is a subdir of the mountpoint of the clone dataset
        local dataset_mountpoint=$(zfs get mountpoint -H -o value "${dataset}")
        local all_datasets_with_mountpoint=$(zfs list -H -o name,mountpoint,mounted -s name)
        local datasets_with_subdir_in_mountpoint=$(grep "${dataset_mountpoint}" <<< "${all_datasets_with_mountpoint}" | grep yes$ | awk '{print $1}')

        ## Get datasets that are a mount_child but not a dataset_child
        local datasets_mount_child_but_not_dataset_child=$(comm -23 <(echo "${datasets_with_subdir_in_mountpoint}" | sort) <(echo "${datasets}" | sort) | sort -r)

        ## Show datasets that need to be temporarily unmounted
        if [ -n "${datasets_mount_child_but_not_dataset_child}" ]; then
			cat <<-EOF
                The following datasets will be temporarily unmounted to allow destoying:
                ${datasets_mount_child_but_not_dataset_child}
                
			EOF
        fi
    fi

    ## First confirmmation
	echo "Destroying a dataset is irreversible!"
    read -p "Proceed? (y/n): " confirmation
	if [[ "$confirmation" != "y" ]]; then
		echo "Operation cancelled"
		exit 0
	fi

	## Second confirmation
	echo
    read -p "Type destroy to proceed (destroy/n): " confirmation

    if [[ "$confirmation" == "destroy" ]]; then
        ## Unmount datasets that are a mount_child but not a dataset_child
        if [ -n "${datasets_mount_child_but_not_dataset_child}" ]; then
            unmount_datasets "${datasets_mount_child_but_not_dataset_child}"
        fi

        ## Recursively destroy parent dataset
        echo "Recursively destroying ${dataset}"
        zfs destroy -r "${dataset}"

        ## Mount all datasets
        if [ -n "${datasets_mount_child_but_not_dataset_child}" ]; then
            echo "Mounting temporarily unmounted datasets"
            zfs mount -a
        fi

        ## Result
		echo
        echo "Destroy completed:"
		zorra zfs list
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
			echo "Error: cannot destroy '$1' as it does not exist or is the root dataset"
			exit 1
		fi
        ;;
    *)
        echo "Error: wrong number of arguments for 'zorra zfs recursive-destroy'"
        echo "Enter 'zorra --help' for command syntax"
        exit 1
        ;;
esac