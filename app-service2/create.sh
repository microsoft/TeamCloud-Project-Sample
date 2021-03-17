#!/bin/bash

trace() {
    echo -e "\n>>> $@ ...\n"
}

echo "============================================================"
echo "="
echo "= CREATE"
echo "="
echo "============================================================"

readonly ComponentState="/mnt/storage/component.tfstate"
readonly ComponentPlan="/mnt/storage/component.tfplan"

rm -f $ComponentPlan # delete any existing plan file

trace "Terraform Info"
terraform -version

trace "Initializing Terraform"
terraform init -no-color

# if [[ (! -z "$ComponentResourceGroup") && (! -f "$ComponentState") ]]; then
# 	ComponentResourceGroupId="$(az group show -n $ComponentResourceGroup --query id -o tsv)"
# 	ComponentResourceGroupLocation="$(az group show -n $ComponentResourceGroup --query location -o tsv)"
# 	while read terraformFile; do
# 		trace "Initializing Terraform ResourceGroups ($terraformFile)"
# 		while read tfrg; do

# 			echo -e "\n- Importing $ComponentResourceGroupId into $tfrg\n"
# 			terraform import -no-color -lock=true -state=$ComponentState -var "resourceGroupName=$ComponentResourceGroup" -var "resourceGroupLocation=$ComponentResourceGroupLocation" $tfrg $ComponentResourceGroupId

# 		done < <(cat $terraformFile | hcl2json | jq --raw-output '.resource.azurerm_resource_group // empty | to_entries [] | "azurerm_resource_group.\(.key)"')
# 		echo "- done."
# 	done < <(find . -maxdepth 1 -type f -name '*.tf')
# fi

trace "Updating Terraform Plan"
terraform plan -no-color -refresh=true -lock=true -state=$ComponentState -out=$ComponentPlan -var "resourceGroupName=$ComponentResourceGroup" -var "resourceGroupLocation=$(az group show -n $ComponentResourceGroup --query location -o tsv)"

trace "Applying Terraform Plan"
terraform apply -no-color -auto-approve -lock=true -state=$ComponentState $ComponentPlan

# tail -f /dev/null
