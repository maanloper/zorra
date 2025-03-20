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

setup_msmtp(){
    ## Install msmtp
    echo "msmtp   msmtp/apparmor  boolean true" | debconf-set-selections
    DEBIAN_FRONTEND=noninteractive apt install -y --no-install-recommends msmtp

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
    if [[ "$1" != --test ]]; then
        echo "To test if mstmp works as expected, run this command with the '--test' flag"
    fi
}


## Parse arguments
case $# in
    0)
        setup_msmtp
        ;;
    1)
        if [[ "$1" == --test ]]; then
            setup_msmtp --test
            test_msmtp "${EMAIL_ADDRESS}"

        else
            echo "Error: unrecognized argument '$1' for 'zorra setup msmtp'"
            echo "Enter 'zorra --help' for command syntax"
            exit 1
        fi
        ;;
    *)
        echo "Error: wrong number of arguments for 'zorra setup msmtp'"
        echo "Enter 'zorra --help' for command syntax"
        exit 1
        ;;
esac
