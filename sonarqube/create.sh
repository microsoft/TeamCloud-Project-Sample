#!/bin/bash

trace() {
    echo -e "\n>>> $@ ...\n"
}

error() {
    echo "Error: $@" 1>&2
}

# get the default runner script path to execute first before adding custom stuff
SCRIPT="$(find /docker-runner.d -maxdepth 1 -iname "$(basename "$0")")"

# isolate task script execution in sub shell  
( exec "$SCRIPT"; exit $? ) || exit $?

SQHOSTNAME="$(az webapp list --subscription $ComponentSubscription -g "$ComponentResourceGroup" --query "[0].defaultHostName" -o tsv)"

trace "Initializing SonarQube database"
while true; do
    SQHOSTSTATUS="$(curl -s https://$SQHOSTNAME/api/system/status | jq '.status' | tr -d '"')"
    [ "$SQHOSTSTATUS" == "UP" ] && { echo '' && break; } || { echo -n '.' && sleep 5; }
done

trace "Configuring SonarQube service"

SQADMINUSERNAME="admin"
SQADMINPASSWORD="$( echo "$ComponentTemplateParameters" | jq --raw-output '.adminPassword' )" # <== this is where we reference the admin password defined as parameter
SQSCANNERUSERNAME="scanner"
SQSCANNERPASSWORD="$( uuidgen | tr -d '-' )"

# fetch an access token using the default admin password - if this works, the current SQ instance is completely unconfigurated
SQTOKEN="$( curl -s -u $SQADMINUSERNAME:$SQADMINUSERNAME -d "" -X POST "https://$SQHOSTNAME/api/user_tokens/generate?name=$(uuidgen)" | jq --raw-output '.token' )"

if [ ! -z "$SQTOKEN" ]; then
    echo "- Initializing user: admin" # the admin password was still set to its default value. therefore we received a valid token and need to update the admin's password first
    curl -s -u $SQTOKEN: --data-urlencode "password=$SQADMINPASSWORD" -X POST "https://$SQHOSTNAME/api/users/change_password?login=$SQADMINUSERNAME&previousPassword=$SQADMINUSERNAME"
fi

# refresh the admin token to do further configuration tasks - this time we use the password provided by the component input json
SQTOKEN="$( curl -s -u $SQADMINUSERNAME:$SQADMINPASSWORD -d "" -X POST "https://$SQHOSTNAME/api/user_tokens/generate?name=$(uuidgen)" | jq --raw-output '.token' )"

echo "- Initialize user: scanner"
SQSTATUS="$( curl -s -o /dev/null -w "%{http_code}" -u $SQTOKEN: --data-urlencode "name=$SQSCANNERUSERNAME" -X POST "https://$SQHOSTNAME/api/users/create?login=$SQSCANNERUSERNAME&password=$SQSCANNERPASSWORD" )"

if [ "$SQSTATUS" == "200" ]; then 
    curl -s -u $SQTOKEN: -d "" -X POST "https://$SQHOSTNAME/api/permissions/add_user?login=$SQSCANNERUSERNAME&permission=scan"
    curl -s -u $SQTOKEN: -d "" -X POST "https://$SQHOSTNAME/api/permissions/add_user?login=$SQSCANNERUSERNAME&permission=provisioning"
fi

echo "- Configure authentication"
curl -s -u $SQTOKEN: -d "" -X POST "https://$SQHOSTNAME/api/settings/set?key=sonar.forceAuthentication&value=true"
