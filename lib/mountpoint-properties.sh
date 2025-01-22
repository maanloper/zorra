#!/bin/bash
set -e

overview_mountpoints(){
    ## Get input
    dataset_mountpoint="$1"

    ## Get list of datasets
    local list="$(zfs list -o name,canmount,mounted,mountpoint)"

    ## Display header if grep dataset_mounpoint removes header
    if [[ -n "${dataset_mountpoint}" ]]; then
        echo "${list}" | head -n 1
    fi

    ## Display coloured result
    echo "${list}" | grep "${dataset}" \
    | GREP_COLORS='ms=01;32' grep --color=always -E "( [a-z]*.* yes .*${dataset_mountpoint}|$)" \
    | GREP_COLORS='ms=01;30' grep --color=always -E "( [a-z]*.* no .*${dataset_mountpoint}|$)"
    echo
}

check_mountpoint_in_use(){
    local mountpoint=$(zfs get mountpoint -H -o value "$1")
    if lsof | grep -q "${mountpoint}"; then
        echo "Mountpoint '${mountpoint}' is in use by:"
        lsof | grep --color=always "${mountpoint}"
        echo "Make sure no processes (e.g. containers) are using the mountpoint before proceeding"
        exit 1
    fi
}