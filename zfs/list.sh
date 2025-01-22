#!/bin/bash
set -e

#zfs list -o name,keystatus,canmount,mounted,mountpoint "$@"
list=$(zfs list -o name,keystatus,canmount,mounted,mountpoint "$@")

echo "${list}" \
| GREP_COLORS='ms=01;32' grep --color=always -E "(.* [a-z]* .* yes .*|$)" \
| GREP_COLORS='ms=01;30' grep --color=always -E "(.* [a-z]* .* no .*|$)" \
| GREP_COLORS='ms=01;31' grep --color=always -E "(.* on .* no .*|$)"
echo