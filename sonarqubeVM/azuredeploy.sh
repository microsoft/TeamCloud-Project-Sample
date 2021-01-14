#!/bin/bash

# elevate the script if not executed as root
[ "$UID" != "0" ] && exec sudo -E "$0" ${1+"$@"}

DIR=$(dirname $(readlink -f $0))

# tee stdout and stderr into log file
exec &> >(tee -a "$DIR/azuredeploy.log")

PARAM_ADMINUSERNAME="$( echo "${1}" | base64 --decode )"
PARAM_ADMINPASSWORD="$( echo "${2}" | base64 --decode )"
PARAM_CONNECTIONSTRING="$( echo "${3}" | base64 --decode )"

ARCHITECTURE="x64"
ARCHITECTURE_BIT="64"

# OIC_AUTHORIZATION_ENDPOINT=$(curl -s "https://login.microsoftonline.com/$PARAM_OIC_TENANT_ID/v2.0/.well-known/openid-configuration" | jq --raw-output '.authorization_endpoint')
# OIC_TOKEN_ENDPOINT=$(curl -s "https://login.microsoftonline.com/$PARAM_OIC_TENANT_ID/v2.0/.well-known/openid-configuration" | jq --raw-output '.token_endpoint')

VM_NAME=$(curl -s -H Metadata:true "http://169.254.169.254/metadata/instance/compute/name?api-version=2017-08-01&format=text")
VM_LOCATION=$(curl -s -H Metadata:true "http://169.254.169.254/metadata/instance/compute/location?api-version=2017-08-01&format=text")
VM_FQN=$(echo $(curl -s -H Metadata:true "http://169.254.169.254/metadata/instance/compute/tags?api-version=2017-08-01&format=text") | grep -Po 'ServiceUrl:(?:(?!;).)*' | grep -Po '(?<=:\/\/).*')

trace() {
    echo -e "\n>>> $(date '+%F %T'): $@\n"
}

trace "Updating hosts file"
sed -i "s/127.0.0.1 localhost/127.0.0.1 localhost $(cat /etc/hostname) $VM_FQN/g" /etc/hosts
cat /etc/hosts

trace "Updating & upgrading packages"
apt-get update && apt-get upgrade -y
snap install core && snap refresh core

trace "Installing Azure CLI"
curl -sL https://aka.ms/InstallAzureCLIDeb | bash

trace "Installing NGINX & CertBot"
ACCEPT_EULA=Y apt-get install -y nginx 
snap install --classic certbot 
[ ! -L /usr/bin/certbot ] && ln -s /snap/bin/certbot /usr/bin/certbot
certbot --nginx --register-unsafely-without-email --agree-tos -d $VM_FQN

trace "Initialize data disk"
[ -d "/datadrive" ] && cat /etc/fstab || {
	printf "n\np\n1\n\n\nw\n" | fdisk /dev/sdc
	mkfs -t ext4 /dev/sdc1
	mkdir /datadrive
	mount /dev/sdc1 /datadrive
	tee -a /etc/fstab << END 
UUID=$(blkid /dev/sdc1 -s UUID -o value)   /datadrive   ext4   defaults,nofail   1   2
END
} 

trace "Initialize data folders"
[ -d "/datadrive/data" ] || mkdir /datadrive/data 
[ -d "/datadrive/temp" ] || mkdir /datadrive/temp
ls /datadrive

SONARUSERNAME="sonar"
SONARPASSWORD=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 32 | head -n 1)

# trace "Preparing SonarQube database"
# SQLCMD_HOME=/opt/mssql-tools/bin
# $SQLCMD_HOME/sqlcmd -S tcp:$PARAM_DATABASE_SERVER.database.windows.net,1433 -d master -U $PARAM_ADMINUSERNAME -P $PARAM_ADMINPASSWORD -Q "CREATE LOGIN $SONARUSERNAME WITH PASSWORD='$SONARPASSWORD';"
# $SQLCMD_HOME/sqlcmd -S tcp:$PARAM_DATABASE_SERVER.database.windows.net,1433 -d $PARAM_DATABASE_NAME -U $PARAM_ADMINUSERNAME -P $PARAM_ADMINPASSWORD -Q "CREATE USER $SONARUSERNAME FROM LOGIN $SONARUSERNAME; exec sp_addrolemember 'db_owner', '$SONARUSERNAME';"

# configure SonarQube run-as user
trace "Configuring SonarQube (run-as user)"
[ ! $(getent group $SONARUSERNAME) ] && groupadd $SONARUSERNAME
[ ! `id -u $SONARUSERNAME 2>/dev/null || echo -1` -ge 0 ] && useradd -c "Sonar System User" -d /opt/sonarqube -g $SONARUSERNAME -s /bin/bash $SONARUSERNAME
chown -R sonar:sonar /opt/sonarqube
chown sonar:sonar /datadrive/data
chown sonar:sonar /datadrive/temp
sed -i s/\#RUN_AS_USER=/RUN_AS_USER=$SONARUSERNAME/g /opt/sonarqube/bin/linux-x86-$ARCHITECTURE_BIT/sonar.sh 
cat /opt/sonarqube/bin/linux-x86-$ARCHITECTURE_BIT/sonar.sh 

# configure SonarQube settings
trace "Configuring SonarQube (properties)"
tee -a /opt/sonarqube/conf/sonar.properties << END

#--------------------------------------------------------------------------------------------------
# CUSTOM CONFIGURATION

sonar.jdbc.username=$PARAM_ADMINUSERNAME
sonar.jdbc.password=$PARAM_ADMINPASSWORD
sonar.jdbc.url=$PARAM_CONNECTIONSTRING

sonar.path.data=/datadrive/data
sonar.path.temp=/datadrive/temp
END

# configure SonarQube as a service
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

# initalize SonarQube database
trace "Intializing SonarQube database"
/opt/sonarqube/bin/linux-x86-$ARCHITECTURE_BIT/sonar.sh console &

# wait for SonarQube database to be initialized
trace "Waiting for SonarQube database to be initialized"
while [ "$(curl -s http://localhost:9000/api/system/status | jq '.status' | tr -d '"')" != "UP" ]; do
    echo "- status: $(curl -s http://localhost:9000/api/system/status | jq '.status' | tr -d '"')"
    sleep 5
done

# enable SonarQube service
trace "Enabling SonarQube service"
systemctl enable sonar