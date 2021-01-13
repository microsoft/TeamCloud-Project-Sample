#!/bin/bash

DIR=$(basename $0)
LOG="$DIR\azuredeploy.log"

touch $LOG     # ensure the log file exists
exec 1>$LOG    # forward stdout to log file
exec 2>&1      # redirect stderr to stdout

PARAM_ADMINUSERNAME="$( echo "${1}" | base64 --decode )"
PARAM_ADMINPASSWORD="$( echo "${2}" | base64 --decode )"
PARAM_CONNECTIONSTRING="$( echo "${3}" | base64 --decode )"

trace() {
    echo -e "\n>>> $(date '+%F %T.%N'): $@\n"
}

trace "Fetching OIC metadata"
OIC_AUTHORIZATION_ENDPOINT=$(curl -s "https://login.microsoftonline.com/$PARAM_OIC_TENANT_ID/v2.0/.well-known/openid-configuration" | jq --raw-output '.authorization_endpoint')
OIC_TOKEN_ENDPOINT=$(curl -s "https://login.microsoftonline.com/$PARAM_OIC_TENANT_ID/v2.0/.well-known/openid-configuration" | jq --raw-output '.token_endpoint')

trace "Fetching VM metadata"
VM_NAME=$(curl -s -H Metadata:true "http://169.254.169.254/metadata/instance/compute/name?api-version=2017-08-01&format=text")
VM_LOCATION=$(curl -s -H Metadata:true "http://169.254.169.254/metadata/instance/compute/location?api-version=2017-08-01&format=text")
VM_FQN=$(echo $(curl -s -H Metadata:true "http://169.254.169.254/metadata/instance/compute/tags?api-version=2017-08-01&format=text") | grep -Po 'ServiceUrl:(?:(?!;).)*' | grep -Po '(?<=:\/\/).*')

trace "Updating hosts file"
sudo sed -i "s/127.0.0.1 localhost/127.0.0.1 localhost $(sudo cat /etc/hostname) $VM_FQN/g" /etc/hosts

trace "Updating & upgrading packages"
sudo apt-get update && sudo apt-get upgrade -y

trace "Installing NGINX"
sudo ACCEPT_EULA=Y apt-get install -y azure-cli nginx unzip jq software-properties-common python-certbot-nginx
sudo certbot --nginx --register-unsafely-without-email --agree-tos -d $VM_FQN

trace "Initialize data disk"
printf "n\np\n1\n\n\nw\n" | sudo fdisk /dev/sdc
sudo mkfs -t ext4 /dev/sdc1
sudo mkdir /datadrive
sudo mount /dev/sdc1 /datadrive
sudo tee -a /etc/fstab << END 
UUID=$(sudo blkid /dev/sdc1 -s UUID -o value)   /datadrive   ext4   defaults,nofail   1   2
END

trace "Create data disk folders"
sudo mkdir /datadrive/data
sudo mkdir /datadrive/temp