#!/bin/bash
set -e

overview_mountpoints() {
    local list="$(zfs list -o name,canmount,mounted,mountpoint)"
    if [[ -n "$1" ]]; then
        echo "${list}" | head -n 1
    fi
    echo "${list}" | grep --color=always -E "(${1}|clone)"
    echo
}

check_mountpoint_in_use() {
    local mountpoint=$(zfs get mountpoint -H -o value "$1")
    if lsof | grep -q "${mountpoint}"; then
        echo "Mountpoint '${mountpoint}' is in use by:"
        lsof | grep --color=always "${mountpoint}"
        echo "Make sure no processes are using the mountpoint before proceeding"
        exit 1
    fi
}