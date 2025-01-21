#!/bin/bash
set -e

prompt_list(){
	## Get input
	local output_variable="$1"
	local list="$2"
	local prompt_text="$3"

	## Show list to user
	echo "${prompt_text}:"
	nl <<< "${list}"
	echo

	## Get selection
	local count=$(wc -l <<< "${list}")
	local n=""
	while true; do
		read -r -p 'Select option: ' n
		if [ "$n" -eq "$n" ] && [ "$n" -gt 0 ] && [ "$n" -le "${count}" ]; then
			break
		else
			echo "Invalid selection"
			echo
		fi
	done
	selected="$(sed -n "${n}p" <<< "${list}")"

	## Assign selection to output variable
	printf -v "${output_variable}" "%s" "${selected}"
}