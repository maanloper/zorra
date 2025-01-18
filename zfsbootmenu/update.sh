#!/bin/bash
set -e

## Check for root priviliges
if [ "$(id -u)" -ne 0 ]; then
   echo "This command can only be run as root. Run with sudo or elevate to root."
   exit 1
fi

## Get the absolute path to the current script directory
script_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"

# Source safe_generate_initramfs
source "$script_dir/../lib/safe-generate-initramfs.sh"

update_zfsbootmenu(){
	## Pull latest ZFSBootMenu from github
	git -C /usr/local/src/zfsbootmenu pull
	
	## Make ZFSBootMenu using dracut
	make -C /usr/local/src/zfsbootmenu core dracut

	# Ensure the ZFSBootMenu config file exists before modifying
	local zfsbootmenu_config="/etc/zfsbootmenu/config.yaml"
	if [[ ! -f "${zfsbootmenu_config}" ]]; then
		echo "Error: ZFSBootMenu configuration file not found at '${zfsbootmenu_config}'"
		exit 1
    fi

	## Update ZFSBootMenu configuration file
	sed \
		-e 's|ManageImages:.*|ManageImages: true|' \
		-e 's|ImageDir:.*|ImageDir: /boot/efi/EFI/zbm|' \
		-e 's|Versions:.*|Versions: 2|' \
		-e '/^Components:/,/^[^[:space:]]/ s|Enabled:.*|Enabled: true|' \
		-e '/^EFI:/,/^[^[:space:]]/ s|Enabled:.*|Enabled: false|' \
		-i "${zfsbootmenu_config}"
		
	## Generate initramfs with check if keystore is mounted
	safe_generate_initramfs

	## Generate new ZFSBootMenu image
	generate-zbm
}

if [[ $# -gt 0 ]]; then
	echo "Error: no arguments allowed for 'zorra zfsbootmenu update'"
	echo "Enter 'zorra --help' for usage"
	exit 1
fi

update_zfsbootmenu