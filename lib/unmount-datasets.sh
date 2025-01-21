#!/bin/bash
set -e

unmount_datasets() {
    local dataset
    for dataset in $1; do
        echo "Unmounting ${dataset}"
        if ! unmount_error=$(zfs unmount -f "${dataset}" 2>&1) && [[ ! "${unmount_error}" =~ "not currently mounted" ]]; then
            echo "Cannot unmount ${dataset}"
            echo "Error: ${unmount_error}"
            echo -e "Check which datasets have been unmounted to prevent partial unmounting:"
            overview_mountpoints
            exit 1
        fi
    done
}
