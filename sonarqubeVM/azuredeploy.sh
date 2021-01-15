#!/bin/bash

# elevate the script if not executed as root
[ "$UID" != "0" ] && exec sudo -E "$0" ${1+"$@"}

DIR=$(dirname $(readlink -f $0))

# tee stdout and stderr into log file
exec &> >(tee -a "$DIR/azuredeploy.log")

readonly PARAM_ADMINUSERNAME="$( echo "${1}" | base64 --decode )"
readonly PARAM_ADMINPASSWORD="$( echo "${2}" | base64 --decode )"
readonly PARAM_DATABASESERVER="$( echo "${3}" | base64 --decode )"
readonly PARAM_DATABASENAME="$( echo "${4}" | base64 --decode )"
readonly PARAM_CONNECTIONSTRING="$( echo "${5}" | base64 --decode )"

readonly ARCHITECTURE="x64"
readonly ARCHITECTURE_BIT="64"

# OIC_AUTHORIZATION_ENDPOINT=$(curl -s "https://login.microsoftonline.com/$PARAM_OIC_TENANT_ID/v2.0/.well-known/openid-configuration" | jq --raw-output '.authorization_endpoint')
# OIC_TOKEN_ENDPOINT=$(curl -s "https://login.microsoftonline.com/$PARAM_OIC_TENANT_ID/v2.0/.well-known/openid-configuration" | jq --raw-output '.token_endpoint')

readonly SONARUSERNAME="sonar"
readonly SONARPASSWORD=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 32 | head -n 1)
readonly SONARVERSION="7.9.5"

trace() {
    echo -e "\n>>> $(date '+%F %T'): $@\n"
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
# =========================================================================================================

trace "Registering package feeds"
curl -s https://packages.microsoft.com/keys/microsoft.asc | apt-key add -
curl -s https://packages.microsoft.com/config/ubuntu/18.04/prod.list >> /etc/apt/sources.list.d/msprod.list

trace "Updating & upgrading packages"
apt-get update && apt-get upgrade -y
snap install core && snap refresh core

trace "Installing Utilities"
ACCEPT_EULA=Y apt-get install -y jq unzip mssql-tools unixodbc-dev

trace "Installing NGINX & CertBot"
ACCEPT_EULA=Y apt-get install -y default-jre nginx 
snap install --classic certbot 
[ ! -L /usr/bin/certbot ] && ln -s /snap/bin/certbot /usr/bin/certbot
certbot --nginx --register-unsafely-without-email --agree-tos --noninteractive -d "$( getVMFQN )"

trace "Installing SonarQube"
[[ ! -d /opt/sonarqube || -z "$(ls -A /opt/sonarqube)" ]] && {
	SONARARCHIVE="$(find $PWD -maxdepth 1 -iname "sonarqube-$SONARVERSION.zip")"
	[ -z "$SONARARCHIVE" ] && {
		SONARARCHIVE="./sonarqube-$SONARVERSION.zip" 
		curl -s https://binaries.sonarsource.com/Distribution/sonarqube/sonarqube-$SONARVERSION.zip --output $SONARARCHIVE
	}
	unzip $SONARARCHIVE && mv ./sonarqube-$SONARVERSION /opt/sonarqube
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
# Configuring SonarQube (user)
# - Create user & group
# - Grant ownership permissions and set RunAsUser
# =========================================================================================================

trace "Configuring SonarQube (user)"
[ ! $(getent group $SONARUSERNAME) ] && { 
	echo "- Creating group: $SONARUSERNAME"
	groupadd $SONARUSERNAME 
}
[ ! `id -u $SONARUSERNAME 2>/dev/null || echo -1` -ge 0 ] && { 
	echo "- Creating user: $SONARUSERNAME" 
	useradd -c "Sonar System User" -d /opt/sonarqube -g $SONARUSERNAME -s /bin/bash $SONARUSERNAME 
}

echo "- Granting $SONARUSERNAME SonarQube ownership"
chown -R sonar:sonar /opt/sonarqube

echo "- Setting $SONARUSERNAME as RunAsUser"
sed -i s/\#RUN_AS_USER=/RUN_AS_USER=$SONARUSERNAME/g /opt/sonarqube/bin/linux-x86-$ARCHITECTURE_BIT/sonar.sh 

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
mkdir -p /datadrive/data && chown sonar:sonar /datadrive/data
mkdir -p /datadrive/temp && chown sonar:sonar /datadrive/temp
find /datadrive -maxdepth 1 -group sonar

# =========================================================================================================
# Configuring SonarQube (database)
# - Grant user database ownership
# =========================================================================================================

trace "Configuring SonarQube (database)"
readonly SQLCMD_HOME=/opt/mssql-tools/bin
$SQLCMD_HOME/sqlcmd -S tcp:$PARAM_DATABASESERVER,1433 -d master -U $PARAM_ADMINUSERNAME -P $PARAM_ADMINPASSWORD -Q "CREATE LOGIN $SONARUSERNAME WITH PASSWORD='$SONARPASSWORD';" >/dev/null
$SQLCMD_HOME/sqlcmd -S tcp:$PARAM_DATABASESERVER,1433 -d $PARAM_DATABASENAME -U $PARAM_ADMINUSERNAME -P $PARAM_ADMINPASSWORD -Q "CREATE USER $SONARUSERNAME FROM LOGIN $SONARUSERNAME; exec sp_addrolemember 'db_owner', '$SONARUSERNAME';" >/dev/null

# =========================================================================================================
# Configuring SonarQube (properties)
# - Update SonarQube configuration (database & storage)
# =========================================================================================================

trace "Configuring SonarQube (properties)"
[ -z "$(grep 'CUSTOM CONFIGURATION' /opt/sonarqube/conf/sonar.properties)" ] && tee -a /opt/sonarqube/conf/sonar.properties << END

#--------------------------------------------------------------------------------------------------
# CUSTOM CONFIGURATION

sonar.jdbc.username=$PARAM_ADMINUSERNAME
sonar.jdbc.password=$PARAM_ADMINPASSWORD
sonar.jdbc.url=$PARAM_CONNECTIONSTRING

sonar.path.data=/datadrive/data
sonar.path.temp=/datadrive/temp

END

# =========================================================================================================
# Configuring SonarQube (service)
# - Configure systemd for SonarQube
# =========================================================================================================

trace "Configuring SonarQube (service)"
tee /etc/systemd/system/sonar.service << END
[Unit]
Description=SonarQube service
After=syslog.target network.target

[Service]
Type=forking

ExecStart=/opt/sonarqube/bin/linux-x86-$ARCHITECTURE_BIT/sonar.sh start
ExecStop=/opt/sonarqube/bin/linux-x86-$ARCHITECTURE_BIT/sonar.sh stop

User=sonar
Group=sonar
Restart=always

[Install]
WantedBy=multi-user.target
END

# =========================================================================================================
# Intializing SonarQube
# - Force database initialization by starting SonarQube in console mode
# - Enable SonarQube to run as service
# =========================================================================================================

trace "Intializing SonarQube"

echo "- Starting SonarQube Console"
/opt/sonarqube/bin/linux-x86-$ARCHITECTURE_BIT/sonar.sh console &

timeout=$(($(date +%s)+300)) # now plus 5 minutes
echo "  ."; while [ "$timeout" -ge "$(date +%s)" ]; do
	status="$( curl -s http://localhost:9000/api/system/status | jq --raw-output '.status' )"
	[ "$status" == "UP" ] && { echo ". done"; break; } || { echo -n "."; sleep 5; }
done;

echo "- Enabling SonarQube Service"
systemctl enable sonar