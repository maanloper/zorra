#!/bin/bash
set -e

## TODO: these values are also needed in debootstrap install. How to do this?
## Default rEFInd settings (can be overridden with flags)
refind_timeout="3"											# Default timeout before rEFInd boots default bootloader



set_refind_timeout(){
	## Update ZFSBootMenu timer if required
	sed -i "s|^timeout .*|timeout ${refind_timeout}|" /boot/efi/EFI/refind/refind.conf
	echo "Successfully set rEFInd bootscreen timeout ${refind_timeout}"
}