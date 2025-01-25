#!/bin/bash
set -e

## Check for root priviliges
if [ "$(id -u)" -ne 0 ]; then
    echo "This command can only be run as root. Run with sudo or elevate to root."
    exit 1
fi

## Get the absolute path to the current script directory
script_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"

# Source test_msmtp
source "$script_dir/../lib/test-msmtp.sh"

config_zfs_zed(){
    local zed_notify_verbose=0
    if [[ $1 == --test ]]; then
        zed_notify_verbose=1
    fi

    ## Ensure the ZFS-ZED config file exists before modifying
    local zed_config="/etc/zfs/zed.d/zed.rc"
    if [[ ! -f "${zed_config}" ]]; then
        echo "Error: ZFS-ZED configuration file not found at '${zed_config}'"
        exit 1
    fi

    ## Updates values in ZFS-ZED config
    sed -i -E "/^#?ZED_EMAIL_ADDR.*/c\ZED_EMAIL_ADDR=\"${EMAIL_ADDRESS}\"" "${zed_config}"
    sed -i -E "/^#?ZED_EMAIL_PROG.*/c\ZED_EMAIL_PROG=\"msmtp\"" "${zed_config}"
    sed -i -E "/^#?ZED_EMAIL_OPTS.*/c\ZED_EMAIL_OPTS=\"@ADDRESS@\"" "${zed_config}"
    sed -i -E "/^#?ZED_NOTIFY_INTERVAL_SECS.*/c\ZED_NOTIFY_INTERVAL_SECS=86400" "${zed_config}" # Maximum of 1 notification per day to prevent spamming
    sed -i -E "/^#?ZED_NOTIFY_VERBOSE.*/c\ZED_NOTIFY_VERBOSE=${zed_notify_verbose}" "${zed_config}"

    ## Provide information on result and how to test functionality
    echo "Successfully set health monitoring for all pools in '${zed_config}'"
    if [[ ${zed_notify_verbose} -eq 1 ]]; then
        zpool scrub "${ROOT_POOL_NAME}"
        echo "A scrub has been started on ${ROOT_POOL_NAME}, after it finishes you should receive an email"
        echo "If you do not receive an email, make sure msmtp is set up correctly (see 'zorra --help')"
        echo "After testing, run this command again without the '--test' flag to only monitor unhealthy states"
    else
        echo "Make sure to run the command with the '--test' flag to check if everying works as expected!"
    fi
}

## Parse arguments
case $# in
    0)
		# No verbosity set in ZFS-ZED
        config_zfs_zed
        ;;
    1)
        if [[ "$1" == --test ]]; then
            config_zfs_zed --test
        else
            echo "Error: unrecognized argument '$1' for 'zorra zfs monitor-status'"
            echo "Enter 'zorra --help' for command syntax"
            exit 1
        fi
        ;;
    *)
        echo "Error: wrong number of arguments for 'zorra zfs monitor-status'"
        echo "Enter 'zorra --help' for command syntax"
        exit 1
        ;;
esac

