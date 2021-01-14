#!/bin/bash

trace() {
    echo -e "\n>>> $@ ...\n"
}

error() {
    echo "Error: $@" 1>&2
}

deleteCustomScriptExtensions() {
	local ComponentResourceGroup="$1" 
	echo "$(az vm list --subscription $ComponentSubscription -g $ComponentResourceGroup --query "[].name" -o tsv)" | while read VMNAME; do
		IDS="$(az vm extension list --subscription $ComponentSubscription -g $ComponentResourceGroup --vm-name $VMNAME --query "[?typePropertiesType == 'CustomScript'].id" -o tsv)"
		[ ! -z "$IDS" ] && echo "- $IDS" && az vm extension delete --ids ${IDS} # delete all resolved custom script extensions by their ID
	done && echo ""
}

# get the default runner script path to execute first before adding custom stuff
SCRIPT="$(find /docker-runner.d -maxdepth 1 -iname "$(basename "$0")")"

trace "Deleting script extensions"
if [ -z "$ComponentResourceGroup" ]; then
    echo "$(az group list --query "[].name" -o tsv)" | while read rg; do
        deleteCustomScriptExtensions "$rg"
    done
else
    deleteCustomScriptExtensions "$ComponentResourceGroup"
fi


# isolate task script execution in sub shell  
( exec "$SCRIPT"; exit $? ) || exit $?