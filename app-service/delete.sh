#!/bin/bash

trace() {
    echo -e "\n>>> $@ ...\n"
}

echo "============================================================"
echo "="
echo "= DELETE"
echo "="
echo "============================================================"

readonly ComponentStateFile="/mnt/storage/terraform.tfstate"

ComponentTemplateFile="$(echo "$ComponentTemplateFolder/azuredeploy.tf" | sed 's/^file:\/\///g')"
ComponentTemplatePlan="$(echo "$ComponentTemplateFile.plan")"
ComponentTemplateJson="$(cat $ComponentTemplateFile | hcl2json)"

# echo "$ComponentTemplateJson"

trace "Initializing Terraform"
terraform init -no-color

trace "Updating Terraform Plan"
terraform plan -no-color -refresh=true -lock=true -destroy -state=$ComponentStateFile -out=$ComponentTemplatePlan -var "ComponentResourceGroupName=$ComponentResourceGroup"

trace "Applying Terraform Plan"
terraform apply -no-color -auto-approve -lock=true -state=$ComponentStateFile $ComponentTemplatePlan

# tail -f /dev/null
