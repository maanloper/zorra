#!/bin/bash
set -e




#!/bin/bash
set -o history

# Check if script is run by systemd
systemd=0
if [[ $(ps -o comm= -p $(ps -o ppid= -p $$)) == "systemd" ]]; then
    systemd=1
fi

# Redirect stdout and stderr to logs
if [[ ${systemd} -eq 1 ]]; then
	script=$(basename "${0}")
	exec > >(systemd-cat -t "${script}" -p info)
	exec 2> >(systemd-cat -t "${script}" -p err)
fi

# Load send_email function
source /usr/local/bin/send_email.sh

# Load Docker start/stop functions
source /usr/local/bin/start_stop_docker_containers.sh

# Error logging and mail function
error_handler() {
    echo -e "${1}" >&2
    send_email "Error in ${script}" "$(echo -e "${1}")"
    exit 1
}

# Stop Docker containers
stop_docker_containers

# Set retention policy. Defaults to daily.
retention_policy="daily"
if [[ $(date +%d) -eq 1 && ${systemd} -eq 1 ]]; then
    retention_policy="monthly" # Set retention policy to monthly if first day of the month and script is executed by systemd
fi

# Create recursive snapshot of root dataset, on failure call error_handler
snapshot_name="droppi@$(date +"%Y%m%dT%H%M")-${retention_policy}"
snapshot_error=$(zfs snapshot -r -o :retention_policy="${retention_policy}" "${snapshot_name}" 2>&1) || \
    error_handler "Error on line $((LINENO)): $(history | tail -n 1 | sed -E 's/^ *[0-9]+ +//;s/ *\|\|.*$//')\n\nError:\n${snapshot_error}"

# Log successful execution
echo -e "Created snapshot: ${snapshot_name}"

# Run only if script was executed by systemd
if [[ ${systemd} -eq 1 ]]; then
    # Start Docker containers
    start_docker_containers

    # Prune snapshots
    /usr/local/bin/prune_snapshots.sh
else
	echo "Script executed from CLI:"
	echo "    - Stopped docker containers will not be restarted automatically"
	echo "    - Snapshots will not be pruned"
fi