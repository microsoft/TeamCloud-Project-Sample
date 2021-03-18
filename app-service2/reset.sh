#!/bin/bash

trace() {
    echo -e "\n>>> $@ ...\n"
}

function ResolveScript () {

    # check if the task file exists in the process dir
    SCRIPT="$(find $PWD -maxdepth 1 -iname "$1")"

    if [[ -z "$SCRIPT" ]]; then 
        # check if the task file exists in the default runner dir
        SCRIPT="$(find /docker-runner.d -maxdepth 1 -iname "$1")"
    fi

    echo "$SCRIPT"
}

readonly ComponentState="/mnt/storage/component.tfstate"
readonly ComponentPlan="/mnt/temporary/component.tfplan"
readonly ComponentVars="/mnt/temporary/component.tfvars.json"

echo "$ComponentTemplateParameters" > $ComponentVars



if [ -f "$ComponentState" ]; then

	trace "Terraform Info"
	terraform -version

	trace "Initializing Terraform"
	terraform init -no-color

	trace "Tainting Terraform State"

	while read res; do
		echo "- resource $res"
	done < <(terraform state list -state=$ComponentState)

else

	# isolate task script execution in sub shell  
	( exec "$( ResolveScript 'delete.sh' )"; exit $? ) && ( exec "$( ResolveScript 'create.sh' )"; exit $? ) || exit $?

fi





# tail -f /dev/null
