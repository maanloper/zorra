#!/bin/bash
set -e

prune_empty_datasets(){
	## Find datasets that probably do not have snapshots
	for dataset in $(zfs list -H -o name,usedsnap -S name | tail -n +2 | grep 0B$ | awk '{print $1}'); do
		## Check if dataset exists and does not have snapshots (inluding no snapshots for any children)
		if zfs list -H "${dataset}" &>/dev/null && ! zfs list -H -t snapshot -r "${dataset}" | grep -q "${dataset}"; then
			echo "Dataset '${dataset}' has no snapshots"
			read -p "Do you want to destroy the dataset? (destroy/n) " confirmation
			 if [[ "$confirmation" == "destroy" ]]; then
				## Destroy empty dataset
				if zfs destroy -r "${dataset}"; then
					echo "Destroyed empty dataset: ${dataset}"
				else
					echo "Error: failed destroying dataset '${dataset}'"
				fi
			else
				echo "Skipped destroying ${dataset}'"
			fi
		fi
	done
}

prune_empty_datasets