#!/bin/bash
set -e

## Check for root priviliges
if [ "$(id -u)" -ne 0 ]; then
    echo "This command can only be run as root. Run with sudo or elevate to root."
    exit 1
fi

## Get the absolute path to the current script directory
script_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"

# Source the common functions
source "$SCRIPT_DIR/../lib/common_functions.sh"

test_msmtp(){
    ## Ensure an email can be sent
    local message="Subject: Monitor-status test\n\nNote: this is not a confirmation ZFS-ZED can sent an email, merely that msmtp is configured correctly to sent emails"
    if echo -e "${message}" | msmtp "${ZED_EMAIL_ADDR}"; then
        echo "Succesfully sent a test email using msmtp. Note: this only tests msmtp, not ZFS-ZED!"
    else
        echo "Error: could not send a test email to ${ZED_EMAIL_ADDR} using msmtp"
        echo "Check your settings in the .env file and configure msmtp (see 'zorra --help' for the command)"
        exit 1
    fi
}
# Source the common functions
source "$SCRIPT_DIR/../lib/common_functions.sh"

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
    sed -i -E "/^#?ZED_EMAIL_ADDR.*/c\ZED_EMAIL_ADDR=\"${ZED_EMAIL_ADDR}\"" "${zed_config}"
    sed -i -E "/^#?ZED_EMAIL_PROG.*/c\ZED_EMAIL_PROG=\"msmtp\"" "${zed_config}"
    sed -i -E "/^#?ZED_EMAIL_OPTS.*/c\ZED_EMAIL_OPTS=\"@ADDRESS@\"" "${zed_config}"
    sed -i -E "/^#?ZED_NOTIFY_INTERVAL_SECS.*/c\ZED_NOTIFY_INTERVAL_SECS=${ZED_NOTIFY_INTERVAL_SECS}" "${zed_config}"
    sed -i -E "/^#?ZED_NOTIFY_VERBOSE.*/c\ZED_NOTIFY_VERBOSE=${zed_notify_verbose}" "${zed_config}"

    ## Provide information on result and how to test functionality
    echo "Successfully set health monitoring for all pools in '${zed_config}'"
    if [[ ${zed_notify_verbose} -eq 0 ]]; then
        echo "Make sure to run the command with the '--test' flag to check if everying works as expected!"
    else
        echo "To test ZFS-ZED, run a 'zpool scrub <pool>' and wait for it to finish. You should receive an email."
        echo "After testing, run this command again without the '--test' flag to only monitor unhealthy states."
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
            test_msmtp "${ZED_EMAIL_ADDR}"
            config_zfs_zed --test
        else
            echo "Error: unrecognized argument '$1' for 'zorra zfs monitor-status'"
            echo "Enter 'zorra --help' for usage"
            exit 1
        fi
        ;;
    *)
        echo "Error: wrong number of arguments for 'zorra zfs monitor-status'"
        echo "Enter 'zorra --help' for usage"
        exit 1
        ;;
esac

