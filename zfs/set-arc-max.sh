#!/bin/bash
set -e

## Check for root priviliges
if [ "$(id -u)" -ne 0 ]; then
    echo "This command can only be run as root. Run with sudo or elevate to root."
    exit 1
fi

get_arc_max(){
    ## Display current zfs_arc_max
    zfs_arc_max=$(cat /sys/module/zfs/parameters/zfs_arc_max)
    if [[ ${zfs_arc_max} -ne 0 ]]; then
        zfs_arc_max_gb=$(echo "scale=1;  ${zfs_arc_max} / (1000*1000*1000)" | bc)
        zfs_arc_max_gib=$(echo "scale=1;  ${zfs_arc_max} / (1024*1024*1024)" | bc)
        echo "Current zfs_arc_max: ${zfs_arc_max} bytes (~${zfs_arc_max_gb}GB | ~${zfs_arc_max_gib}GiB)"
    else
		cat <<-EOF
			Current value of zfs_arc_max is set to '0'
			This sets a default % of ram for zfs_arc_max depending on OS
			Check the OpenZFS documention to see what this percentage is for your OS
			
			Run 'zorra zfs set-arc-max [<int> (bytes) / <int>%]' to set a custom value
		EOF
    fi
}

calculate_arc_max(){
    ## calculate the value of zfs_arc_max from percentage
    local percentage="${1%\%}"
    if (( percentage < 0 || percentage > 100 )); then
        echo "Error: percentage for set-arc-max must be between 0% and 100%"
        exit 1
    fi

    ## Calculate zfs_arc_max based on total installed ram and percentage
    local total_ram=$(free -b | awk '/^Mem:/ {print $2}')
    local zfs_arc_max=$(( (${total_ram} * ${percentage}) / 100 ))
    echo "$zfs_arc_max"
}

set_arc_max(){
    ## Get zfs_arc_max from input
    local zfs_arc_max="$1"

    ## Check that value is smaller than total ram
    total_ram=$(free -b | awk '/^Mem:/ {print $2}')
    if (( zfs_arc_max > total_ram )); then
        echo "Error: zfs_arc_max cannot be set larger than total available ram (${total_ram} bytes)"
        exit 1
    fi

    ## Get current zfsbootmenu:commandline and remove zfs.zfs_arc_max=<int> from it
    local zfsbootmenu_commandline=$(zfs get -H -o value org.zfsbootmenu:commandline "${ROOT_POOL_NAME}" | sed 's/zfs\.zfs_arc_max=[0-9]\+//' | awk '{$1=$1;print}')

    ## Append zfs_arc_max to zfsbootmenu:commandline
    zfsbootmenu_commandline+=" zfs.zfs_arc_max=${zfs_arc_max}"

    ## Set zfsbootmenu:commandline
    zfs set org.zfsbootmenu:commandline="${zfsbootmenu_commandline}" "${ROOT_POOL_NAME}"

    ## Report on result
    zfs_arc_max_gb=$(echo "scale=1;  ${zfs_arc_max} / (1000*1000*1000)" | bc)
    zfs_arc_max_gib=$(echo "scale=1;  ${zfs_arc_max} / (1024*1024*1024)" | bc)
		cat <<-EOF
			Successfully set zfs_arc_max to ${zfs_arc_max} bytes (~${zfs_arc_max_gb}GB / ~${zfs_arc_max_gib}GiB)
			Reboot your system for the change to take effect
			After rebooting run 'zorra zfs set-arc-max --show' to check
		EOF

}

## Parse arguments
case $# in
    0)
		# Default arc size
            set_arc_max "$(calculate_arc_max "85%")"
        ;;
    1)
        if [[ "$1" == --show ]]; then
            get_arc_max
        elif [[ "$1" =~ ^[0-9]+%$ ]]; then
            set_arc_max "$(calculate_arc_max "$1")"
        elif [[ "$1" =~ ^[0-9]+$ ]]; then
            set_arc_max "$1"
        else
            echo "Error: unrecognized argument '$1' for 'zorra zfs set-arc-max'"
            echo "Enter 'zorra --help' for command syntax"
            exit 1
        fi
        ;;
    *)
        echo "Error: wrong number of arguments for 'zorra zfs set-arc-max'"
        echo "Enter 'zorra --help' for command syntax"
        exit 1
        ;;
esac