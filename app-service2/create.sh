#!/bin/bash

trace() {
    echo -e "\n>>> $@ ...\n"
}

readonly ComponentState="/mnt/storage/component.tfstate"

trace "Terraform Info"
terraform -version

trace "Initializing Terraform"
terraform init -no-color

trace "Applying Terraform Plan"
terraform apply -no-color -refresh=true -auto-approve -lock=true -state=$ComponentState -var "resourceGroupName=$ComponentResourceGroup"

# tail -f /dev/null
