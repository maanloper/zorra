#!/bin/bash
set -e

show_from_to(){
    ## Input variables
    local input1="$1" # Text for the left side of the '>'
    local input2="$2" # Text for the right side of the '>'

    ## Calculate the maximum width of the left column
    local maxlen=$(echo "${input1}" | awk '{ if (length > maxlen) maxlen = length } END { print maxlen }')

    ## Align the output
    paste <(echo "${input1}") <(echo "${input2}") | awk -v maxlen="${maxlen}" 'BEGIN { FS="\t" } { printf "%-*s > %s\n", maxlen, $1, $2 }'
}