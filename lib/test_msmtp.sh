#!/bin/bash
set -e

test_msmtp(){
    local email_address="$1"

    ## Set message
    local message="Subject: Test of msmtp\n\nNote: this is not a confirmation that anything other than msmtp if properly configure, merely that msmtp is configured correctly to sent emails"
    
    ## Ensure an email can be sent
    if echo -e "${message}" | msmtp "${email_address}"; then
        echo "Successfully sent a test email using msmtp. Note: this only tests msmtp, not any other configurations!"
    else
        echo "Error: could not send a test email to ${email_address} using msmtp"
        echo "Check your settings in the .env file and configure msmtp (see 'zorra --help' for the command)"
        exit 1
    fi
}