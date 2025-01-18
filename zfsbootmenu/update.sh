#!/bin/bash
set -e

update_zfsbootmenu(){
	## Download latest ZFSBootMenu
	curl -L https://get.zfsbootmenu.org/source | tar -zxv --strip-components=1 -C /usr/local/src/zfsbootmenu -f -
	make -C /usr/local/src/zfsbootmenu core dracut

	## Update ZBM configuration file
	sed \
		-e 's|ManageImages:.*|ManageImages: true|' \
		-e 's|ImageDir:.*|ImageDir: /boot/efi/EFI/zbm|' \
		-e 's|Versions:.*|Versions: 2|' \
		-e '/^Components:/,/^[^[:space:]]/ s|Enabled:.*|Enabled: true|' \
		-e '/^EFI:/,/^[^[:space:]]/ s|Enabled:.*|Enabled: false|' \
		-i /etc/zfsbootmenu/config.yaml
	
	## Generate initramfs with check if keystore is mounted
	safe_generate_initramfs

	## Generate new ZFSBootMenu image
	generate-zbm
}