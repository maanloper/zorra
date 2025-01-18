#!/bin/bash
set -e

## Check for root priviliges
if [ "$(id -u)" -ne 0 ]; then
   echo "This command can only be run as root. Run with sudo or elevate to root."
   exit 1
fi

set_refind_theme(){
	local refind_theme="$1"
	local refind_theme_config="$2"

	# Ensure the rEFInd config file exists before modifying
	local refind_config="/boot/efi/EFI/refind/refind.conf"
	if [[ ! -f "${refind_config}" ]]; then
		echo "Error: rEFInd configuration file not found at '${refind_config}'"
		exit 1
    fi

	## Remove themes dir and clear theme from rEFInd config
	rm -fr /boot/efi/EFI/refind/themes
	sed -i "/^include themes\//d" "${refind_config}"

	if [[ "${refind_theme}" == "none" ]]; then
		echo "Removed rEFInd theme"
	else
		## Create themes dir if needed
		mkdir -p /boot/efi/EFI/refind/themes

		## Git clone theme
		git -C /boot/efi/EFI/refind/themes clone ${refind_theme}

		## Include theme in rEFInd config
		echo "include themes/${refind_theme_config}" >> "${refind_config}"

		echo "Successfully set rEFInd theme ${refind_theme}"
	fi
}


## Parse arguments
case $# in
    0)
		# Default theme
        set_refind_theme "https://github.com/maanloper/darkmini.git" "darkmini/theme-mini.conf"
        ;;
    1)
        if [[ "$1" == "none" ]]; then
            set_refind_theme "$1"
        else
            echo "Error: unrecognized argument '$1' for 'zorra refind set theme'"
            echo "Enter 'zorra --help' for usage"
            exit 1
        fi
        ;;
    2)
        if [[ "$1" =~ git && -n "$2" ]]; then
            set_refind_theme "$1" "$2"
        else
            echo "Error: unrecognized arguments '$@' for 'zorra refind set theme'"
            echo "Enter 'zorra --help' for usage"
            exit 1
        fi
        ;;
    *)
        echo "Error: wrong number of arguments for 'zorra refind set theme'"
        echo "Enter 'zorra --help' for usage"
        exit 1
        ;;
esac