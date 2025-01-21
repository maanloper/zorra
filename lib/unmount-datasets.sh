#!/bin/bash
set -e

unmount_datasets() {
    local dataset
    for dataset in $1; do
        if [[ "$(zfs get -H mounted -o value "${dataset}")" == yes ]]; then
            echo "Unmounting ${dataset}"
            if ! zfs unmount -f "${dataset}"; then
                echo "Cannot unmount ${dataset}"
                echo "Check which datasets have been unmounted to prevent partial unmounting:"
                zorra zfs list
                exit 1
            fi
        fi
    done
}
