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

trace "Registering package feeds"
curl -s https://packages.microsoft.com/keys/microsoft.asc | apt-key add -
curl -s https://packages.microsoft.com/config/ubuntu/18.04/prod.list >> /etc/apt/sources.list.d/msprod.list

trace "Updating & upgrading packages"
apt-get update && apt-get upgrade -y
snap install core && snap refresh core

trace "Installing Utilities"
ACCEPT_EULA=Y apt-get install -y jq unzip  

trace "Updating hosts file"
sed -i "s/127.0.0.1 localhost/127.0.0.1 localhost $(cat /etc/hostname) $( getVMFQN )/g" /etc/hosts
cat /etc/hosts

trace "Installing Azure CLI"
curl -sL https://aka.ms/InstallAzureCLIDeb | bash

trace "Installing MSSQL Tools"
ACCEPT_EULA=Y apt-get install -y mssql-tools unixodbc-dev

trace "Installing NGINX & CertBot"
ACCEPT_EULA=Y apt-get install -y default-jre nginx 
snap install --classic certbot 
[ ! -L /usr/bin/certbot ] && ln -s /snap/bin/certbot /usr/bin/certbot
echo "- Creating SSL certificate for $( getVMFQN )"
certbot --nginx --register-unsafely-without-email --agree-tos --noninteractive -d "$( getVMFQN )"

trace "Installing SonarQube"
[[ ! -d /opt/sonarqube || -z "$(ls -A /opt/sonarqube)" ]] && {
	SONARARCHIVE="$(find $PWD -maxdepth 1 -iname "sonarqube-$SONARVERSION.zip")"
	[ -z "$SONARARCHIVE" ] && {
		SONARARCHIVE="./sonarqube-$SONARVERSION.zip" 
		curl -s https://binaries.sonarsource.com/Distribution/sonarqube/sonarqube-$SONARVERSION.zip --output $SONARARCHIVE
	}
	unzip $SONARARCHIVE && mv ./sonarqube-$SONARVERSION /opt/sonarqube && chown -R sonar:sonar /opt/sonarqube
}

trace "Creating SonarQube User"
[ ! $(getent group $SONARUSERNAME) ] && { 
	echo "- Creating group: $SONARUSERNAME"
	groupadd $SONARUSERNAME 
}
[ ! `id -u $SONARUSERNAME 2>/dev/null || echo -1` -ge 0 ] && { 
	echo "- Creating user: $SONARUSERNAME" 
	useradd -c "Sonar System User" -d /opt/sonarqube -g $SONARUSERNAME -s /bin/bash $SONARUSERNAME 
}
sed -i s/\#RUN_AS_USER=/RUN_AS_USER=$SONARUSERNAME/g /opt/sonarqube/bin/linux-x86-$ARCHITECTURE_BIT/sonar.sh 

trace "Configuring SonarQube (data disk)"
[ -d "/datadrive" ] && cat /etc/fstab || {
	printf "n\np\n1\n\n\nw\n" | fdisk /dev/sdc
	mkfs -t ext4 /dev/sdc1
	mkdir /datadrive
	mount /dev/sdc1 /datadrive
	tee -a /etc/fstab << END 
UUID=$(blkid /dev/sdc1 -s UUID -o value)   /datadrive   ext4   defaults,nofail   1   2
END
} 

trace "Configuring SonarQube (data directories)"
mkdir -p /datadrive/data && chown sonar:sonar /datadrive/data
mkdir -p /datadrive/temp && chown sonar:sonar /datadrive/temp
find /datadrive -maxdepth 1 -group sonar

trace "Configuring SonarQube (database)"
readonly SQLCMD_HOME=/opt/mssql-tools/bin
$SQLCMD_HOME/sqlcmd -S tcp:$PARAM_DATABASESERVER,1433 -d master -U $PARAM_ADMINUSERNAME -P $PARAM_ADMINPASSWORD -Q "CREATE LOGIN $SONARUSERNAME WITH PASSWORD='$SONARPASSWORD';" >/dev/null
$SQLCMD_HOME/sqlcmd -S tcp:$PARAM_DATABASESERVER,1433 -d $PARAM_DATABASENAME -U $PARAM_ADMINUSERNAME -P $PARAM_ADMINPASSWORD -Q "CREATE USER $SONARUSERNAME FROM LOGIN $SONARUSERNAME; exec sp_addrolemember 'db_owner', '$SONARUSERNAME';" >/dev/null

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
timeout=$(($(date +%s)+300)) # now plus 5 minutes
while [ "$timeout" -ge "$(date +%s)" ]; do
	status="$( curl -s http://localhost:9000/api/system/status | jq --raw-output '.status' )"
	[ "$status" == "UP" ] && break || { echo "- $status"; sleep 5; }
done

# enable SonarQube service
trace "Enabling SonarQube service"
systemctl enable sonar