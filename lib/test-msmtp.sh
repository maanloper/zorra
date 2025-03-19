#!/bin/bash
set -e

test_msmtp(){
    local email_address="$1"

    ## Set message
    local message="Subject: Test of msmtp on $(hostname)\n\nNote: this email only confirms that msmtp is properly configured to send emails. Any programs/scripts using msmtp must be tested separately."
    
    ## Ensure an email can be send
    if echo -e "${message}" | msmtp "${email_address}"; then
        echo "Successfully sent a test email using msmtp, check your inbox/spam"
        echo "Note: this only tests msmtp, not any other programs/scripts!"
    else
        echo "Error: could not sent a test email to ${email_address} using msmtp"
        echo "Check your settings in the .env file and configure msmtp (see 'zorra --help' for the command)"
        exit 1
    fi
}