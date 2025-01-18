#!/bin/bash

# Get the absolute path to the script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Parse the top-level command
command="$1"
shift 1  # Shift away the processed argument

# Dynamically build the script and dir paths
CUR_DIR_PATH="$SCRIPT_DIR/$command.sh"
SUB_DIR_PATH="$SCRIPT_DIR/$command/$command.sh"

# Check if the script exists in the current dir
if [[ -x "$CUR_DIR_PATH" ]]; then
	# Pass all remaining arguments to the script
	"$CUR_DIR_PATH" "$@"

# Check if the script exists the subdir
elif [[ -x "$SUB_DIR_PATH" ]]; then
	# Pass all remaining arguments to the script
	"$SUB_DIR_PATH" "$@"

else
	if [[ -z $command ]]; then
		echo "Missing command"
	else
		echo "Command not found: $command"
	fi
	# Add full overview of possible commands"
	exit 1
fi