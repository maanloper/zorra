#!/bin/bash
set -e

prompt_input(){
	## Read input twice, and if inputs match, set output variable to input
	while true; do
		local output_variable="${1}"
		local read_text="${2}"
		local confirm="${3}"

		## In confirm is specified input is likely a password/passphrase/key
		local silent=""
		if [[ "${confirm}" == confirm ]]; then
			silent="-s"
		fi

		## Read input
		read ${silent} -r -p "Enter ${read_text}: " input; echo

		## If confirmation is required ask again
		if [[ "${confirm}" == confirm ]]; then
			read ${silent} -r -p "Confirm ${read_text}: " input_confirm; echo

			## Check if inputs match
			if [[ "${input}" == "${input_confirm}" ]]; then
			if [[ -n ${silent} ]]; then echo; fi
				break
			else
				echo "Inputs do not match. Please try again."
				echo
			fi
		else
			break
		fi
	done

	## Assign input to output variable
	printf -v "$output_variable" "%s" "$input"
}