#!/bin/bash

DIR=$(dirname "$0")

trace() {
    echo -e "\n>>> $@ ...\n"
}

VMResourceIds=""

if [ -z "$ComponentResourceGroup" ]; then
    VMResourceIds=$(az vm list --subscription $ComponentSubscription --query "[].id" -o tsv)
else
    VMResourceIds=$(az vm list --subscription $ComponentSubscription -g $ComponentResourceGroup --query "[].id" -o tsv)
fi

if [[ ! -z "$VMResourceIds" ]]; then

    trace "Starting VM resources"
    az vm start --ids ${VMResourceIds}

    echo "${VMResourceIds}" | while read id; do 
        name=$(az resource show --id $id --query "name" -o tsv)
        echo "- $name"
    done
fi
