#!/bin/bash
set -e

## Get the absolute path to the current script directory
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

## Ensure at least one argument is provided
if [[ $# -eq 0 ]]; then
	echo "Error: missing command/argument for 'zorra refind set'"
	echo "Enter 'zorra --help' for usage"
	exit 1
fi

## Parse the top-level command
command="$1"
shift 1

## Dispatch command
case "${command}" in
	theme)
		"${script_dir}/theme.sh" "$@"
	;;
	timeout)
		"${script_dir}/timeout.sh" "$@"
	;;
	*)
		echo "Error: unrecognized command 'zorra refind set ${command}'"
		echo "Enter 'zorra --help' for usage"
		exit 1
	;;
esac