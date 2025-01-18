#!/bin/bash
set -e


if [ -f "${SCRIPT_DIR}/.env" ]; then
    export $(grep -v '^#' "${SCRIPT_DIR}/.env" | xargs)
fi

## Send email: install and configure msmtp
apt install msmtp

cat <<-EOF > /etc/msmtprc
# Default SMTP configuration
account default-account
host ${HOST}
port ${PORT}
user ${USER}
password ${PASSWORD}
from_full_name ${FROM_FULL_NAME}
from ${FROM}
auth on
tls on
tls_starttls on
syslog on

# Set default account
account default : default-account
EOF

chmod 600 /etc/msmtprc