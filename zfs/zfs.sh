#!/bin/bash
set -e

## Get the absolute path to the current script directory
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

## Ensure at least one argument is provided
if [[ $# -eq 0 ]]; then
	echo "Error: missing command/argument for 'zorra zfs'"
	echo "Enter 'zorra --help' for usage"
	exit 1
fi

## Parse the top-level command
command="$1"
shift 1

## Dispatch command
case "${command}" in
	list)
		"${script_dir}/list.sh" "$@"
	;;
	snapshot)
		"${script_dir}/snapshot.sh" "$@"
	;;
	rollback)
		"${script_dir}/rollback.sh" "$@"
	;;
	undo-rollback)
		"${script_dir}/undo-rollback.sh" "$@"
	;;
	promote)
		"${script_dir}/promote.sh" "$@"
	;;
	destroy)
		"${script_dir}/destroy.sh" "$@"
	;;
	monitor-status)
		"${script_dir}/monitor-status.sh" "$@"
	;;
	auto-unlock)
		"${script_dir}/auto-unlock.sh" "$@"
	;;
	change-key)
		"${script_dir}/change-key.sh" "$@"
	;;
	*)
		echo "Error: unrecognized command 'zorra zfs ${command}'"
		echo "Enter 'zorra --help' for usage"
		exit 1
	;;
esac