#!/bin/bash
set -e

# TODO: in functions, put in dataset instead of mountpoint?
overview_mountpoints(){
    ## Get input
    #dataset="$1"

    ## Get mountpoint
    #mountpoint=$(zfs get -H mountpoint -o value "${dataset}")

    ## Get list of datasets
    #local list=$(zfs list -o name,canmount,mounted,mountpoint)

    ## Show header if grep dataset_mounpoint removes header
    #if [[ -n "${dataset}" ]]; then
    #    echo "${list}" | head -n 1
    #fi

########################################################################################################################

    ## Get input
    old_dataset="$1"
    new_dataset="$2"

    ## Get mountpoints
    mountpoint=$(zfs get -H mountpoint -o value "${new_dataset}")

    ## Get list of datasets
    list=$(zfs list -o name,canmount,mounted,mountpoint)

    ## Show list header
    echo "${list}" | head -n 1

    ## Show disabled datasets (only nothing or '/' allowed behind name) | errors: canmount=on or mounted=yes
    if [[ -n "${old_dataset}" ]]; then
        echo "${list}" \
        | grep --color=never -E "^${old_dataset}( |/).*" \
        | GREP_COLORS='ms=01;31' grep --color=always -E "(.* (on|yes) .*|$)" \
        | GREP_COLORS='ms=01;30' grep --color=always -E "(.* no .*|$)"
    fi

    ## Show cloned/rolled back/promoted datasets (only nothing or '/' allowed behind name) | errors: canmount=off/noauto or mounted=no
    echo "${list}" \
    | grep --color=never -E "^${new_dataset}( |/).*" \
    | GREP_COLORS='ms=01;31' grep --color=always -E "(.* (off|noauto|no) .*|$)" \
    | GREP_COLORS='ms=01;32' grep --color=always -E "(.* yes .*|$)"

    ## Show temp unmounted datasets (same mountpoint, name neither old nor new dataset) | error: canmount=off/noauto or mounted=no
    echo "${list}" \
    | grep --color=never -E "${mountpoint}" \
    | grep --color=never -vE "^(${old_dataset}|${new_dataset})" \
    | GREP_COLORS='ms=01;31' grep --color=always -E "(.* (off|noauto|no) .*|$)"


########################################################################################################################
    ## Show overview of datasets
    #echo "${list}" \
    #| GREP_COLORS='ms=01;31' grep --color=always -E "(.* on .* no .*|$)" \
    #| GREP_COLORS='ms=01;32' grep --color=always -E "(^${dataset}.* yes .*|$)" \
    #| GREP_COLORS='ms=01;30' grep --color=always -E "(.* no .*|$)" \
    #| grep --color=never "${mountpoint}"
    #echo
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