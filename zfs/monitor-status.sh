#!/bin/bash
set -e

if [ -f "${SCRIPT_DIR}/.env" ]; then
    export $(grep -v '^#' "${SCRIPT_DIR}/.env" | xargs)
fi

sed -i -E "/^#?ZED_EMAIL_ADDR.*/c\ZED_EMAIL_ADDR=\"${ZED_EMAIL_ADDR}\"" /etc/zfs/zed.d/zed.rc
sed -i -E "/^#?ZED_EMAIL_PROG.*/c\ZED_EMAIL_PROG=\"msmtp\"" /etc/zfs/zed.d/zed.rc
sed -i -E "/^#?ZED_EMAIL_OPTS.*/c\ZED_EMAIL_OPTS=\"@ADDRESS@\"" /etc/zfs/zed.d/zed.rc
sed -i -E "/^#?ZED_NOTIFY_INTERVAL_SECS.*/c\ZED_NOTIFY_INTERVAL_SECS=${ZED_NOTIFY_INTERVAL_SECS}" /etc/zfs/zed.d/zed.rc