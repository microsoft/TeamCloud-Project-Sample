#!/bin/bash

# elevate the script if not executed as root
[ "$UID" != "0" ] && exec sudo -E "$0" ${1+"$@"}

DIR=$(dirname $(readlink -f $0))

# tee stdout and stderr into log file
exec &> >(tee -a "$DIR/azuredeploy.log")

readonly PARAM_DATABASEPASSWORD="$( echo "${1}" | base64 --decode )"
readonly PARAM_DATABASESERVER="$( echo "${2}" | base64 --decode )"
readonly PARAM_DATABASENAME="$( echo "${3}" | base64 --decode )"
readonly PARAM_AADTENANTID="$( echo "${4}" | base64 --decode )"
readonly PARAM_AADCLIENTID="$( echo "${5}" | base64 --decode )"
readonly PARAM_AADCLIENTSECRET="$( echo "${6}" | base64 --decode )"

readonly ARCHITECTURE="x64"
readonly ARCHITECTURE_BIT="64"

readonly SQ_VERSION="7.9.5"
readonly SQ_DATABASE_USERNAME="sonarqube"
readonly SQ_DATABASE_PASSWORD=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 32 | head -n 1)
readonly SQ_SCANNER_USERNAME="scanner"
readonly SQ_SCANNER_PASSWORD=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 32 | head -n 1)

trace() {
    echo -e "\n>>> $(date '+%F %T'): $@"
	echo -e "=========================================================================================================\n"
}

error() {
    echo "Error: $@" 1>&2
}

getVMName() {
	curl -s -H Metadata:true "http://169.254.169.254/metadata/instance/compute?api-version=2020-10-01" | jq --raw-output '.name'
}

getVMLocation() {
	curl -s -H Metadata:true "http://169.254.169.254/metadata/instance/compute?api-version=2020-10-01" | jq --raw-output '.location'
}

getVMFQN() {
	curl -s -H Metadata:true "http://169.254.169.254/metadata/instance/compute?api-version=2020-10-01" | jq --raw-output '"\(.name).\(.location).cloudapp.azure.com"'
}

getSQToken() {
	local token=$( cat /tmp/sonarqube_tkn_$$ 2>/dev/null )
	[ -z "$token" ] && {
		token=$(curl -s -u admin:admin -X POST "http://localhost:9000/api/user_tokens/generate?name=$(uuidgen)" | jq --raw-output '.token')
		[ ! -z "$token" ] && curl -s -u $token: --data-urlencode "password=$PARAM_DATABASEPASSWORD" -X POST "http://localhost:9000/api/users/change_password?login=admin&previousPassword=admin"
	}
	curl -s -u admin:$PARAM_DATABASEPASSWORD -X POST "http://localhost:9000/api/user_tokens/generate?name=$(uuidgen)" | jq --raw-output '.token' | tee /tmp/sonarqube_tkn_$$
}

# =========================================================================================================
# Updating host system
# The system need some core settings changed to enable SonarQube (ElasticSearch)
# =========================================================================================================

trace "Updating host system"
sysctl -w vm.max_map_count=262144 > /dev/null
sysctl --system

# =========================================================================================================
# Installing prerequisites and core services
# - Register some custom package feeds
# - Update & upgrade current packages
# - Install utilities, NGINX, and SonarQube
# - Connecting Azure to enable resource interaction
# =========================================================================================================

trace "Registering package feeds"
curl -s https://packages.microsoft.com/keys/microsoft.asc | apt-key add -
curl -s https://packages.microsoft.com/config/ubuntu/18.04/prod.list >> /etc/apt/sources.list.d/msprod.list

trace "Updating & upgrading packages"
apt-get update && apt-get upgrade -y
snap install core && snap refresh core

trace "Installing Core Utilities"
ACCEPT_EULA=Y apt-get install -y jq unzip mssql-tools unixodbc-dev

trace "Installing NGINX & CertBot"
ACCEPT_EULA=Y apt-get install -y default-jre nginx 
snap install --classic certbot 
[ ! -L /usr/bin/certbot ] && ln -s /snap/bin/certbot /usr/bin/certbot
certbot --nginx --register-unsafely-without-email --agree-tos --noninteractive -d "$( getVMFQN )"

