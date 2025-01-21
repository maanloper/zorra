#!/bin/bash
set -e

mount_datasets() {
    for dataset in $1; do
        echo "Mounting ${dataset}"
        if ! mount_error=$(zfs mount "${dataset}" 2>&1) && [[ ! "${mount_error}" =~ "filesystem already mounted" ]]; then
            echo -e "Cannot mount ${dataset}"
            echo -e "Error: ${mount_error}"
            echo -e "Overview of mounted datasets:"
            overview_mountpoints
            exit 1
        fi
    done
}

unmount_datasets() {
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
