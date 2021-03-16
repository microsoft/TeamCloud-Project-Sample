#!/bin/bash

trace() {
    echo -e "\n>>> $@ ...\n"
}

readonly ComponentStateFile="/mnt/storage/terraform.tfstate"

ComponentTemplateFile="$(echo "$ComponentTemplateFolder/azuredeploy.tf" | sed 's/^file:\/\///g')"
ComponentTemplateJson="$(cat $ComponentTemplateFile | hcl2json)"

# echo "$ComponentTemplateJson"

trace "Initializing Terraform"
terraform init -no-color

trace "Updating Terraform Plan"
terraform plan -no-color -refresh -state=$ComponentStateFile -var "ComponentResourceGroupName=$ComponentResourceGroup"

trace "Applying Terraform Plan"
terraform apply -no-color -auto-approve -state=$ComponentStateFile -var "ComponentResourceGroupName=$ComponentResourceGroup"

# tail -f /dev/null
