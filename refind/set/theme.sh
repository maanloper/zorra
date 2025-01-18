#!/bin/bash
set -e

## Default theme (can be overridden with flags)
refind_theme="https://github.com/maanloper/darkmini.git"	# Default rEFInd theme
refind_theme_config="darkmini/theme-mini.conf"				# Default rEFInd theme config

set_refind_theme(){
	if [[ "${refind_theme}" == "none" ]]; then
		## Remove theme
		rm -fr /boot/efi/EFI/refind/themes/*
		sed -i "/^include themes\//d" /boot/efi/EFI/refind/refind.conf
		echo "Removed rEFInd theme"
	else
		## Set and clear themes dir
		mkdir -p /boot/efi/EFI/refind/themes
		rm -fr /boot/efi/EFI/refind/themes/*
		git -C /boot/efi/EFI/refind/themes clone ${refind_theme}

		## Include theme
		sed -i "/^include themes\//d" /boot/efi/EFI/refind/refind.conf
		echo "include themes/${refind_theme_config}" >> /boot/efi/EFI/refind/refind.conf

		echo "Successfully set rEFInd theme ${refind_theme}"
	fi
}