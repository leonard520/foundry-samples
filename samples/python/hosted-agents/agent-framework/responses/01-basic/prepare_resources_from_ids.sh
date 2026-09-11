#!/usr/bin/env bash

set -euo pipefail

# Git Bash otherwise rewrites leading-slash Azure resource IDs as Windows paths for native commands.
case "${OSTYPE:-}" in
  msys*|cygwin*)
    export MSYS_NO_PATHCONV=1
    export MSYS2_ARG_CONV_EXCL='*'
    ;;
esac

APPLY=false
AZD_ENVIRONMENT=""
REGION=""

usage() {
  cat <<'EOF'
Usage: ./scripts/prepare_resources_from_ids.sh [--apply] [--azd-env <name>] [--region <location>]

Uses caller-provided Azure resource IDs as the desired resource locations.
When a non-AKS resource ID is omitted, a suitable ID is generated under
FOUNDRY_RESOURCE_GROUP_ID. Existing non-AKS resources are reused; missing
non-AKS resources are created at the resolved IDs. AKS_RESOURCE_ID must identify
an existing cluster. The script reads its kubelet identity to grant registry
pull access, but never creates or modifies AKS clusters or node pools.

Without --apply, the script only prints the resolved plan.

Resource ID inputs:
  FOUNDRY_RESOURCE_GROUP_ID (required)
  AKS_RESOURCE_ID (required)
  HOSTING_IDENTITY_RESOURCE_ID (optional)
  WORKLOAD_IDENTITY_RESOURCE_ID (optional)
  STORAGE_ACCOUNT_RESOURCE_ID (optional)
  ACR_RESOURCE_ID (optional)
  AGENT_SUBNET_RESOURCE_ID (optional)
  APPLICATIONINSIGHTS_RESOURCE_ID (optional; must identify an existing component)

Options:
  --apply             Create missing resources and required role assignments.
  --azd-env <name>    Create or reuse this azd environment, then write the resolved resource IDs to it.
  --region <location> Azure region for newly created resources. Defaults to AZURE_LOCATION or eastus2euap.
  -h, --help          Show this help.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply)
      APPLY=true
      shift
      ;;
    --azd-env)
      [[ $# -ge 2 ]] || { echo "--azd-env requires a value" >&2; exit 2; }
      AZD_ENVIRONMENT="$2"
      shift 2
      ;;
    --region)
      [[ $# -ge 2 ]] || { echo "--region requires a value" >&2; exit 2; }
      REGION="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

: "${FOUNDRY_RESOURCE_GROUP_ID:?Set FOUNDRY_RESOURCE_GROUP_ID to the desired resource group ID.}"
: "${AKS_RESOURCE_ID:?Set AKS_RESOURCE_ID to the existing AKS cluster resource ID.}"

resource_id_subscription() {
  local resource_id="$1"

  if [[ "$resource_id" =~ ^/subscriptions/([^/]+)(/|$) ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
    return
  fi

  echo "Invalid Azure resource ID: ${resource_id}" >&2
  return 1
}

resource_group_name() {
  local resource_group_id="$1"

  if [[ "$resource_group_id" =~ ^/subscriptions/[^/]+/resourceGroups/([^/]+)$ ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
    return
  fi

  echo "Invalid resource group ID: ${resource_group_id}" >&2
  return 1
}

resource_id_resource_group() {
  local resource_id="$1"

  if [[ "$resource_id" =~ ^/subscriptions/[^/]+/resourceGroups/([^/]+)/providers/ ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
    return
  fi

  echo "Resource ID does not contain a resource group: ${resource_id}" >&2
  return 1
}

resource_id_name() {
  local resource_id="$1"
  printf '%s\n' "${resource_id##*/}"
}

subnet_vnet_name() {
  local subnet_id="$1"

  if [[ "$subnet_id" =~ /virtualNetworks/([^/]+)/subnets/[^/]+$ ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
    return
  fi

  echo "Invalid subnet resource ID: ${subnet_id}" >&2
  return 1
}

require_resource_id_pattern() {
  local label="$1"
  local resource_id="$2"
  local pattern="$3"

  if [[ ! "$resource_id" =~ $pattern ]]; then
    echo "${label} is not a valid resource ID: ${resource_id}" >&2
    return 1
  fi
}

require_resource_id_pattern \
  "FOUNDRY_RESOURCE_GROUP_ID" \
  "$FOUNDRY_RESOURCE_GROUP_ID" \
  '^/subscriptions/[^/]+/resourceGroups/[^/]+$'

RESOURCE_SUBSCRIPTION_ID="$(resource_id_subscription "$FOUNDRY_RESOURCE_GROUP_ID")"
LOCATION="${REGION:-${AZURE_LOCATION:-eastus2euap}}"

AZD_SUBSCRIPTION_ID=""
AZD_ENVIRONMENT_EXISTS=false
if [[ -n "$AZD_ENVIRONMENT" ]]; then
  command -v azd >/dev/null || { echo "azd is required with --azd-env." >&2; exit 1; }
  if azd env get-values --environment "$AZD_ENVIRONMENT" >/dev/null 2>&1; then
    AZD_ENVIRONMENT_EXISTS=true
    AZD_SUBSCRIPTION_ID="$(azd env get-value AZURE_SUBSCRIPTION_ID --environment "$AZD_ENVIRONMENT" 2>/dev/null || true)"
  fi
fi

if [[ -n "${AZURE_SUBSCRIPTION_ID:-}" && -n "$AZD_SUBSCRIPTION_ID" &&
  "$AZURE_SUBSCRIPTION_ID" != "$AZD_SUBSCRIPTION_ID" ]]; then
  echo "AZURE_SUBSCRIPTION_ID does not match environment '${AZD_ENVIRONMENT}'." >&2
  exit 2
fi

configured_subscription_id="${AZURE_SUBSCRIPTION_ID:-$AZD_SUBSCRIPTION_ID}"
if [[ -n "$configured_subscription_id" && "$configured_subscription_id" != "$RESOURCE_SUBSCRIPTION_ID" ]]; then
  echo "The configured subscription does not match FOUNDRY_RESOURCE_GROUP_ID." >&2
  exit 2
fi

VNET_PREFIX="${VNET_PREFIX:-172.20.0.0/16}"
SUBNET_PREFIX="${SUBNET_PREFIX:-172.20.1.0/24}"

RESOURCE_GROUP="$(resource_group_name "$FOUNDRY_RESOURCE_GROUP_ID")"
resource_prefix="$(printf '%s' "$RESOURCE_GROUP" |
  tr '[:upper:]' '[:lower:]' |
  sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//' |
  cut -c1-40 |
  sed -E 's/-+$//')"
if [[ ${#resource_prefix} -lt 3 ]]; then
  resource_prefix="foundry-byoc"
fi

hosting_identity_name="${HOSTING_IDENTITY_NAME:-${resource_prefix}-hosting-mi}"
workload_identity_name="${WORKLOAD_IDENTITY_NAME:-${resource_prefix}-workload-mi}"
vnet_name="${VNET_NAME:-${resource_prefix}-agent-vnet}"
subnet_name="${SUBNET_NAME:-agent-subnet}"
APPLICATION_INSIGHTS_LOCATION="${APPLICATION_INSIGHTS_LOCATION:-$([[ "$LOCATION" == "eastus2euap" ]] && echo eastus2 || echo "$LOCATION")}"
application_insights_name="${APPLICATION_INSIGHTS_NAME:-${resource_prefix}-appi}"
log_analytics_workspace_name="${LOG_ANALYTICS_WORKSPACE_NAME:-${resource_prefix}-law}"

HOSTING_IDENTITY_RESOURCE_ID="${HOSTING_IDENTITY_RESOURCE_ID:-${FOUNDRY_RESOURCE_GROUP_ID}/providers/Microsoft.ManagedIdentity/userAssignedIdentities/${hosting_identity_name}}"
WORKLOAD_IDENTITY_RESOURCE_ID="${WORKLOAD_IDENTITY_RESOURCE_ID:-${FOUNDRY_RESOURCE_GROUP_ID}/providers/Microsoft.ManagedIdentity/userAssignedIdentities/${workload_identity_name}}"
AGENT_SUBNET_RESOURCE_ID="${AGENT_SUBNET_RESOURCE_ID:-${FOUNDRY_RESOURCE_GROUP_ID}/providers/Microsoft.Network/virtualNetworks/${vnet_name}/subnets/${subnet_name}}"
APPLICATION_INSIGHTS_WAS_PROVIDED=false
if [[ -n "${APPLICATIONINSIGHTS_RESOURCE_ID:-}" ]]; then
  APPLICATION_INSIGHTS_WAS_PROVIDED=true
else
  APPLICATIONINSIGHTS_RESOURCE_ID="${FOUNDRY_RESOURCE_GROUP_ID}/providers/Microsoft.Insights/components/${application_insights_name}"
fi
if [[ -z "${ACR_RESOURCE_ID:-}" ]]; then
  acr_base="$(printf '%sacr' "$resource_prefix" | tr -cd 'a-z0-9')"
  acr_hash="$(printf '%s' "${RESOURCE_SUBSCRIPTION_ID}:${RESOURCE_GROUP}:acr" | shasum -a 256 | cut -c1-8)"
  acr_name="${ACR_NAME:-$(printf '%.42s%s' "$acr_base" "$acr_hash")}"
  if [[ ! "$acr_name" =~ ^[a-z0-9]{5,50}$ ]]; then
    echo "ACR_NAME must be 5-50 lowercase letters or numbers." >&2
    exit 2
  fi
  ACR_RESOURCE_ID="${FOUNDRY_RESOURCE_GROUP_ID}/providers/Microsoft.ContainerRegistry/registries/${acr_name}"
fi
if [[ -z "${STORAGE_ACCOUNT_RESOURCE_ID:-}" ]]; then
  storage_base="$(printf '%s' "$resource_prefix" | tr -cd 'a-z0-9')"
  storage_hash="$(printf '%s' "${RESOURCE_SUBSCRIPTION_ID}:${RESOURCE_GROUP}" | shasum -a 256 | cut -c1-8)"
  storage_account_name="${STORAGE_ACCOUNT_NAME:-$(printf '%.16s%s' "$storage_base" "$storage_hash")}"
  STORAGE_ACCOUNT_RESOURCE_ID="${FOUNDRY_RESOURCE_GROUP_ID}/providers/Microsoft.Storage/storageAccounts/${storage_account_name}"
fi

require_resource_id_pattern \
  "AKS_RESOURCE_ID" \
  "$AKS_RESOURCE_ID" \
  '^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft\.ContainerService/managedClusters/[^/]+$'
require_resource_id_pattern \
  "HOSTING_IDENTITY_RESOURCE_ID" \
  "$HOSTING_IDENTITY_RESOURCE_ID" \
  '^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft\.ManagedIdentity/userAssignedIdentities/[^/]+$'
require_resource_id_pattern \
  "WORKLOAD_IDENTITY_RESOURCE_ID" \
  "$WORKLOAD_IDENTITY_RESOURCE_ID" \
  '^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft\.ManagedIdentity/userAssignedIdentities/[^/]+$'
require_resource_id_pattern \
  "STORAGE_ACCOUNT_RESOURCE_ID" \
  "$STORAGE_ACCOUNT_RESOURCE_ID" \
  '^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft\.Storage/storageAccounts/[^/]+$'
require_resource_id_pattern \
  "ACR_RESOURCE_ID" \
  "$ACR_RESOURCE_ID" \
  '^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft\.ContainerRegistry/registries/[^/]+$'
require_resource_id_pattern \
  "AGENT_SUBNET_RESOURCE_ID" \
  "$AGENT_SUBNET_RESOURCE_ID" \
  '^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft\.Network/virtualNetworks/[^/]+/subnets/[^/]+$'
require_resource_id_pattern \
  "APPLICATIONINSIGHTS_RESOURCE_ID" \
  "$APPLICATIONINSIGHTS_RESOURCE_ID" \
  '^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft\.Insights/components/[^/]+$'

AKS_SUBSCRIPTION_ID="$(resource_id_subscription "$AKS_RESOURCE_ID")"
AKS_RESOURCE_GROUP="$(resource_id_resource_group "$AKS_RESOURCE_ID")"
AKS_NAME="$(resource_id_name "$AKS_RESOURCE_ID")"
HOSTING_IDENTITY_SUBSCRIPTION_ID="$(resource_id_subscription "$HOSTING_IDENTITY_RESOURCE_ID")"
HOSTING_IDENTITY_RESOURCE_GROUP="$(resource_id_resource_group "$HOSTING_IDENTITY_RESOURCE_ID")"
HOSTING_IDENTITY_NAME="$(resource_id_name "$HOSTING_IDENTITY_RESOURCE_ID")"
WORKLOAD_IDENTITY_SUBSCRIPTION_ID="$(resource_id_subscription "$WORKLOAD_IDENTITY_RESOURCE_ID")"
WORKLOAD_IDENTITY_RESOURCE_GROUP="$(resource_id_resource_group "$WORKLOAD_IDENTITY_RESOURCE_ID")"
WORKLOAD_IDENTITY_NAME="$(resource_id_name "$WORKLOAD_IDENTITY_RESOURCE_ID")"
STORAGE_ACCOUNT_SUBSCRIPTION_ID="$(resource_id_subscription "$STORAGE_ACCOUNT_RESOURCE_ID")"
STORAGE_ACCOUNT_RESOURCE_GROUP="$(resource_id_resource_group "$STORAGE_ACCOUNT_RESOURCE_ID")"
STORAGE_ACCOUNT_NAME="$(resource_id_name "$STORAGE_ACCOUNT_RESOURCE_ID")"
ACR_SUBSCRIPTION_ID="$(resource_id_subscription "$ACR_RESOURCE_ID")"
ACR_RESOURCE_GROUP="$(resource_id_resource_group "$ACR_RESOURCE_ID")"
ACR_NAME="$(resource_id_name "$ACR_RESOURCE_ID")"
AGENT_SUBNET_SUBSCRIPTION_ID="$(resource_id_subscription "$AGENT_SUBNET_RESOURCE_ID")"
AGENT_SUBNET_RESOURCE_GROUP="$(resource_id_resource_group "$AGENT_SUBNET_RESOURCE_ID")"
VNET_NAME="$(subnet_vnet_name "$AGENT_SUBNET_RESOURCE_ID")"
SUBNET_NAME="$(resource_id_name "$AGENT_SUBNET_RESOURCE_ID")"
VNET_RESOURCE_ID="${AGENT_SUBNET_RESOURCE_ID%/subnets/*}"
APPLICATION_INSIGHTS_SUBSCRIPTION_ID="$(resource_id_subscription "$APPLICATIONINSIGHTS_RESOURCE_ID")"
APPLICATION_INSIGHTS_RESOURCE_GROUP="$(resource_id_resource_group "$APPLICATIONINSIGHTS_RESOURCE_ID")"
APPLICATION_INSIGHTS_NAME="$(resource_id_name "$APPLICATIONINSIGHTS_RESOURCE_ID")"
LOG_ANALYTICS_WORKSPACE_RESOURCE_ID="/subscriptions/${APPLICATION_INSIGHTS_SUBSCRIPTION_ID}/resourceGroups/${APPLICATION_INSIGHTS_RESOURCE_GROUP}/providers/Microsoft.OperationalInsights/workspaces/${log_analytics_workspace_name}"

print_plan() {
  cat <<EOF
Mode:                         $([[ "$APPLY" == true ]] && echo apply || echo preview)
Creation subscription:        ${RESOURCE_SUBSCRIPTION_ID}
Location for new resources:   ${LOCATION}
Resource group action:        reuse if present; create if missing
Hosting identity action:      reuse if present; create if missing
Workload identity action:     reuse if present; create if missing
Storage account action:       reuse if present; create if missing
Container registry action:    reuse if present; create if missing
Agent subnet action:          reuse if present; create if missing
Application Insights action:  reuse supplied component; otherwise create if missing
AKS action:                   external (read kubelet identity only)

FOUNDRY_RESOURCE_GROUP_ID=${FOUNDRY_RESOURCE_GROUP_ID}
AKS_RESOURCE_ID=${AKS_RESOURCE_ID}
HOSTING_IDENTITY_RESOURCE_ID=${HOSTING_IDENTITY_RESOURCE_ID}
WORKLOAD_IDENTITY_RESOURCE_ID=${WORKLOAD_IDENTITY_RESOURCE_ID}
STORAGE_ACCOUNT_RESOURCE_ID=${STORAGE_ACCOUNT_RESOURCE_ID}
ACR_RESOURCE_ID=${ACR_RESOURCE_ID}
AGENT_SUBNET_RESOURCE_ID=${AGENT_SUBNET_RESOURCE_ID}
APPLICATIONINSIGHTS_RESOURCE_ID=${APPLICATIONINSIGHTS_RESOURCE_ID}
EOF
}

run() {
  printf '+ '
  printf '%q ' "$@"
  printf '\n'
  "$@"
}

ensure_role_assignment() {
  local scope="$1"
  local principal_id="$2"
  local role_id="$3"
  local scope_subscription_id
  local role_definition_id
  local resource_manager_endpoint
  local existing

  scope_subscription_id="$(resource_id_subscription "$scope")"
  role_definition_id="/subscriptions/${scope_subscription_id}/providers/Microsoft.Authorization/roleDefinitions/${role_id}"
  resource_manager_endpoint="$(az cloud show --query endpoints.resourceManager -o tsv)"
  resource_manager_endpoint="${resource_manager_endpoint%/}"
  existing="$(az rest --method get \
    --url "${resource_manager_endpoint}${scope}/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01&%24filter=atScope()" \
    --query "value[?properties.principalId=='${principal_id}' && ends_with(properties.roleDefinitionId, '${role_id}')].id | [0]" \
    -o tsv)"

  if [[ -n "$existing" ]]; then
    echo "Role assignment already exists: ${existing}"
    return
  fi

  local assignment_id
  assignment_id="$(uuidgen | tr '[:upper:]' '[:lower:]')"
  run az rest --method put \
    --url "${resource_manager_endpoint}${scope}/providers/Microsoft.Authorization/roleAssignments/${assignment_id}?api-version=2022-04-01" \
    --body "{\"properties\":{\"roleDefinitionId\":\"${role_definition_id}\",\"principalId\":\"${principal_id}\",\"principalType\":\"ServicePrincipal\"}}" \
    --output none
}

write_azd_environment() {
  [[ -n "$AZD_ENVIRONMENT" ]] || return 0

  run azd env set --environment "$AZD_ENVIRONMENT" \
    "AZURE_RESOURCE_GROUP=${RESOURCE_GROUP}" \
    "AZURE_SUBSCRIPTION_ID=${RESOURCE_SUBSCRIPTION_ID}" \
    "AZURE_LOCATION=${LOCATION}" \
    "AZD_AGENT_SKIP_ACR=false" \
    "FOUNDRY_RESOURCE_GROUP_ID=${FOUNDRY_RESOURCE_GROUP_ID}" \
    "AKS_RESOURCE_ID=${AKS_RESOURCE_ID}" \
    "HOSTING_IDENTITY_RESOURCE_ID=${HOSTING_IDENTITY_RESOURCE_ID}" \
    "WORKLOAD_IDENTITY_RESOURCE_ID=${WORKLOAD_IDENTITY_RESOURCE_ID}" \
    "STORAGE_ACCOUNT_RESOURCE_ID=${STORAGE_ACCOUNT_RESOURCE_ID}" \
    "ACR_RESOURCE_ID=${ACR_RESOURCE_ID}" \
    "AZURE_CONTAINER_REGISTRY_ENDPOINT=${AZURE_CONTAINER_REGISTRY_ENDPOINT}" \
    "AZURE_CONTAINER_REGISTRY_RESOURCE_ID=${ACR_RESOURCE_ID}" \
    "AGENT_SUBNET_RESOURCE_ID=${AGENT_SUBNET_RESOURCE_ID}" \
    "APPLICATIONINSIGHTS_RESOURCE_ID=${APPLICATIONINSIGHTS_RESOURCE_ID}"

  printf '+ azd env set --environment %q APPLICATIONINSIGHTS_CONNECTION_STRING=%q\n' \
    "$AZD_ENVIRONMENT" '<redacted>'
  azd env set --environment "$AZD_ENVIRONMENT" \
    "APPLICATIONINSIGHTS_CONNECTION_STRING=${APPLICATIONINSIGHTS_CONNECTION_STRING}"
}

ensure_azd_environment() {
  [[ -n "$AZD_ENVIRONMENT" ]] || return 0

  if [[ "$AZD_ENVIRONMENT_EXISTS" == true ]]; then
    echo "Reusing azd environment: ${AZD_ENVIRONMENT}"
    return
  fi

  run azd env new "$AZD_ENVIRONMENT" \
    --subscription "$RESOURCE_SUBSCRIPTION_ID" \
    --location "$LOCATION" \
    --no-prompt
}

print_plan
if [[ "$APPLY" != true ]]; then
  echo
  echo "Preview only. Re-run with --apply to create missing resources and role assignments."
  exit 0
fi

command -v az >/dev/null || { echo "Azure CLI is required with --apply." >&2; exit 1; }
ensure_azd_environment
run az account set --subscription "$RESOURCE_SUBSCRIPTION_ID"

if ! kubelet_principal_id="$(
  az aks show \
    --subscription "$AKS_SUBSCRIPTION_ID" \
    --resource-group "$AKS_RESOURCE_GROUP" \
    --name "$AKS_NAME" \
    --query identityProfile.kubeletidentity.objectId \
    -o tsv
)"; then
  echo "Unable to read the AKS kubelet managed identity: ${AKS_RESOURCE_ID}" >&2
  exit 1
fi
if [[ -z "$kubelet_principal_id" ]]; then
  echo "AKS cluster does not expose a kubelet managed identity: ${AKS_RESOURCE_ID}" >&2
  exit 1
fi

if ! az group show \
  --subscription "$RESOURCE_SUBSCRIPTION_ID" \
  --name "$RESOURCE_GROUP" \
  --output none 2>/dev/null; then
  run az group create \
    --subscription "$RESOURCE_SUBSCRIPTION_ID" \
    --name "$RESOURCE_GROUP" \
    --location "$LOCATION" \
    --output none
else
  echo "Reusing resource group: ${FOUNDRY_RESOURCE_GROUP_ID}"
fi

if ! az identity show --ids "$HOSTING_IDENTITY_RESOURCE_ID" --output none 2>/dev/null; then
  run az identity create \
    --subscription "$HOSTING_IDENTITY_SUBSCRIPTION_ID" \
    --resource-group "$HOSTING_IDENTITY_RESOURCE_GROUP" \
    --name "$HOSTING_IDENTITY_NAME" \
    --location "$LOCATION" \
    --output none
else
  echo "Reusing hosting identity: ${HOSTING_IDENTITY_RESOURCE_ID}"
fi

if ! az identity show --ids "$WORKLOAD_IDENTITY_RESOURCE_ID" --output none 2>/dev/null; then
  run az identity create \
    --subscription "$WORKLOAD_IDENTITY_SUBSCRIPTION_ID" \
    --resource-group "$WORKLOAD_IDENTITY_RESOURCE_GROUP" \
    --name "$WORKLOAD_IDENTITY_NAME" \
    --location "$LOCATION" \
    --output none
else
  echo "Reusing workload identity: ${WORKLOAD_IDENTITY_RESOURCE_ID}"
fi

if ! az storage account show --ids "$STORAGE_ACCOUNT_RESOURCE_ID" --output none 2>/dev/null; then
  run az storage account create \
    --subscription "$STORAGE_ACCOUNT_SUBSCRIPTION_ID" \
    --resource-group "$STORAGE_ACCOUNT_RESOURCE_GROUP" \
    --name "$STORAGE_ACCOUNT_NAME" \
    --location "$LOCATION" \
    --kind StorageV2 \
    --sku Standard_LRS \
    --https-only true \
    --min-tls-version TLS1_2 \
    --allow-blob-public-access false \
    --public-network-access Enabled \
    --default-action Allow \
    --output none
else
  echo "Reusing storage account: ${STORAGE_ACCOUNT_RESOURCE_ID}"
fi

if ! az monitor app-insights component show --ids "$APPLICATIONINSIGHTS_RESOURCE_ID" --output none 2>/dev/null; then
  if [[ "$APPLICATION_INSIGHTS_WAS_PROVIDED" == true ]]; then
    echo "APPLICATIONINSIGHTS_RESOURCE_ID does not identify an existing Application Insights resource: ${APPLICATIONINSIGHTS_RESOURCE_ID}" >&2
    exit 1
  fi

  if ! az monitor log-analytics workspace show \
    --subscription "$APPLICATION_INSIGHTS_SUBSCRIPTION_ID" \
    --resource-group "$APPLICATION_INSIGHTS_RESOURCE_GROUP" \
    --workspace-name "$log_analytics_workspace_name" \
    --output none 2>/dev/null; then
    run az monitor log-analytics workspace create \
      --subscription "$APPLICATION_INSIGHTS_SUBSCRIPTION_ID" \
      --resource-group "$APPLICATION_INSIGHTS_RESOURCE_GROUP" \
      --workspace-name "$log_analytics_workspace_name" \
      --location "$APPLICATION_INSIGHTS_LOCATION" \
      --sku PerGB2018 \
      --retention-time 90 \
      --output none
  fi

  run az monitor app-insights component create \
    --subscription "$APPLICATION_INSIGHTS_SUBSCRIPTION_ID" \
    --resource-group "$APPLICATION_INSIGHTS_RESOURCE_GROUP" \
    --app "$APPLICATION_INSIGHTS_NAME" \
    --location "$APPLICATION_INSIGHTS_LOCATION" \
    --kind web \
    --application-type web \
    --workspace "$LOG_ANALYTICS_WORKSPACE_RESOURCE_ID" \
    --output none
else
  echo "Reusing Application Insights: ${APPLICATIONINSIGHTS_RESOURCE_ID}"
fi

APPLICATIONINSIGHTS_CONNECTION_STRING="$(
  az monitor app-insights component show \
    --ids "$APPLICATIONINSIGHTS_RESOURCE_ID" \
    --query connectionString \
    -o tsv
)"
if [[ -z "$APPLICATIONINSIGHTS_CONNECTION_STRING" ]]; then
  echo "Application Insights did not return a connection string: ${APPLICATIONINSIGHTS_RESOURCE_ID}" >&2
  exit 1
fi

if ! az acr show \
  --subscription "$ACR_SUBSCRIPTION_ID" \
  --resource-group "$ACR_RESOURCE_GROUP" \
  --name "$ACR_NAME" \
  --output none 2>/dev/null; then
  run az acr create \
    --subscription "$ACR_SUBSCRIPTION_ID" \
    --resource-group "$ACR_RESOURCE_GROUP" \
    --name "$ACR_NAME" \
    --location "$LOCATION" \
    --sku Basic \
    --admin-enabled false \
    --output none
else
  echo "Reusing container registry: ${ACR_RESOURCE_ID}"
fi

AZURE_CONTAINER_REGISTRY_ENDPOINT="$(
  az acr show \
    --subscription "$ACR_SUBSCRIPTION_ID" \
    --resource-group "$ACR_RESOURCE_GROUP" \
    --name "$ACR_NAME" \
    --query loginServer \
    -o tsv
)"
if [[ -z "$AZURE_CONTAINER_REGISTRY_ENDPOINT" ]]; then
  echo "Container registry did not return a login server: ${ACR_RESOURCE_ID}" >&2
  exit 1
fi

if ! az network vnet show --ids "$VNET_RESOURCE_ID" --output none 2>/dev/null; then
  run az network vnet create \
    --subscription "$AGENT_SUBNET_SUBSCRIPTION_ID" \
    --resource-group "$AGENT_SUBNET_RESOURCE_GROUP" \
    --name "$VNET_NAME" \
    --location "$LOCATION" \
    --address-prefixes "$VNET_PREFIX" \
    --output none
fi

if ! az network vnet subnet show \
  --subscription "$AGENT_SUBNET_SUBSCRIPTION_ID" \
  --resource-group "$AGENT_SUBNET_RESOURCE_GROUP" \
  --vnet-name "$VNET_NAME" \
  --name "$SUBNET_NAME" \
  --output none 2>/dev/null; then
  run az network vnet subnet create \
    --subscription "$AGENT_SUBNET_SUBSCRIPTION_ID" \
    --resource-group "$AGENT_SUBNET_RESOURCE_GROUP" \
    --vnet-name "$VNET_NAME" \
    --name "$SUBNET_NAME" \
    --address-prefixes "$SUBNET_PREFIX" \
    --delegations Microsoft.App/environments \
    --output none
else
  echo "Reusing agent subnet: ${AGENT_SUBNET_RESOURCE_ID}"
fi

hosting_principal_id="$(az identity show --ids "$HOSTING_IDENTITY_RESOURCE_ID" --query principalId -o tsv)"
workload_principal_id="$(az identity show --ids "$WORKLOAD_IDENTITY_RESOURCE_ID" --query principalId -o tsv)"

READER_ROLE_ID="acdd72a7-3385-48ef-bd42-f606fba81ae7"
AKS_CONTRIBUTOR_ROLE_ID="ed7f3fbd-7b88-4dd4-9017-9adb7ce333f8"
FEDERATED_IDENTITY_CREDENTIAL_CONTRIBUTOR_ROLE_ID="7e559ce2-48d7-4b27-9128-fa1b247f1308"
STORAGE_BLOB_DATA_CONTRIBUTOR_ROLE_ID="ba92f5b4-2d11-453d-a403-e96b0029c9fe"
AKS_RBAC_CLUSTER_ADMIN_ROLE_ID="b1ff04bb-8a4e-4dc4-8eb5-8693973ce19b"
ACR_PULL_ROLE_ID="7f951dda-4ed3-4680-a7ca-43fe172d538d"
CONTAINER_REGISTRY_REPOSITORY_READER_ROLE_ID="b93aa761-3e63-49ed-ac28-beffa264f7ac"

acr_role_assignment_mode="$(
  az acr show \
    --subscription "$ACR_SUBSCRIPTION_ID" \
    --resource-group "$ACR_RESOURCE_GROUP" \
    --name "$ACR_NAME" \
    --query roleAssignmentMode \
    -o tsv
)"
case "$acr_role_assignment_mode" in
  AbacRepositoryPermissions|rbac-abac)
    registry_pull_role_id="$CONTAINER_REGISTRY_REPOSITORY_READER_ROLE_ID"
    ;;
  ""|LegacyRegistryPermissions|legacy-registry-permissions)
    registry_pull_role_id="$ACR_PULL_ROLE_ID"
    ;;
  *)
    echo "Unsupported ACR role assignment mode '${acr_role_assignment_mode}': ${ACR_RESOURCE_ID}" >&2
    exit 1
    ;;
esac

ensure_role_assignment "$FOUNDRY_RESOURCE_GROUP_ID" "$hosting_principal_id" "$READER_ROLE_ID"
ensure_role_assignment "$AKS_RESOURCE_ID" "$hosting_principal_id" "$AKS_CONTRIBUTOR_ROLE_ID"
ensure_role_assignment "$AKS_RESOURCE_ID" "$hosting_principal_id" "$AKS_RBAC_CLUSTER_ADMIN_ROLE_ID"
ensure_role_assignment "$ACR_RESOURCE_ID" "$kubelet_principal_id" "$registry_pull_role_id"
ensure_role_assignment \
  "$WORKLOAD_IDENTITY_RESOURCE_ID" \
  "$hosting_principal_id" \
  "$FEDERATED_IDENTITY_CREDENTIAL_CONTRIBUTOR_ROLE_ID"
ensure_role_assignment \
  "$STORAGE_ACCOUNT_RESOURCE_ID" \
  "$workload_principal_id" \
  "$STORAGE_BLOB_DATA_CONTRIBUTOR_ROLE_ID"

write_azd_environment

echo
echo "All required Azure resources have been created successfully, and the necessary permissions have been granted."