trace "Installing SonarQube"
[[ ! -d /opt/sonarqube || -z "$(ls -A /opt/sonarqube)" ]] && {
	SQ_ARCHIVE="$(find $PWD -maxdepth 1 -iname "sonarqube-$SQ_VERSION.zip")"
	[ -z "$SQ_ARCHIVE" ] && {
		SQ_ARCHIVE="./sonarqube-$SQ_VERSION.zip" 
		curl -s https://binaries.sonarsource.com/Distribution/sonarqube/sonarqube-$SQ_VERSION.zip --output $SQ_ARCHIVE
	}
	unzip $SQ_ARCHIVE && mv ./sonarqube-$SQ_VERSION /opt/sonarqube
}

trace "Updating host names"
sed -i "s/127.0.0.1 localhost/127.0.0.1 localhost $(cat /etc/hostname) $( getVMFQN )/g" /etc/hosts
cat /etc/hosts

# =========================================================================================================
# Configuring SonarQube (web)
# - Configure NGINX to forward traffic to SonarQube
# - Restart NGINX to activate configuration
# =========================================================================================================

trace "Configuring SonarQube (web)"
tee /etc/nginx/sites-available/default << END
upstream sonarqube {
    server 127.0.0.1:9000 fail_timeout=0;
}

server {
    if (\$host = $( getVMFQN )) {
        return 301 https://\$host\$request_uri;
    } # managed by Certbot

    listen 80 ;
    listen [::]:80 ;

    server_name $( getVMFQN );
    return 404; # managed by Certbot
}

server {
    listen [::]:443 ssl ipv6only=on; # managed by Certbot
    listen 443 ssl; # managed by Certbot

    server_name $( getVMFQN );

    ssl_certificate /etc/letsencrypt/live/$( getVMFQN )/fullchain.pem; # managed by Certbot
    ssl_certificate_key /etc/letsencrypt/live/$( getVMFQN )/privkey.pem; # managed by Certbot

    include /etc/letsencrypt/options-ssl-nginx.conf; # managed by Certbot
    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem; # managed by Certbot

    location / {
        proxy_set_header        Host \$host;
        proxy_set_header        X-Real-IP \$remote_addr;
        proxy_set_header        X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header        X-Forwarded-Proto \$scheme;
        proxy_redirect          http://$( getVMFQN ) https://$( getVMFQN );
        proxy_pass              http://sonarqube;
    }
}
END
nginx -s reload

# =========================================================================================================
# Configuring SonarQube (identity)
# - Create service user & group
# - Grant ownership permissions and set RunAsUser
# =========================================================================================================

trace "Configuring SonarQube (identity)"
[ ! $(getent group $SQ_DATABASE_USERNAME) ] && { 
	echo "- Creating group: $SQ_DATABASE_USERNAME"
	groupadd $SQ_DATABASE_USERNAME 
}
[ ! `id -u $SQ_DATABASE_USERNAME 2>/dev/null || echo -1` -ge 0 ] && { 
	echo "- Creating user: $SQ_DATABASE_USERNAME" 
	useradd -c "Sonar System User" -d /opt/sonarqube -g $SQ_DATABASE_USERNAME -s /bin/bash $SQ_DATABASE_USERNAME 
}

echo "- Granting $SQ_DATABASE_USERNAME SonarQube ownership"
chown -R $SQ_DATABASE_USERNAME:$SQ_DATABASE_USERNAME /opt/sonarqube

echo "- Setting $SQ_DATABASE_USERNAME as RunAsUser"
sed -i s/\#RUN_AS_USER=/RUN_AS_USER=$SQ_DATABASE_USERNAME/g /opt/sonarqube/bin/linux-x86-$ARCHITECTURE_BIT/sonar.sh 

# =========================================================================================================
# Configuring SonarQube (storage)
# - Mount storage drive and initialize volumne
# - Create folder structure and grant access
# =========================================================================================================

trace "Configuring SonarQube (storage)"

