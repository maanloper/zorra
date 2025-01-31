#!/bin/bash
set -e

## Check for root priviliges
if [ "$(id -u)" -ne 0 ]; then
	echo "This command can only be run as root. Run with sudo or elevate to root."
	exit 1
fi


allow_all_permissions(){
	## Get inputs
	local user="$1"
	local pool="$2"
	permissions_backup_file="/tmp/permissions_backup_${user}"

	## Save current permissions of user for restore
	if [[ ! -e "${permissions_backup_file}" ]]; then
		echo "Backing up current permissions of user '${user}' for pool ${pool}..."
		zfs allow "${user}" | grep "user ${user}" | awk '{print $3}' > "${permissions_backup_file}"
	else
		echo "Permission backup file already exists for user '${user}', skipped saving backup to not override backup..."
	fi

	## Allow all permissions for user
	echo "Allowing all permissions of user '${user}' for pool ${pool}..."
	local all_permissions=$(echo "$(zfs allow -h)" | awk '/NAME/ {found=1; next} found' | awk '!/^[[:space:]]|^mlslabel/ {print $1}' | paste -sd ',')
	zfs allow -u "${user}" "${all_permissions}" "${pool}"

	## Show permissions
	echo
	zfs allow "${pool}"
	echo
}

restore_permissions(){
	## Get inputs
	local user="$1"
	local pool="$2"
	permissions_backup_file="/tmp/permissions_backup_${user}"

	## Remove all permissions of user
	echo "Unallowing current permissions of user '${user}' for pool ${pool}..."
	local current_permissions=$(zfs allow "${user}" | grep "user ${user}" | awk '{print $3}')
	zfs unallow -u "${user}" "${current_permissions}" "${pool}"

	## Allow backed up permissions for user
	echo "Restoring backed up permissions of user '${user}' for pool ${pool}..."
	local permissions_backup=$(cat "${permissions_backup_file}")
	zfs allow -u "${user}" "${permissions_backup}" "${pool}"

	## Remove file
	rm -f "${permissions_backup_file}"

	## Show permissions
	echo
	zfs allow "${pool}"
	echo
}


## Parse arguments
case $# in
    3)
		user="$1"
		pool="$2"
		case "$3" in
			--all|-a)
				allow_all_permissions "${user}" "${pool}"
			;;
			--restore|-r)
				restore_permissions "${user}" "${pool}"
			;;
			*)
				echo "Error: unrecognized argument '$3' for 'zorra zfs allow'"
				echo "Enter 'zorra --help' for command syntax"
				exit 1
			;;
		esac
        ;;
    *)
        echo "Error: wrong number of arguments for 'zorra zfs allow'"
        echo "Enter 'zorra --help' for command syntax"
        exit 1
        ;;
esac