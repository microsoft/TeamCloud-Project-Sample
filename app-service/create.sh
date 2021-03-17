#!/bin/bash

trace() {
    echo -e "\n>>> $@ ...\n"
}

echo "============================================================"
echo "="
echo "= CREATE"
echo "="
echo "============================================================"

readonly ComponentStateFile="/mnt/storage/terraform.tfstate"

ComponentTemplateFile="$(echo "$ComponentTemplateFolder/main.tf" | sed 's/^file:\/\///g')"
ComponentTemplatePlan="$(echo "$ComponentTemplateFile.plan")"
ComponentTemplateJson="$(cat $ComponentTemplateFile | hcl2json)"

# echo "$ComponentTemplateJson"

trace "Terraform Info"
terraform -version

trace "Initializing Terraform"
terraform init -no-color

if [ ! -z "$ComponentResourceGroup" && ! -f "$ComponentStateFile" ]; then
	ComponentResourceGroupId=$(az group show -n $ComponentResourceGroup --query id -o tsv)
	while read terraformFile; do
		trace "Initializing Terraform ResourceGroups ($terraformFile)"
		while read rg; do

			echo "- Importing $ComponentResourceGroupId into $rg"
			terraform import -no-color -lock=true -state=$ComponentStateFile $rg $ComponentResourceGroupId -var "resourceGroupName=$ComponentResourceGroup" -var "resourceGroupLocation=$(az group show -n $ComponentResourceGroup --query location -o tsv)"

		done < <(cat $terraformFile | hcl2json | jq --raw-output '.resource.azurerm_resource_group | to_entries [] | "azurerm_resource_group.\(.key)"')
		echo "- done."
	done < <(find . -maxdepth 1 -type f -name '*.tf')
fi

trace "Updating Terraform Plan"
terraform plan -no-color -refresh=true -lock=true -state=$ComponentStateFile -out=$ComponentTemplatePlan -var "resourceGroupName=$ComponentResourceGroup" -var "resourceGroupLocation=$(az group show -n $ComponentResourceGroup --query location -o tsv)"

trace "Applying Terraform Plan"
terraform apply -no-color -auto-approve -lock=true -state=$ComponentStateFile $ComponentTemplatePlan

# tail -f /dev/null
