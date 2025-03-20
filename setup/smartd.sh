#!/bin/bash
set -e

## Check for root priviliges
if [ "$(id -u)" -ne 0 ]; then
    echo "This command can only be run as root. Run with sudo or elevate to root."
    exit 1
fi


setup_smartd(){
	## Get variables
	local test="$1"

	## Install smartmontools
	apt install -y smartmontools

	## Change /etc/smartmontools/run.d/10mail to use msmtp
	cat <<-EOF2 > /etc/smartmontools/run.d/10mail
		#!/bin/bash

		if [ -z "\${SMARTD_ADDRESS}" ]; then
		    echo "\$0: SMARTD_ADDRESS must be set"
		    exit 1
		fi

		exec /usr/bin/msmtp \${SMARTD_ADDRESS} <<EOF
		Subject: \${SMARTD_SUBJECT-[SMARTD_SUBJECT]}
		To: \${SMARTD_ADDRESS// /, }

		\${SMARTD_FULLMESSAGE-[SMARTD_FULLMESSAGE]}
		EOF
	EOF2

	## Activate SMART attributes on all disks
	for disk in $(lsblk -d -n -o NAME,TYPE | awk '$2 == "disk" {print "/dev/"$1}'); do
		smartctl -s on -o on -S on "${disk}" || true
	done

	## Set DEVICESCAN in /etc/smartd.conf (with optional '-M test' flag), short test run daily at 01:00, long test on 1st of every month at 02:00
	if [[ -n "${test}" ]]; then
        test_arg="-M test"
    fi

	sed -i "/^DEVICESCAN/c\DEVICESCAN -a -o on -S on -s (L/../01/./02|S/../.././01) -m ${EMAIL_ADDRESS} -M exec /usr/share/smartmontools/smartd-runner ${test_arg}" /etc/smartd.conf

	## Restart smartd service
	systemctl restart smartd
}

## Parse arguments
case $# in
    0)
        setup_smartd
        ;;
    1)
        if [[ "$1" == --test ]]; then
            setup_smartd --test
        else
            echo "Error: unrecognized argument '$1' for 'zorra setup smartd'"
            echo "Enter 'zorra --help' for command syntax"
            exit 1
        fi
        ;;
    *)
        echo "Error: wrong number of arguments for 'zorra setup smartd'"
        echo "Enter 'zorra --help' for command syntax"
        exit 1
        ;;
esac
