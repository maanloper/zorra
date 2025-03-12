#!/bin/bash
set -e

prune_empty_datasets(){
	## Find datasets that probably do not have snapshots
	for dataset in $(zfs list -H -o name,usedsnap -S name | tail -n +2 | grep 0B$ | awk '{print $1}'); do
		## Check if dataset exists and does not have snapshots (inluding no snapshots for any children)
		if zfs list -H "${dataset}" &>/dev/null && ! zfs list -H -t snapshot -r "${dataset}" | grep -q "${dataset}" && [[ -z "$(ls -A $(zfs get mountpoint -H -o value ${dataset}) 2>/dev/null)" ]]; then
			echo "Dataset '${dataset}' has no snapshots and no files at the mountpoint (warning: also possible if dataset is not mounted)"
			read -p "Do you want to destroy the dataset? (y/n) " confirmation
			 if [[ "$confirmation" == "y" ]]; then
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