#!/bin/bash

trace() {
    echo -e "\n>>> $@ ...\n"
}

error() {
    echo "Error: $@" 1>&2
}

# get the default runner script path to execute first before adding custom stuff
SCRIPT="$(find /docker-runner.d -maxdepth 1 -iname "$(basename "$0")")"

trace "Deleting script extensions"
if [ ! -z "$ComponentResourceGroup" ]; then
	echo "$(az vm list --subscription $ComponentSubscription -g $ComponentResourceGroup --query "[].name" -o tsv)" | while read VMNAME; do

		az vm extension list --subscription $ComponentSubscription -g $ComponentResourceGroup --vm-name $VMNAME
		IDS="$(az vm extension list --subscription $ComponentSubscription -g $ComponentResourceGroup --vm-name $VMNAME --query "[?typePropertiesType == 'CustomScript'].id" -o tsv)"

		echo "- VM: $VMNAME ($IDS)"
		[ ! -z "$IDS" ] && az vm extension delete --ids ${IDS} # delete all custom script extensions so we can rerun out deployment template with failing because of conflicts

	done
fi

# isolate task script execution in sub shell  
( exec "$SCRIPT"; exit $? ) || exit $?