[ -d "/datadrive" ] && cat /etc/fstab || {
	printf "n\np\n1\n\n\nw\n" | fdisk /dev/sdc
	mkfs -t ext4 /dev/sdc1
	mkdir /datadrive
	mount /dev/sdc1 /datadrive
	tee -a /etc/fstab << END 
UUID=$(blkid /dev/sdc1 -s UUID -o value)   /datadrive   ext4   defaults,nofail   1   2
END
} 

mkdir -p /datadrive/data && chown $SQ_DATABASE_USERNAME:$SQ_DATABASE_USERNAME /datadrive/data
mkdir -p /datadrive/temp && chown $SQ_DATABASE_USERNAME:$SQ_DATABASE_USERNAME /datadrive/temp

find /datadrive -maxdepth 1 -group $SQ_DATABASE_USERNAME

# =========================================================================================================
# Configuring SonarQube (database)
# - Grant user database ownership
# =========================================================================================================

trace "Configuring SonarQube (database)"
readonly SQLCMD_HOME=/opt/mssql-tools/bin

$SQLCMD_HOME/sqlcmd -S tcp:$PARAM_DATABASESERVER,1433 -d master -U sonarqube -P $PARAM_DATABASEPASSWORD -Q "CREATE LOGIN $SQ_DATABASE_USERNAME WITH PASSWORD='$SQ_DATABASE_PASSWORD';" >/dev/null
$SQLCMD_HOME/sqlcmd -S tcp:$PARAM_DATABASESERVER,1433 -d $PARAM_DATABASENAME -U sonarqube -P $PARAM_DATABASEPASSWORD -Q "CREATE USER $SQ_DATABASE_USERNAME FROM LOGIN $SQ_DATABASE_USERNAME; exec sp_addrolemember 'db_owner', '$SQ_DATABASE_USERNAME';" >/dev/null

# =========================================================================================================
# Configuring SonarQube (properties)
# - Update SonarQube configuration (database & storage)
# =========================================================================================================

trace "Configuring SonarQube (properties)"
[ -z "$(grep 'CUSTOM CONFIGURATION' /opt/sonarqube/conf/sonar.properties)" ] && tee -a /opt/sonarqube/conf/sonar.properties << END

#--------------------------------------------------------------------------------------------------
# CUSTOM CONFIGURATION

sonar.jdbc.username=$SQ_DATABASE_USERNAME
sonar.jdbc.password=$SQ_DATABASE_PASSWORD
sonar.jdbc.url=jdbc:sqlserver://$PARAM_DATABASESERVER;databaseName=$PARAM_DATABASENAME;encrypt=true;trustServerCertificate=false;hostNameInCertificate=*.database.windows.net;loginTimeout=30;

sonar.path.data=/datadrive/data
sonar.path.temp=/datadrive/temp

END

# =========================================================================================================
# Configuring SonarQube (service)
# - Configure systemd for SonarQube
# =========================================================================================================

trace "Configuring SonarQube (service)"
tee /etc/systemd/system/sonarqube.service << END
[Unit]
Description=SonarQube service
After=syslog.target network.target

[Service]
Type=forking

ExecStart=/opt/sonarqube/bin/linux-x86-$ARCHITECTURE_BIT/sonar.sh start
ExecStop=/opt/sonarqube/bin/linux-x86-$ARCHITECTURE_BIT/sonar.sh stop

User=$SQ_DATABASE_USERNAME
Group=$SQ_DATABASE_USERNAME
Restart=always

[Install]
WantedBy=multi-user.target
END

echo "- Enabling SonarQube Service"
systemctl enable sonarqube

# =========================================================================================================
# Intializing SonarQube
# - Force database initialization by starting SonarQube in console mode
# - Enable SonarQube to run as service
# =========================================================================================================

trace "Intializing SonarQube"

echo "- Starting SonarQube Console" # use a subshell to hide output
( /opt/sonarqube/bin/linux-x86-$ARCHITECTURE_BIT/sonar.sh console & ) > /dev/null

# initialization need to be secured by a timeout
timeout=$(($(date +%s)+300)) # now plus 5 minutes

