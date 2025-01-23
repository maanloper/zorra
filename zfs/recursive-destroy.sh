#!/bin/bash
set -e

## Check for root priviliges
if [ "$(id -u)" -ne 0 ]; then
   echo "This command can only be run as root. Run with sudo or elevate to root."
   exit 1
fi

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

    # Load datasets to destroy
	local datasets=$(grep "^${dataset}" <<< "${allowed_datasets}")

    # Show datasets that will be destroyed
    echo "The following datasets will be destroyed:"
    echo "${datasets}"

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
        # Check if datasets are mounted, and if so, if it is in use.

        # Recursively destroy parent dataset
        echo "Recursively destroying ${dataset}"
        zfs destroy -r "${dataset}"

        # Result
		echo
        echo "Destroy completed:"
		overview_mountpoints "${original_dataset_timestamped}" "${original_dataset}"
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