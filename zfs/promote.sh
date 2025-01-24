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

# Source overview_mountpoints
source "$script_dir/../lib/overview-mountpoints.sh"

select_clone(){
    ## Select dataset
	if [ -n "${allowed_clone_datasets}" ]; then
		echo
        prompt_list clone_dataset "${allowed_clone_datasets}" "Please select a clone to recursively promote and rename"
		echo
    else
		echo "There are no clones available for a full-promote"
		exit 1
	fi
}


recursive_promote_and_rename_clone() {
    ## Get input
    local clone_dataset="$1"

    # Show clones to destroy and datasets to restore for confirmation
    local clone_datasets=$(grep "^${clone_dataset}" <<< "${clone_datasets}")
    local original_datasets=$(echo "${clone_datasets}" | sed 's/_[0-9]*T[0-9]*[^/]*//')

	## Show datasets to promote
	cat <<-EOF
	
		The following clones will be promoted and renamed:
		$(change_from_to "${clone_datasets}" "${original_datasets}")
						
	EOF

	## Get the original timestamped datasets
	local original_dataset_timestamped=$(echo "${clone_dataset}" | sed 's/_clone_[^/]*\(\/\|$\)/\1/')
    local all_original_datasets=$(zfs list -H -o name -s name | awk -F'/' '!/_clone_/ && NF > 1')
    local original_datasets_timestamped=$(grep "^${original_dataset_timestamped}" <<< "${all_original_datasets}")

	## Show datasets to destroy
	cat <<-EOF
		The following previously original datasets can optionally be destroyed:
		${original_datasets_timestamped}
		
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
			The following datasets will be temporarily unmounted to allow renaming:
			${datasets_mount_child_but_not_dataset_child}
			
		EOF
    fi

    # Confirm to proceed
    read -p "Proceed and optionally destroy previously original dataset? (y/n/destroy): " confirmation

    if [[ "$confirmation" == "y" || "$confirmation" == "destroy" ]]; then
        ## Unmount datasets that are a mount_child but not a dataset_child
        if [ -n "${datasets_mount_child_but_not_dataset_child}" ]; then
            unmount_datasets "${datasets_mount_child_but_not_dataset_child}"
        fi

        # Unmount clone datasets (parent is sufficient)
        unmount_datasets "${clone_dataset}"

        # Recursively promote clone parent dataset
        for dataset in $clone_datasets; do
            echo "Promoting $dataset"
            zfs promote "$dataset"
        done

        # Rename clone parent dataset to original name
		local original_dataset=$(echo "${clone_dataset}" | sed 's/_[0-9]*T[0-9]*[^/]*//')
        echo "Renaming ${clone_dataset} to ${original_dataset}"
        zfs rename "${clone_dataset}" "${original_dataset}"

        ## Recursively destroy clone dataset
        if [[ "$confirmation" == "destroy" ]]; then
            echo "Recursively destroying ${original_dataset_timestamped}"
            zfs destroy -r "${original_dataset_timestamped}"
		else
            set_mount_properties_clone(){
                local dataset
                for dataset in ${original_dataset_timestamped}; do
                    echo "Setting canmount=off for ${dataset}"
                    zfs set -u canmount=off "${dataset}"
                done
            }
            set_mount_properties_clone
        fi

        ## Mount all datasets
        echo "Mounting all datasets"
        zfs mount -a

        ## Reload zfs-mount-generator units
        systemctl daemon-reload

        # Result
		echo
        echo "Promoting safe-rollback clone completed:"
        overview_mountpoints "${original_dataset_timestamped}" "${original_dataset}"
        exit 0
    else
        echo "Operation cancelled"
        exit 0
    fi

}

## Get clones and allowed clones datasets
clone_datasets=$(zfs list -H -t snapshot -o clones | tr ',' '\n' | grep -v "^-" | grep "_clone_") || true
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
		recursive_promote_and_rename_clone "${clone_dataset}"
        ;;
    1)
		if grep -Fxq "$1" <<< "${allowed_clone_datasets}"; then
			recursive_promote_and_rename_clone "$1"
		else
			echo "Error: cannot promote '$1' as it does not exist or is the root dataset"
			exit 1
		fi
        ;;
    *)
        echo "Error: wrong number of arguments for 'zorra zfs full-promote'"
        echo "Enter 'zorra --help' for command syntax"
        exit 1
        ;;
esac