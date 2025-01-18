#!/bin/bash
set -e

set_refind_timeout(){
	# Set timeout, revert to default if not provided
	local refind_timeout="$1"

	# Ensure the rEFInd config file exists before modifying
	local refind_config="/boot/efi/EFI/refind/refind.conf"
	if [[ ! -f "${refind_config}" ]]; then
		echo "Error: rEFInd configuration file not found at '${refind_config}'"
		exit 1
    fi

	## Set timeout before rEFInd boots default bootloader
	sed -i "s|^timeout .*|timeout ${refind_timeout}|" "${refind_config}"
	echo "Successfully set rEFInd bootscreen timeout ${refind_timeout}"
}


## Parse arguments
case $# in
    0)
		# Default timeout
        set_refind_timeout 3
        ;;
    1)
        if [[ "$1" =~ ^[0-9]+$ ]]; then
            set_refind_timeout "$1"
        else
            echo "Error: unrecognized argument '$1' for 'zorra refind set theme'"
            echo "Enter 'zorra --help' for usage"
            exit 1
        fi
        ;;
    *)
        echo "Error: wrong number of arguments for 'zorra refind set theme'"
        echo "Enter 'zorra --help' for usage"
        exit 1
        ;;
esac