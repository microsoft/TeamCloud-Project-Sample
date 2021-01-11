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

SQADMINUSERNAME="admin"
echo "SQADMINUSERNAME=$SQADMINUSERNAME"
SQADMINPASSWORD="$( echo "$ComponentTemplateParameters" | jq --raw-output '.adminPassword' )" # <== this is where we reference the admin password defined as parameter
echo "SQADMINPASSWORD=$SQADMINPASSWORD"
SQADMINTOKEN=$(curl -s -u $SONARQUBE_ADMIN_USER:$SONARQUBE_ADMIN_USER -X POST "https://$SQHOSTNAME/api/user_tokens/generate?name=Configure" | jq .token | tr -d '"')
echo "SQADMINTOKEN=$SQADMINTOKEN"

trace "Configuring SonarQube users"
curl -s -u $SQADMINTOKEN: --data-urlencode "password=$SQADMINPASSWORD" -X POST "https://$SQHOSTNAME/api/users/change_password?login=$SQADMINUSERNAME&previousPassword=$SQADMINUSERNAME"
curl -s -u $SQADMINTOKEN: -X POST "https://$SQHOSTNAME/api/settings/set?key=sonar.forceAuthentication&value=true"
