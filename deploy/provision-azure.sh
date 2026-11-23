#!/usr/bin/env bash
# One-time setup of the hosted InterviewCheck web workspace on Azure, plus the GitHub
# settings the deploy workflow needs. Run from the repository root on a machine signed in
# with `az login` (subscription owner) and `gh auth login` (repo admin).
#
# Creates, in one resource group:
#   - a small Ubuntu VM (Docker + Caddy, data on the VM's OS disk, no SSH port open)
#   - an Azure Container Registry the workflow pushes images to
#   - a storage account for nightly database backups (kept 30 days)
#   - an Entra app that GitHub Actions signs in as (OIDC, no stored password)
# Then writes /srv/interviewcheck/app.env on the VM (secrets are generated there).
#
# Required: OPERATOR_EMAIL (the one account allowed to sign in to this deployment).
set -euo pipefail

: "${OPERATOR_EMAIL:?set OPERATOR_EMAIL}"
REPO=${REPO:-bogdang40/InterviewCheck}
LOCATION=${LOCATION:-eastus2}
RG=${RG:-interviewcheck-rg}
VM=${VM:-interviewcheck-vm}
VM_SIZE=${VM_SIZE:-Standard_B1ms}
SUFFIX=${SUFFIX:-$(openssl rand -hex 3)}
ACR=${ACR:-interviewcheck$SUFFIX}
BACKUP_ACCOUNT=${BACKUP_ACCOUNT:-icbackup$SUFFIX}
DNS_LABEL=${DNS_LABEL:-interviewcheck-$SUFFIX}
KEY_DIR=${KEY_DIR:-$HOME/.interviewcheck-web}

SUB=$(az account show --query id -o tsv)
TENANT=$(az account show --query tenantId -o tsv)
echo "Subscription $SUB, suffix $SUFFIX"

az group create -n "$RG" -l "$LOCATION" -o none

# Registry for images (Basic tier).
az acr create -g "$RG" -n "$ACR" --sku Basic --admin-enabled false -o none
ACR_ID=$(az acr show -n "$ACR" --query id -o tsv)

# Backups: private blob container, deleted after 30 days.
az storage account create -g "$RG" -n "$BACKUP_ACCOUNT" -l "$LOCATION" --sku Standard_LRS --kind StorageV2 \
  --min-tls-version TLS1_2 --allow-blob-public-access false -o none
STORAGE_ID=$(az storage account show -g "$RG" -n "$BACKUP_ACCOUNT" --query id -o tsv)
az storage container create --account-name "$BACKUP_ACCOUNT" -n backups --auth-mode key -o none
az storage account management-policy create -g "$RG" --account-name "$BACKUP_ACCOUNT" --policy '{
  "rules": [{"enabled": true, "name": "expire-backups", "type": "Lifecycle",
    "definition": {"actions": {"baseBlob": {"delete": {"daysAfterModificationGreaterThan": 30}}},
                   "filters": {"blobTypes": ["blockBlob"], "prefixMatch": ["backups/"]}}}]}' -o none

# Emergency SSH key (the SSH port stays closed; open it temporarily if ever needed).
mkdir -p "$KEY_DIR" && chmod 700 "$KEY_DIR"
[ -f "$KEY_DIR/vm_ed25519" ] || ssh-keygen -q -t ed25519 -N "" -C interviewcheck-vm -f "$KEY_DIR/vm_ed25519"

az vm create -g "$RG" -n "$VM" -l "$LOCATION" --image Ubuntu2404 --size "$VM_SIZE" \
  --admin-username azureuser --ssh-key-values "$KEY_DIR/vm_ed25519.pub" \
  --public-ip-sku Standard --public-ip-address-dns-name "$DNS_LABEL" \
  --nsg-rule NONE --os-disk-size-gb 32 --storage-sku StandardSSD_LRS \
  --assign-identity '[system]' --custom-data deploy/cloud-init.yaml -o none
NSG=$(az network nsg list -g "$RG" --query "[0].name" -o tsv)
az network nsg rule create -g "$RG" --nsg-name "$NSG" -n allow-https --priority 1000 \
  --access Allow --protocol '*' --direction Inbound --destination-port-ranges 80 443 -o none
