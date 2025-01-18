#!/bin/bash
set -e

## Get the absolute path to the current script directory
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

## Get .env
export $(grep -v '^#' "${script_dir}/../.env" | xargs)

sed -i -E "/^#?ZED_EMAIL_ADDR.*/c\ZED_EMAIL_ADDR=\"${ZED_EMAIL_ADDR}\"" /etc/zfs/zed.d/zed.rc
sed -i -E "/^#?ZED_EMAIL_PROG.*/c\ZED_EMAIL_PROG=\"msmtp\"" /etc/zfs/zed.d/zed.rc
sed -i -E "/^#?ZED_EMAIL_OPTS.*/c\ZED_EMAIL_OPTS=\"@ADDRESS@\"" /etc/zfs/zed.d/zed.rc
sed -i -E "/^#?ZED_NOTIFY_INTERVAL_SECS.*/c\ZED_NOTIFY_INTERVAL_SECS=${ZED_NOTIFY_INTERVAL_SECS}" /etc/zfs/zed.d/zed.rc