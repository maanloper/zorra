#!/bin/bash
set -e

## Check for root priviliges
if [ "$(id -u)" -ne 0 ]; then
	echo "This command can only be run as root. Run with sudo or elevate to root."
	exit 1
fi

validate_key(){
	## Check if disable_backups-file exists (triggered by key change)
	if [ -f /usr/local/zorra/disable_backups ]; then
		echo "Error: no backup created due to triggered by disable_backups-file"
		exit 1
	fi

	## Set send and receive pool
	local send_pool="$1"
	local receive_pool="$2"



	## Get latest local snapshot (a snapshot must be send to check crypt_keydata)
	latest_root_dataset_snapshot=$(zfs list -H -t snapshot -o name -s creation "${pool}" | tail -n 1)

	## Latest local crypt_keydata
	crypt_keydata_local="./crypt_keydata_${pool}_local"
	output=$(zfs send -w "${latest_root_dataset_snapshot}" | zstreamdump -d | awk '/end crypt_keydata/{exit}1')
	echo "$output" | sed -n '/crypt_keydata/,$p' | sed 's/^[ \t]*//' > "${crypt_keydata_local}"

	## Latest remote crypt_keydata
	crypt_keydata_remote="./crypt_keydata_${pool}_remote"
	output=$(zfs send -w "${latest_root_dataset_snapshot}" | zstreamdump -d | awk '/end crypt_keydata/{exit}1')
	echo "$output" | sed -n '/crypt_keydata/,$p' | sed 's/^[ \t]*//' > "${crypt_keydata_remote}"
	
	## Compare local and remote crypt_keydata
	if ! cmp -s ${crypt_keydata_local} ${crypt_keydata_remote}; then
		echo "Error: local and remote crypt_keydata are not equal"
		echo "Creating file '/usr/local/zorra/disable_backups' and exiting script"

		## Create file to disable further backup tries
		touch /usr/local/zorra/disable_backups

		## Send warning email
		echo -e "Subject: WARNING: keychange on ${pool}\n\nLocal and remote crypt_keydata are not equal\ncrypt_keydata_local:\n${crypt_keydata_local}\n\crypt_keydata_remote:\n${crypt_keydata_remote}" | msmtp "${EMAIL_ADDRESS}"

		## Stop execution
		exit 1
	fi
}

create_backup(){
	## Set send and receive pool
	local send_pool="$1"
	local receive_pool="$2"

	## Set ssh prefix if ssh host is specified
	if [ -n "$3" ]; then
		local ssh_host="$3"
		if [ -n "$4" ]; then
			local ssh_port="-p $4"
		fi
		local ssh_prefix="ssh ${ssh_host} ${ssh_port}"
	fi

	## Get all first-level subdirectories (since root dataset cannot be restored, after a full pool restore the (not restored) root dataset has no matching snapshots on backup pool)
	local send_datasets=$(${ssh_prefix} zfs list -H -o name -r "${send_pool}" | sed -n "s|^$send_pool/\([^/]*\).*|$send_pool/\1|p" | sort -u)
	if [ -z "${send_datasets}" ]; then echo "Error: pool '${send_pool}' does not exist or has no child datasets to backup"; exit 1; fi

	## Send all datasets including children (-R flag) to receive dataset
	for send_dataset in ${send_datasets}; do
		## Get latest snapshot on sending side
		local latest_send_snapshot=$(${ssh_prefix} zfs list -H -t snap -o name -s creation "${send_dataset}" | tail -n 1)
		if [ -z "${latest_send_snapshot}" ]; then echo "Error: target '${send_dataset}' does not exist or has no snapshots to backup"; exit 1; fi

		## Set receive dataset
		local receive_dataset="${receive_pool}/${send_dataset}"

		## Get latest snapshot on receiving side, set incremental if it exists
		local latest_receive_snapshot=$(zfs list -H -t snap -o name -s creation "${receive_dataset}" | tail -n 1)
		if [ -n "${latest_receive_snapshot}" ]; then
			local incremental_snapshot="-I ${latest_receive_snapshot#*@}"
		else
			echo "No received snapshot found, executing a full send/receive..."
		fi

		## Execute send/receive
		if ${ssh_prefix} zfs send -b -w -R "${incremental_snapshot}" "${latest_send_snapshot}" | zfs receive -v "${receive_dataset}"; then
			echo "Successfully backed up '${latest_send_snapshot}' into '${receive_dataset}'"
		else
			echo "Failed to send/receive '${latest_send_snapshot}' into '${receive_dataset}'"
			#exit 1
		fi
	done
}

## Set backup dataset and receiving pool
send_pool="$1"
receive_pool="$2"
shift 2

## Init args
validate_key=false

## Get any arguments
while [[ $# -gt 0 ]]; do
	case "$1" in
		--ssh)
			ssh_host="$2"
			shift 1
		;;
		-p)
			ssh_port="$2"
 			shift 1
 		;;
		--no-key-validation)
			validate_key=false
 		;;
		*)
 			echo "Error: unrecognized argument '$1' for 'zorra zfs backup'"
 			echo "Enter 'zorra --help' for command syntax"
 			exit 1
		;;
	esac
	shift 1
done

## Run code
if ${validate_key}; then
	validate_key "${send_pool}" "${receive_pool}"
fi
create_backup "${send_pool}" "${receive_pool}" "${ssh_host}" "${ssh_port}"