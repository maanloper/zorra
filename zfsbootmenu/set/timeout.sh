#!/bin/bash
set -e

## TODO: these values are also needed in debootstrap install. How to do this?
## Default ZFSBootMenu settings (can be overridden with flags)
zbm_timeout="-1"											# Default timeout before ZBM boots default OS [zbm.timeout=0 -> zbm.skip, zbm.timeout=-1 -> zbm.show]


set_zbm_timeout(){
	## Update ZFSBootMenu timer if required
	sed -i "s|zbm.timeout=-\?[0-9]*|zbm.timeout=${zbm_timeout}|" /boot/efi/EFI/zbm/refind_linux.conf
	echo "Successfully set zbm.timeout=${zbm_timeout}"
}