#!/bin/bash
set -e

## Check for root priviliges
if [ "$(id -u)" -ne 0 ]; then
   echo "This command can only be run as root. Run with sudo or elevate to root."
   exit 1
fi

set_timeout(){
	# Set timeout, revert to default if not provided
	local timeout="$1"

	# Ensure the zbm-rEFInd config file exists before modifying
	local zbm_refind_config="/boot/efi/EFI/zbm/refind_linux.conf"
	if [[ ! -f "${zbm_refind_config}" ]]; then
		echo "Error: rEFInd configuration file not found at '${zbm_refind_config}'"
		exit 1
    fi

	## Update ZFSBootMenu timer if required
	sed -i "s|zbm.timeout=-\?[0-9]*|zbm.timeout=${timeout}|" "${zbm_refind_config}"
	echo "Successfully set zbm.timeout=${timeout}"
}


## Parse arguments
case $# in
    0)
		# Default timeout
        set_timeout -1
        ;;
    1)
        if [[ "$1" =~ ^[-]?[0-9]+$ ]]; then
            set_timeout "$1"
        else
            echo "Error: unrecognized argument '$1' for 'zorra refind set theme'"
            echo "Enter 'zorra --help' for command syntax"
            exit 1
        fi
        ;;
    *)
        echo "Error: wrong number of arguments for 'zorra refind set theme'"
        echo "Enter 'zorra --help' for command syntax"
        exit 1
        ;;
esac