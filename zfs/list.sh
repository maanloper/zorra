#!/bin/bash
set -e

list=$(zfs list -o name,keystatus,canmount,mounted,mountpoint "$@")

echo "${list}" \
| GREP_COLORS='ms=01;31' grep --color=always -E "(.* on .* no .*|$)" \
| GREP_COLORS='ms=01;33' grep --color=always -E "(.* noauto .* yes .*|$)" \
| GREP_COLORS='ms=01;00' grep --color=always -E "(.* on .* yes .*|$)" \
| GREP_COLORS='ms=01;30' grep --color=always -E "(.* no .*|$)"
echo

## Add yellow for noauto