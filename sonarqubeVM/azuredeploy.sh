#!/bin/bash

# elevate the script if not executed as root
[ "$UID" != "0" ] && exec sudo -E "$0" ${1+"$@"}

DIR=$(dirname $(readlink -f $0))
LOG="$DIR/azuredeploy.log"

touch $LOG     # ensure the log file exists
exec 1>$LOG    # forward stdout to log file
exec 2>&1      # redirect stderr to stdout

PARAM_ADMINUSERNAME="$( echo "${1}" | base64 --decode )"
PARAM_ADMINPASSWORD="$( echo "${2}" | base64 --decode )"
PARAM_CONNECTIONSTRING="$( echo "${3}" | base64 --decode )"

trace() {
    echo -e "\n>>> $(date '+%F %T'): $@\n"
}

# trace "Fetching OIC metadata"
# OIC_AUTHORIZATION_ENDPOINT=$(curl -s "https://login.microsoftonline.com/$PARAM_OIC_TENANT_ID/v2.0/.well-known/openid-configuration" | jq --raw-output '.authorization_endpoint')
# OIC_TOKEN_ENDPOINT=$(curl -s "https://login.microsoftonline.com/$PARAM_OIC_TENANT_ID/v2.0/.well-known/openid-configuration" | jq --raw-output '.token_endpoint')

trace "Fetching VM metadata"
VM_NAME=$(curl -s -H Metadata:true "http://169.254.169.254/metadata/instance/compute/name?api-version=2017-08-01&format=text")
VM_LOCATION=$(curl -s -H Metadata:true "http://169.254.169.254/metadata/instance/compute/location?api-version=2017-08-01&format=text")
VM_FQN=$(echo $(curl -s -H Metadata:true "http://169.254.169.254/metadata/instance/compute/tags?api-version=2017-08-01&format=text") | grep -Po 'ServiceUrl:(?:(?!;).)*' | grep -Po '(?<=:\/\/).*')

trace "Updating hosts file"
sed -i "s/127.0.0.1 localhost/127.0.0.1 localhost $(sudo cat /etc/hostname) $VM_FQN/g" /etc/hosts

trace "Updating & upgrading packages"
apt-get update && apt-get upgrade -y

trace "Installing NGINX"
ACCEPT_EULA=Y apt-get install -y azure-cli nginx unzip jq software-properties-common python-certbot-nginx
certbot --nginx --register-unsafely-without-email --agree-tos -d $VM_FQN

trace "Initialize data disk"
[ -d "/datadrive" ] || {
	printf "n\np\n1\n\n\nw\n" | fdisk /dev/sdc
	mkfs -t ext4 /dev/sdc1
	mkdir /datadrive
	mount /dev/sdc1 /datadrive
	tee -a /etc/fstab << END 
UUID=$(blkid /dev/sdc1 -s UUID -o value)   /datadrive   ext4   defaults,nofail   1   2
END
}

trace "Create data disk folders"
[ -d "/datadrive/data" ] || mkdir /datadrive/data 
[ -d "/datadrive/temp" ] || mkdir /datadrive/temp