echo -n "  ."; while [ "$timeout" -ge "$(date +%s)" ]; do
	status="$( curl -s http://localhost:9000/api/system/status | jq --raw-output '.status' )"
	[ "$status" == "UP" ] && { echo ". done"; break; } || { echo -n "."; sleep 5; }
done; [ "$status" != "UP" ] && { echo ". failed"; exit 1; }


# =========================================================================================================
# Configuring SonarQube (authentication)
# =========================================================================================================

trace "Configuring SonarQube (authentication)"

# OIC_AUTHORIZATION_ENDPOINT=$(curl -s "https://login.microsoftonline.com/$PARAM_OIC_TENANT_ID/v2.0/.well-known/openid-configuration" | jq --raw-output '.authorization_endpoint')
# OIC_TOKEN_ENDPOINT=$(curl -s "https://login.microsoftonline.com/$PARAM_OIC_TENANT_ID/v2.0/.well-known/openid-configuration" | jq --raw-output '.token_endpoint')

echo "- Enforce authentication"
curl -s -o /dev/null -u $( getSQToken ): -d "" -X POST "http://localhost:9000/api/settings/set?key=sonar.forceAuthentication&value=true"

[[ ! =z "$PARAM_AADTENANTID" && ! =z "$PARAM_AADCLIENTID" && ! =z "$PARAM_AADCLIENTSECRET" ]] && {

	echo "- Installing authentication plugin"
	curl -s -o /dev/null -u $( getSQToken ): -d "" -X POST "http://localhost:9000/api/plugins/install?key=authaad"

	echo "- Configuring authentication plugin"
	curl -s -o /dev/null -u $( getSQToken ): -d "" -X POST "http://localhost:9000/api/settings/set?key=sonar.auth.aad.enabled&value=true"
	curl -s -o /dev/null -u $( getSQToken ): -d "" -X POST "http://localhost:9000/api/settings/set?key=sonar.auth.aad.clientId.secured&value=$AADCLIENTID"
	curl -s -o /dev/null -u $( getSQToken ): --data-urlencode "value=$AADCLIENTSECRET" -X POST "http://localhost:9000/api/settings/set?key=sonar.auth.aad.clientSecret.secured"
	curl -s -o /dev/null -u $( getSQToken ): -d "" -X POST "http://localhost:9000/api/settings/set?key=sonar.auth.aad.tenantId&value=$AADTENANTID"
	curl -s -o /dev/null -u $( getSQToken ): --data-urlencode "value=Same as Azure AD login" -X POST "http://localhost:9000/api/settings/set?key=sonar.auth.aad.loginStrategy"
	curl -s -o /dev/null -u $( getSQToken ): --data-urlencode "value=http://localhost:9000" -X POST "http://localhost:9000/api/settings/set?key=sonar.core.serverBaseURL"
	curl -s -o /dev/null -u $( getSQToken ): -d "" -X POST "http://localhost:9000/api/settings/set?key=sonar.authenticator.downcase&value=true"
	curl -s -o /dev/null -u $( getSQToken ): -d "" -X POST "http://localhost:9000/api/settings/set?key=sonar.auth.aad.allowUsersToSignUp&value=false"

	echo "- Restarting SonarQube"
	/opt/sonarqube/bin/linux-x86-$ARCHITECTURE_BIT/sonar.sh restart
}

# =========================================================================================================
# Configuring SonarQube (users)
# =========================================================================================================

trace "Configuring SonarQube (users)"

echo "- Initializing system user: scanner"
curl -s -o /dev/null -u $( getSQToken ): --data-urlencode "name=$SQ_SCANNER_USERNAME" -X POST "http://localhost:9000/api/users/create?login=$SQ_SCANNER_USERNAME&password=$SQ_SCANNER_PASSWORD"
curl -s -o /dev/null -u $( getSQToken ): -d "" -X POST "http://localhost:9000/api/permissions/add_user?login=$SQ_SCANNER_USERNAME&permission=scan"
curl -s -o /dev/null -u $( getSQToken ): -d "" -X POST "http://localhost:9000/api/permissions/add_user?login=$SQ_SCANNER_USERNAME&permission=provisioning"

