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

## Source show_from_to
source "$script_dir/../lib/show-from-to.sh"

## Source unmount_datasets
source "$script_dir/../lib/unmount-datasets.sh"

## Source overview_mountpoints
source "$script_dir/../lib/overview-mountpoints.sh"

select_clone(){
    ## Select dataset
	if [ -n "${allowed_clone_datasets}" ]; then
        echo
        prompt_list clone_dataset "${allowed_clone_datasets}" "Please select a clone to recursively undo the rollback of"
        echo
    else
		echo "There are no clones available for an undo-rollback"
		exit 1
	fi
}

undo_recursive_rollback() {
    ## Get input
    local clone_dataset="$1"

	## Get the original timestamped datasets and original no-timestamped datasets
	local original_dataset_timestamped=$(echo "${clone_dataset}" | sed 's/_clone_[^/]*\(\/\|$\)/\1/')
    local all_original_datasets=$(zfs list -H -o name | awk -F'/' '!/_clone_/ && NF > 1')
    local original_datasets_timestamped=$(grep "^${original_dataset_timestamped}" <<< "${all_original_datasets}")
    local original_datasets=$(echo "${original_datasets_timestamped}" | sed 's/_[0-9]*T[0-9]*//')

	## Show datasets to restore
	cat <<-EOF
	
		The following datasets will be restored:
		$(show_from_to "${original_datasets_timestamped}" "${original_datasets}")
						
	EOF

    ## Grep selected clone dataset + all clone child datasets
    local clone_datasets=$(grep "^${clone_dataset}" <<< "${clone_datasets}")

    ## Get all datasets with a mountpoint that is a subdir of the mountpoint of the clone dataset
    local clone_dataset_mountpoint=$(zfs get mountpoint -H -o value "${clone_dataset}")
    local all_datasets_with_mountpoint=$(zfs list -H -o name,mountpoint,mounted)
    local datasets_with_subdir_in_mountpoint=$(grep "${clone_dataset_mountpoint}" <<< "${all_datasets_with_mountpoint}" | grep yes$ | awk '{print $1}')

    ## Get datasets that are a mount_child but not a dataset_child
    local datasets_mount_child_but_not_dataset_child=$(comm -23 <(echo "${datasets_with_subdir_in_mountpoint}" | sort) <(echo "${clone_datasets}" | sort) | sort -r)

	## Show datasets that need to be temporarily unmounted
    if [ -n "${datasets_mount_child_but_not_dataset_child}" ]; then
		cat <<-EOF
			The following datasets will be temporarily unmounted to allow renaming:
			${datasets_mount_child_but_not_dataset_child}
			
		EOF
    fi

    ## Confirm to proceed
    read -p "Proceed? (y/n): " confirmation

    if [[ "$confirmation" == "y" ]]; then
        ## Unmount datasets that are a mount_child but not a dataset_child
        if [ -n "${datasets_mount_child_but_not_dataset_child}" ]; then
            unmount_datasets "${datasets_mount_child_but_not_dataset_child}"
        fi

        ## Unmount clone datasets (parent is sufficient)
        unmount_datasets "${clone_dataset}"

        ## Rename original parent dataset back to original name
		local original_dataset=$(echo "${original_dataset_timestamped}" | sed 's/_[0-9]*T[0-9]*//')
        echo "Renaming ${original_dataset_timestamped} to ${original_dataset}"
        zfs rename "${original_dataset_timestamped}" "${original_dataset}"

		## Set canmount=on and mountpoint to inherit if mountpoint = dataset
	    set_mount_properties(){
            local dataset
            for dataset in ${original_datasets}; do
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

        ## Set canmount=off for clones
        set_mount_properties_clone(){
            local dataset
            for dataset in ${clone_datasets}; do
                echo "Setting canmount=off for ${dataset}"
                zfs set -u canmount=off "${dataset}"
            done
        }
        set_mount_properties_clone

        ## Mount all datasets
        echo "Mounting all datasets"
        zfs mount -a

        ## Reload zfs-mount-generator units
        systemctl daemon-reload

        ## Result
		echo
        echo "Undo rollback completed:"
        overview_mountpoints "${clone_dataset}" "${original_dataset}"
        exit 0

    else
        echo "Operation cancelled"
        exit 0
    fi

}

## Get clones and allowed clones datasets
clone_datasets=$(zfs list -H -t snapshot -o clones | tr ',' '\n' | grep -vx "-" | grep "_clone_") || true
allowed_clone_datasets=$(echo "${clone_datasets}" | grep -E '_clone_[^/]*$') || true
for dataset in ${allowed_clone_datasets}; do
    mounted=$(zfs get -H mounted -o value "${dataset}")
    if [[ "${mounted}" = no ]]; then
        allowed_clone_datasets=$(echo "${allowed_clone_datasets}" | grep -v "${dataset}")
    fi
done
echo "$allowed_clone_datasets"

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