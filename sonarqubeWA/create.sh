#!/bin/bash

trace() {
    echo -e "\n>>> $@ ...\n"
}

error() {
    echo "Error: $@" 1>&2
}

waitFor() {
    if (( $# == 0 )) ; then
        while read data; do waitFor $data; done;
    else
        local RETRYMAX=60
        local RETRYWEB=0
        local RETRYAPI=0

        echo -n "Web ($1): ." && until [ "$(curl -s -o /dev/null -I -w "%{http_code}" https://$1)" == "200" ]; do
             ((RETRYWEB=RETRYWEB+1)) && [ "$RETRYWEB" -gt "$RETRYMAX" ] && ( echo " timeout after $RETRYMAX retries" && exit 1 ) || ( echo -n '.' && sleep 5 )
        done && echo ' done'

        echo -n "API ($1): ." && until [ "$(curl -s https://$1/api/system/status | jq --raw-output '.status')" == "UP" ]; do
            ((RETRYAPI=RETRYAPI+1)) && [ "$RETRYAPI" -gt "$RETRYMAX" ] && ( echo " timeout after $RETRYMAX retries" && exit 1 ) || ( echo -n '.' && sleep 5 )
        done && echo ' done'
    fi
}

# get the default runner script path to execute first before adding custom stuff
SCRIPT="$(find /docker-runner.d -maxdepth 1 -iname "$(basename "$0")")"

# isolate task script execution in sub shell  
( exec "$SCRIPT"; exit $? ) || exit $?

SQWEBAPPID="$(az webapp list --subscription $ComponentSubscription -g "$ComponentResourceGroup" --query "[0].id" -o tsv)"
SQHOSTNAME="$(az webapp list --subscription $ComponentSubscription -g "$ComponentResourceGroup" --query "[0].defaultHostName" -o tsv)"
SQACCNAME="$(az storage account list --subscription $ComponentSubscription -g "$ComponentResourceGroup" --query "[0].name" -o tsv)"
SQACCKEY="$(az storage account keys list --subscription $ComponentSubscription -g "$ComponentResourceGroup" -n "$SQACCNAME" --query "[0].value" -o tsv)"

trace "Initializing SonarQube"
echo "$SQHOSTNAME" | waitFor

trace "Configuring SonarQube"

SQADMINUSERNAME="admin"
SQADMINPASSWORD="$( echo "$ComponentTemplateParameters" | jq --raw-output '.adminPassword' )" # <== this is where we reference the admin password defined as parameter
SQSCANNERUSERNAME="scanner"
SQSCANNERPASSWORD="$( uuidgen | tr -d '-' )"

# fetch an access token using the default admin password - if this works, the current SQ instance is completely unconfigurated
SQTOKEN="$( curl -s -u $SQADMINUSERNAME:$SQADMINUSERNAME -d "" -X POST "https://$SQHOSTNAME/api/user_tokens/generate?name=$(uuidgen)" | jq --raw-output '.token' )"

echo "- Initializing system user: admin" # if the admin password was still set to its default value we should have received a token now and can change the default password to the provided one.
[ ! -z "$SQTOKEN" ] && curl -s -u $SQTOKEN: --data-urlencode "password=$SQADMINPASSWORD" -X POST "https://$SQHOSTNAME/api/users/change_password?login=$SQADMINUSERNAME&previousPassword=$SQADMINUSERNAME"

# refresh the admin token to do further configuration tasks - this time we use the password provided by the component input json
SQTOKEN="$( curl -s -u $SQADMINUSERNAME:$SQADMINPASSWORD -d "" -X POST "https://$SQHOSTNAME/api/user_tokens/generate?name=$(uuidgen)" | jq --raw-output '.token' )"

echo "- Initializing system user: scanner"
curl -s -o /dev/null -u $SQTOKEN: --data-urlencode "name=$SQSCANNERUSERNAME" -X POST "https://$SQHOSTNAME/api/users/create?login=$SQSCANNERUSERNAME&password=$SQSCANNERPASSWORD"
curl -s -o /dev/null -u $SQTOKEN: -d "" -X POST "https://$SQHOSTNAME/api/permissions/add_user?login=$SQSCANNERUSERNAME&permission=scan"
curl -s -o /dev/null -u $SQTOKEN: -d "" -X POST "https://$SQHOSTNAME/api/permissions/add_user?login=$SQSCANNERUSERNAME&permission=provisioning"

AADTENANTID=""
AADCLIENTID=""
AADCLIENTSECRET=""

echo "- Configure authentication"
curl -s -o /dev/null -u $SQTOKEN: -d "" -X POST "https://$SQHOSTNAME/api/settings/set?key=sonar.forceAuthentication&value=true"

# echo "- Installing plugin: sonar-auth-aad-plugin-1.1.jar"
# [ "$( az storage file exists --subscription $ComponentSubscription --account-name "$SQACCNAME" --account-key "$SQACCKEY" --share-name "extensions" --path "plugins/sonar-auth-aad-plugin-1.1.jar" --query "exists" -o tsv)" == "false" ] && {  
#     curl -s "https://github.com/hkamel/sonar-auth-aad/releases/download/1.1/sonar-auth-aad-plugin-1.1.jar" --output "/var/tmp/sonar-auth-aad-plugin-1.1.jar" 
#     az storage directory create --subscription $ComponentSubscription --account-name "$SQACCNAME" --account-key "$SQACCKEY" --share-name "extensions" --name "plugins" -o none
#     az storage file upload      --subscription $ComponentSubscription --account-name "$SQACCNAME" --account-key "$SQACCKEY" --share-name "extensions" --path "plugins/sonar-auth-aad-plugin-1.1.jar" --source "/var/tmp/sonar-auth-aad-plugin-1.1.jar" --no-progress -o none
# }

# echo "- Configuring plugin: sonar-auth-aad-plugin-1.1.jar"
# curl -s -o /dev/null -u $SQTOKEN: -d "" -X POST "https://$SQHOSTNAME/api/plugins/install?key=authaad"
# curl -s -o /dev/null -u $SQTOKEN: -d "" -X POST "https://$SQHOSTNAME/api/settings/set?key=sonar.auth.aad.enabled&value=true"
# curl -s -o /dev/null -u $SQTOKEN: -d "" -X POST "https://$SQHOSTNAME/api/settings/set?key=sonar.auth.aad.clientId.secured&value=$AADCLIENTID"
# curl -s -o /dev/null -u $SQTOKEN: --data-urlencode "value=$AADCLIENTSECRET" -X POST "https://$SQHOSTNAME/api/settings/set?key=sonar.auth.aad.clientSecret.secured"
# curl -s -o /dev/null -u $SQTOKEN: -d "" -X POST "https://$SQHOSTNAME/api/settings/set?key=sonar.auth.aad.tenantId&value=$AADTENANTID"
# curl -s -o /dev/null -u $SQTOKEN: --data-urlencode "value=Same as Azure AD login" -X POST "https://$SQHOSTNAME/api/settings/set?key=sonar.auth.aad.loginStrategy"
# curl -s -o /dev/null -u $SQTOKEN: --data-urlencode "value=https://$SQHOSTNAME" -X POST "https://$SQHOSTNAME/api/settings/set?key=sonar.core.serverBaseURL"
# curl -s -o /dev/null -u $SQTOKEN: -d "" -X POST "https://$SQHOSTNAME/api/settings/set?key=sonar.authenticator.downcase&value=true"
# curl -s -o /dev/null -u $SQTOKEN: -d "" -X POST "https://$SQHOSTNAME/api/settings/set?key=sonar.auth.aad.allowUsersToSignUp&value=false"

trace "Restarting SonarQube"
az webapp restart --ids ${SQWEBAPPID}
sleep 5 && echo "$SQHOSTNAME" | waitFor