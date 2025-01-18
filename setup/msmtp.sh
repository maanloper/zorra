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
source "$script_dir/../lib/test_msmtp.sh"

setup_msmtp(){
    ## Install msmtp
    apt install msmtp

    ## Config msmtp
	cat <<-EOF > /etc/msmtprc
		# Default SMTP configuration
		account default-account
		host ${HOST}
		port ${PORT}
		user ${USER}
		password ${PASSWORD}
		from_full_name ${FROM_FULL_NAME}
		from ${FROM}
		auth on
		tls on
		tls_starttls on
		syslog on
		
		# Set default account
		account default : default-account
	EOF

	## Set permissions
	chmod 600 /etc/msmtprc

    echo "Successfully configured mstmp"
    echo "To test if mstmp works as expected, run this command with the '--test' flag"
}


## Parse arguments
case $# in
    0)
		# No verbosity set in ZFS-ZED
        setup_msmtp
        ;;
    1)
        if [[ "$1" == --test ]]; then
            setup_msmtp
            test_msmtp "${EMAIL_ADDRESS}"

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