SITE_ADDRESS=$(az network public-ip list -g "$RG" --query "[0].dnsSettings.fqdn" -o tsv)
VM_ID=$(az vm show -g "$RG" -n "$VM" --query id -o tsv)
VM_PRINCIPAL=$(az vm show -g "$RG" -n "$VM" --query identity.principalId -o tsv)
az role assignment create --assignee-object-id "$VM_PRINCIPAL" --assignee-principal-type ServicePrincipal \
  --role AcrPull --scope "$ACR_ID" -o none
az role assignment create --assignee-object-id "$VM_PRINCIPAL" --assignee-principal-type ServicePrincipal \
  --role "Storage Blob Data Contributor" --scope "$STORAGE_ID" -o none

# GitHub Actions identity: may push images and run commands on this VM only.
APP_ID=$(az ad app create --display-name "InterviewCheck GitHub deploy" --query appId -o tsv)
SP_ID=$(az ad sp create --id "$APP_ID" --query id -o tsv)
# GitHub may present either subject format: the classic owner/repo name, or the newer one with
# immutable IDs (repo:owner@ownerId/repo@repoId:...). This repository uses the newer one; register both.
OWNER_ID=$(gh api "repos/$REPO" --jq .owner.id)
REPO_ID=$(gh api "repos/$REPO" --jq .id)
IMMUTABLE="repo:${REPO%%/*}@$OWNER_ID/${REPO#*/}@$REPO_ID"
for pair in "github-production=repo:$REPO" "github-production-immutable=$IMMUTABLE"; do
  az ad app federated-credential create --id "$APP_ID" --parameters "{
    \"name\": \"${pair%%=*}\", \"issuer\": \"https://token.actions.githubusercontent.com\",
    \"subject\": \"${pair#*=}:environment:production\", \"audiences\": [\"api://AzureADTokenExchange\"]}" -o none
done
az role assignment create --assignee-object-id "$SP_ID" --assignee-principal-type ServicePrincipal \
  --role AcrPush --scope "$ACR_ID" -o none
az role assignment create --assignee-object-id "$SP_ID" --assignee-principal-type ServicePrincipal \
  --role "Virtual Machine Contributor" --scope "$VM_ID" -o none

# GitHub environment, secrets and variables used by .github/workflows/deploy.yml.
gh api -X PUT "repos/$REPO/environments/production" --input - >/dev/null <<EOF
{"deployment_branch_policy": {"protected_branches": false, "custom_branch_policies": true}}
EOF
gh api -X POST "repos/$REPO/environments/production/deployment-branch-policies" -f name=main >/dev/null || true
gh secret set AZURE_CLIENT_ID -R "$REPO" -e production -b "$APP_ID"
gh secret set AZURE_TENANT_ID -R "$REPO" -e production -b "$TENANT"
gh secret set AZURE_SUBSCRIPTION_ID -R "$REPO" -e production -b "$SUB"
for pair in "ACR_NAME=$ACR" "RESOURCE_GROUP=$RG" "VM_NAME=$VM" "SITE_ADDRESS=$SITE_ADDRESS" "BACKUP_ACCOUNT=$BACKUP_ACCOUNT"; do
  gh variable set "${pair%%=*}" -R "$REPO" -e production -b "${pair#*=}"
done

# App settings on the VM. Secrets are generated on the VM and never leave it.
echo "Waiting for first-boot setup (Docker, Azure CLI) to finish..."
az vm run-command invoke -g "$RG" -n "$VM" --command-id RunShellScript --query "value[0].message" -o tsv --scripts "
cloud-init status --wait >/dev/null
umask 077
test -f /srv/interviewcheck/app.env || cat > /srv/interviewcheck/app.env <<EOF
INTERVIEWCHECK_PUBLIC_ORIGIN=https://$SITE_ADDRESS
INTERVIEWCHECK_ACCESS_MODE=embedded
INTERVIEWCHECK_OPERATOR_EMAIL=$OPERATOR_EMAIL
INTERVIEWCHECK_SIGNUP_SECRET=\$(openssl rand -hex 24)
ADMIN_EMAILS=$OPERATOR_EMAIL
ADMIN_BOOTSTRAP_SECRET=\$(openssl rand -hex 24)
INTERVIEWCHECK_TRUST_PROXY_CLIENT_IP=1
EOF
docker --version; az version --query '\"azure-cli\"' -o tsv"

echo
echo "Done. Site: https://$SITE_ADDRESS (live after the first deploy workflow run)"
echo "Run: gh workflow run deploy.yml -R $REPO"
