#!/bin/bash
set -e

## Get the absolute path to the current script directory
script_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"

## Ensure at least one argument is provided
if [[ $# -eq 0 ]]; then
	echo "Error: missing command/argument for 'zorra zfs'"
	echo "Enter 'zorra --help' for command syntax"
	exit 1
fi

## Parse the top-level command
command="$1"
shift 1

## Dispatch command
case "${command}" in
	list)
		"${script_dir}/${command}.sh" "$@"
	;;
	snapshot)
		"${script_dir}/${command}.sh" "$@"
	;;
	safe-rollback)
		"${script_dir}/${command}.sh" "$@"
	;;
	undo-rollback)
		"${script_dir}/${command}.sh" "$@"
	;;
	full-promote)
		"${script_dir}/${command}.sh" "$@"
	;;
	monitor-status)
		"${script_dir}/${command}.sh" "$@"
	;;
	auto-unlock)
		"${script_dir}/${command}.sh" "$@"
	;;
	change-key)
		"${script_dir}/${command}.sh" "$@"
	;;
	set-arc-max)
		"${script_dir}/${command}.sh" "$@"
	;;
	*)
		echo "Error: unrecognized command 'zorra zfs ${command}'"
		echo "Enter 'zorra --help' for command syntax"
		exit 1
	;;
esac