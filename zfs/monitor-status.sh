#!/bin/bash
set -e

## Check for root priviliges
if [ "$(id -u)" -ne 0 ]; then
    echo "This command can only be run as root. Run with sudo or elevate to root."
    exit 1
fi

## Get the absolute path to the current script directory
script_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"

## Get .env
#if [[ -f ${script_dir}/../.env" ]]; then
#    export $(grep -E '^[a-zA-Z_][a-zA-Z0-9_]*=.*' "${script_dir}/../.env" | xargs)
#else
#    echo "No .env file found. Please run 'sudo cp example.env .env' and edit the contents"
#fi

## Ensure an email can be sent
if ! echo -e "Subject: Monitor-status test\n\nNote: this is not a confirmation ZFS-ZED can sent an email, merely that msmtp is configured correctly to sent emails" | msmtp "${ZED_EMAIL_ADDR}"; then
    echo "Error: could not send a test email to ${ZED_EMAIL_ADDR} using msmtp"
    echo "Check your settings in the .env file and configure msmtp (see 'zorra --help' for the command)"
    exit 1
fi

## Ensure the ZFS-ZED config file exists before modifying
zed_config="/etc/zfs/zed.d/zed.rc"
if [[ ! -f "${zed_config}" ]]; then
    echo "Error: ZFS-ZED configuration file not found at '${zed_config}'"
    exit 1
fi

## Updates values in ZFS-ZED config
sed -i -E "/^#?ZED_EMAIL_ADDR.*/c\ZED_EMAIL_ADDR=\"${ZED_EMAIL_ADDR}\"" "${zed_config}"
sed -i -E "/^#?ZED_EMAIL_PROG.*/c\ZED_EMAIL_PROG=\"msmtp\"" "${zed_config}"
sed -i -E "/^#?ZED_EMAIL_OPTS.*/c\ZED_EMAIL_OPTS=\"@ADDRESS@\"" "${zed_config}"
sed -i -E "/^#?ZED_NOTIFY_INTERVAL_SECS.*/c\ZED_NOTIFY_INTERVAL_SECS=${ZED_NOTIFY_INTERVAL_SECS}" "${zed_config}"
sed -i -E "/^#?ZED_NOTIFY_VERBOSE.*/c\ZED_NOTIFY_VERBOSE=${ZED_NOTIFY_VERBOSE}" "${zed_config}"

echo "Successfully enabled health monitoring for all pools"
echo "If you have set ZED_NOTIFY_VERBOSE to 1 in .env, run a scrub on a pool and wait for it to finish to check if you receive an email"