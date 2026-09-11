#Requires -Version 5.1

[CmdletBinding()]
param(
    [switch]$Apply,
    [Alias("azd-env")]
    [string]$AzdEnvironment = "",
    [string]$Region = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Get-RequiredEnvironmentVariable {
    param([Parameter(Mandatory)][string]$Name)

    $value = [Environment]::GetEnvironmentVariable($Name)
    if ([string]::IsNullOrWhiteSpace($value)) {
        throw "Set $Name to the required Azure resource ID."
    }

    return $value.Trim()
}

function Get-EnvironmentVariableOrDefault {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Default
    )

    $value = [Environment]::GetEnvironmentVariable($Name)
    if ([string]::IsNullOrEmpty($value)) {
        return $Default
    }

    return $value
}

function Get-ResourceIdSubscription {
    param([Parameter(Mandatory)][string]$ResourceId)

    if ($ResourceId -match "^/subscriptions/([^/]+)(?:/|$)") {
        return $Matches[1]
    }

    throw "Invalid Azure resource ID: $ResourceId"
}

function Get-ResourceGroupName {
    param([Parameter(Mandatory)][string]$ResourceGroupId)

    if ($ResourceGroupId -match "^/subscriptions/[^/]+/resourceGroups/([^/]+)$") {
        return $Matches[1]
    }

    throw "Invalid resource group ID: $ResourceGroupId"
}

function Get-ResourceIdResourceGroup {
    param([Parameter(Mandatory)][string]$ResourceId)

    if ($ResourceId -match "^/subscriptions/[^/]+/resourceGroups/([^/]+)/providers/") {
        return $Matches[1]
    }

    throw "Resource ID does not contain a resource group: $ResourceId"
}

function Get-ResourceIdName {
    param([Parameter(Mandatory)][string]$ResourceId)

    return $ResourceId.Substring($ResourceId.LastIndexOf("/") + 1)
}

function Get-SubnetVirtualNetworkName {
    param([Parameter(Mandatory)][string]$SubnetId)

    if ($SubnetId -match "/virtualNetworks/([^/]+)/subnets/[^/]+$") {
        return $Matches[1]
    }

    throw "Invalid subnet resource ID: $SubnetId"
}

function Assert-ResourceIdPattern {
    param(
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][string]$ResourceId,
        [Parameter(Mandatory)][string]$Pattern
    )

    if ($ResourceId -notmatch $Pattern) {
        throw "$Label is not a valid resource ID: $ResourceId"
    }
}

function Get-Sha256Prefix {
    param(
        [Parameter(Mandatory)][string]$Value,
        [Parameter(Mandatory)][int]$Length
    )

    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Value)
        $hash = $sha256.ComputeHash($bytes)
        $hex = -join ($hash | ForEach-Object { $_.ToString("x2") })
        return $hex.Substring(0, $Length)
    }
    finally {
        $sha256.Dispose()
    }
}

function Invoke-NativeCapture {
    param(
        [Parameter(Mandatory)][string]$Command,
        [Parameter(Mandatory)][string[]]$Arguments
    )

    $output = & $Command @Arguments
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        throw "$Command failed with exit code $exitCode."
    }

    return (($output | ForEach-Object { "$_" }) -join [Environment]::NewLine).Trim()
}

function Invoke-LoggedCommand {
    param(
        [Parameter(Mandatory)][string]$Command,
        [Parameter(Mandatory)][string[]]$Arguments
    )

    Write-Host "+ $Command $($Arguments -join ' ')"
    & $Command @Arguments
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        throw "$Command failed with exit code $exitCode."
    }
}

function Test-AzCommand {
    param([Parameter(Mandatory)][string[]]$Arguments)

    & az @Arguments *> $null
    return $LASTEXITCODE -eq 0
}

function Ensure-RoleAssignment {
    param(
        [Parameter(Mandatory)][string]$Scope,
        [Parameter(Mandatory)][string]$PrincipalId,
        [Parameter(Mandatory)][string]$RoleId
    )

    $scopeSubscriptionId = Get-ResourceIdSubscription -ResourceId $Scope
    $roleDefinitionId = "/subscriptions/$scopeSubscriptionId/providers/Microsoft.Authorization/roleDefinitions/$RoleId"
    $resourceManagerEndpoint = Invoke-NativeCapture -Command "az" -Arguments @(
        "cloud", "show",
        "--query", "endpoints.resourceManager",
        "-o", "tsv"
    )
    $resourceManagerEndpoint = $resourceManagerEndpoint.TrimEnd("/")
    $query = "value[?properties.principalId=='$PrincipalId' && ends_with(properties.roleDefinitionId, '$RoleId')].id | [0]"
    $existing = Invoke-NativeCapture -Command "az" -Arguments @(
        "rest",
        "--method", "get",
        "--url", "$resourceManagerEndpoint$Scope/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01&%24filter=atScope()",
        "--query", $query,
        "-o", "tsv"
    )

    if (-not [string]::IsNullOrWhiteSpace($existing)) {
        Write-Host "Role assignment already exists: $existing"
        return
    }

    $assignmentId = [guid]::NewGuid().ToString()
    $body = @{
        properties = @{
            roleDefinitionId = $roleDefinitionId
            principalId = $PrincipalId
            principalType = "ServicePrincipal"
        }
    } | ConvertTo-Json -Compress

    Invoke-LoggedCommand -Command "az" -Arguments @(
        "rest",
        "--method", "put",
        "--url", "$resourceManagerEndpoint$Scope/providers/Microsoft.Authorization/roleAssignments/${assignmentId}?api-version=2022-04-01",
        "--body", $body,
        "--output", "none"
    )
}

function Write-AzdEnvironment {
    if ([string]::IsNullOrWhiteSpace($AzdEnvironment)) {
        return
    }

    Invoke-LoggedCommand -Command "azd" -Arguments @(
        "env", "set",
        "--environment", $AzdEnvironment,
        "AZURE_RESOURCE_GROUP=$resourceGroup",
        "AZURE_SUBSCRIPTION_ID=$resourceSubscriptionId",
        "AZURE_LOCATION=$location",
        "AZD_AGENT_SKIP_ACR=false",
        "FOUNDRY_RESOURCE_GROUP_ID=$foundryResourceGroupId",
        "AKS_RESOURCE_ID=$aksResourceId",
        "HOSTING_IDENTITY_RESOURCE_ID=$hostingIdentityResourceId",
        "WORKLOAD_IDENTITY_RESOURCE_ID=$workloadIdentityResourceId",
        "STORAGE_ACCOUNT_RESOURCE_ID=$storageAccountResourceId",
        "ACR_RESOURCE_ID=$acrResourceId",
        "AZURE_CONTAINER_REGISTRY_ENDPOINT=$azureContainerRegistryEndpoint",
        "AZURE_CONTAINER_REGISTRY_RESOURCE_ID=$acrResourceId",
        "AGENT_SUBNET_RESOURCE_ID=$agentSubnetResourceId",
        "APPLICATIONINSIGHTS_RESOURCE_ID=$applicationInsightsResourceId"
    )

    Write-Host "+ azd env set --environment $AzdEnvironment APPLICATIONINSIGHTS_CONNECTION_STRING=<redacted>"
    & azd env set `
        --environment $AzdEnvironment `
        "APPLICATIONINSIGHTS_CONNECTION_STRING=$applicationInsightsConnectionString"
    if ($LASTEXITCODE -ne 0) {
        throw "azd failed to set APPLICATIONINSIGHTS_CONNECTION_STRING with exit code $LASTEXITCODE."
    }
}

function Ensure-AzdEnvironment {
    if ([string]::IsNullOrWhiteSpace($AzdEnvironment)) {
        return
    }

    if ($azdEnvironmentExists) {
        Write-Host "Reusing azd environment: $AzdEnvironment"
        return
    }

    Invoke-LoggedCommand -Command "azd" -Arguments @(
        "env", "new", $AzdEnvironment,
        "--subscription", $resourceSubscriptionId,
        "--location", $location,
        "--no-prompt"
    )
}

$foundryResourceGroupId = Get-RequiredEnvironmentVariable -Name "FOUNDRY_RESOURCE_GROUP_ID"
$aksResourceId = Get-RequiredEnvironmentVariable -Name "AKS_RESOURCE_ID"

Assert-ResourceIdPattern `
    -Label "FOUNDRY_RESOURCE_GROUP_ID" `
    -ResourceId $foundryResourceGroupId `
    -Pattern "^/subscriptions/[^/]+/resourceGroups/[^/]+$"

$azdEnvironmentExists = $false
$azdSubscriptionId = ""
if (-not [string]::IsNullOrWhiteSpace($AzdEnvironment)) {
    if ($null -eq (Get-Command "azd" -ErrorAction SilentlyContinue)) {
        throw "azd is required with -AzdEnvironment."
    }

    & azd env get-values --environment $AzdEnvironment *> $null
    if ($LASTEXITCODE -eq 0) {
        $azdEnvironmentExists = $true
        $azdOutput = & azd env get-value AZURE_SUBSCRIPTION_ID --environment $AzdEnvironment 2>$null
        if ($LASTEXITCODE -eq 0) {
            $azdSubscriptionId = (($azdOutput | ForEach-Object { "$_" }) -join [Environment]::NewLine).Trim()
        }
    }
}

if (-not [string]::IsNullOrWhiteSpace($env:AZURE_SUBSCRIPTION_ID) -and
    -not [string]::IsNullOrWhiteSpace($azdSubscriptionId) -and
    $env:AZURE_SUBSCRIPTION_ID -ne $azdSubscriptionId) {
    throw "AZURE_SUBSCRIPTION_ID does not match environment '$AzdEnvironment'."
}

$resourceSubscriptionId = Get-ResourceIdSubscription -ResourceId $foundryResourceGroupId
$configuredSubscriptionId = $env:AZURE_SUBSCRIPTION_ID
if ([string]::IsNullOrWhiteSpace($configuredSubscriptionId)) {
    $configuredSubscriptionId = $azdSubscriptionId
}
if (-not [string]::IsNullOrWhiteSpace($configuredSubscriptionId) -and
    $configuredSubscriptionId -ne $resourceSubscriptionId) {
    throw "The configured subscription does not match FOUNDRY_RESOURCE_GROUP_ID."
}

$location = $Region
if ([string]::IsNullOrWhiteSpace($location)) {
    $location = Get-EnvironmentVariableOrDefault -Name "AZURE_LOCATION" -Default "eastus2euap"
}
$vnetPrefix = Get-EnvironmentVariableOrDefault -Name "VNET_PREFIX" -Default "172.20.0.0/16"
$subnetPrefix = Get-EnvironmentVariableOrDefault -Name "SUBNET_PREFIX" -Default "172.20.1.0/24"

$resourceGroup = Get-ResourceGroupName -ResourceGroupId $foundryResourceGroupId
$resourcePrefix = ($resourceGroup.ToLowerInvariant() -replace "[^a-z0-9]+", "-").Trim("-")
if ($resourcePrefix.Length -gt 40) {
    $resourcePrefix = $resourcePrefix.Substring(0, 40).TrimEnd("-")
}
if ($resourcePrefix.Length -lt 3) {
    $resourcePrefix = "foundry-byoc"
}

$hostingIdentityName = Get-EnvironmentVariableOrDefault `
    -Name "HOSTING_IDENTITY_NAME" `
    -Default "$resourcePrefix-hosting-mi"
$workloadIdentityName = Get-EnvironmentVariableOrDefault `
    -Name "WORKLOAD_IDENTITY_NAME" `
    -Default "$resourcePrefix-workload-mi"
$vnetName = Get-EnvironmentVariableOrDefault -Name "VNET_NAME" -Default "$resourcePrefix-agent-vnet"
$subnetName = Get-EnvironmentVariableOrDefault -Name "SUBNET_NAME" -Default "agent-subnet"
$applicationInsightsLocation = Get-EnvironmentVariableOrDefault `
    -Name "APPLICATION_INSIGHTS_LOCATION" `
    -Default $(if ($location -eq "eastus2euap") { "eastus2" } else { $location })
$applicationInsightsName = Get-EnvironmentVariableOrDefault `
    -Name "APPLICATION_INSIGHTS_NAME" `
    -Default "$resourcePrefix-appi"
$logAnalyticsWorkspaceName = Get-EnvironmentVariableOrDefault `
    -Name "LOG_ANALYTICS_WORKSPACE_NAME" `
    -Default "$resourcePrefix-law"

$hostingIdentityResourceId = Get-EnvironmentVariableOrDefault `
    -Name "HOSTING_IDENTITY_RESOURCE_ID" `
    -Default "$foundryResourceGroupId/providers/Microsoft.ManagedIdentity/userAssignedIdentities/$hostingIdentityName"
$workloadIdentityResourceId = Get-EnvironmentVariableOrDefault `
    -Name "WORKLOAD_IDENTITY_RESOURCE_ID" `
    -Default "$foundryResourceGroupId/providers/Microsoft.ManagedIdentity/userAssignedIdentities/$workloadIdentityName"
$agentSubnetResourceId = Get-EnvironmentVariableOrDefault `
    -Name "AGENT_SUBNET_RESOURCE_ID" `
    -Default "$foundryResourceGroupId/providers/Microsoft.Network/virtualNetworks/$vnetName/subnets/$subnetName"
$applicationInsightsResourceId = [Environment]::GetEnvironmentVariable("APPLICATIONINSIGHTS_RESOURCE_ID")
$applicationInsightsWasProvided = -not [string]::IsNullOrWhiteSpace($applicationInsightsResourceId)
if (-not $applicationInsightsWasProvided) {
    $applicationInsightsResourceId = `
        "$foundryResourceGroupId/providers/Microsoft.Insights/components/$applicationInsightsName"
}

$acrResourceId = [Environment]::GetEnvironmentVariable("ACR_RESOURCE_ID")
if ([string]::IsNullOrEmpty($acrResourceId)) {
    $acrBase = ("${resourcePrefix}acr" -replace "[^a-z0-9]", "")
    $acrHash = Get-Sha256Prefix -Value "${resourceSubscriptionId}:${resourceGroup}:acr" -Length 8
    $defaultAcrName = $acrBase.Substring(0, [Math]::Min(42, $acrBase.Length)) + $acrHash
    $acrName = Get-EnvironmentVariableOrDefault -Name "ACR_NAME" -Default $defaultAcrName
    if ($acrName -cnotmatch "^[a-z0-9]{5,50}$") {
        throw "ACR_NAME must be 5-50 lowercase letters or numbers."
    }
    $acrResourceId = "$foundryResourceGroupId/providers/Microsoft.ContainerRegistry/registries/$acrName"
}

$storageAccountResourceId = [Environment]::GetEnvironmentVariable("STORAGE_ACCOUNT_RESOURCE_ID")
if ([string]::IsNullOrEmpty($storageAccountResourceId)) {
    $storageBase = $resourcePrefix -replace "[^a-z0-9]", ""
    $storageHash = Get-Sha256Prefix -Value "${resourceSubscriptionId}:${resourceGroup}" -Length 8
    $defaultStorageAccountName = $storageBase.Substring(0, [Math]::Min(16, $storageBase.Length)) + $storageHash
    $storageAccountName = Get-EnvironmentVariableOrDefault `
        -Name "STORAGE_ACCOUNT_NAME" `
        -Default $defaultStorageAccountName
    $storageAccountResourceId = "$foundryResourceGroupId/providers/Microsoft.Storage/storageAccounts/$storageAccountName"
}

Assert-ResourceIdPattern `
    -Label "AKS_RESOURCE_ID" `
    -ResourceId $aksResourceId `
    -Pattern "^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft\.ContainerService/managedClusters/[^/]+$"
Assert-ResourceIdPattern `
    -Label "HOSTING_IDENTITY_RESOURCE_ID" `
    -ResourceId $hostingIdentityResourceId `
    -Pattern "^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft\.ManagedIdentity/userAssignedIdentities/[^/]+$"
Assert-ResourceIdPattern `
    -Label "WORKLOAD_IDENTITY_RESOURCE_ID" `
    -ResourceId $workloadIdentityResourceId `
    -Pattern "^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft\.ManagedIdentity/userAssignedIdentities/[^/]+$"
Assert-ResourceIdPattern `
    -Label "STORAGE_ACCOUNT_RESOURCE_ID" `
    -ResourceId $storageAccountResourceId `
    -Pattern "^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft\.Storage/storageAccounts/[^/]+$"
Assert-ResourceIdPattern `
    -Label "ACR_RESOURCE_ID" `
    -ResourceId $acrResourceId `
    -Pattern "^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft\.ContainerRegistry/registries/[^/]+$"
Assert-ResourceIdPattern `
    -Label "AGENT_SUBNET_RESOURCE_ID" `
    -ResourceId $agentSubnetResourceId `
    -Pattern "^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft\.Network/virtualNetworks/[^/]+/subnets/[^/]+$"
Assert-ResourceIdPattern `
    -Label "APPLICATIONINSIGHTS_RESOURCE_ID" `
    -ResourceId $applicationInsightsResourceId `
    -Pattern "^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft\.Insights/components/[^/]+$"

$aksSubscriptionId = Get-ResourceIdSubscription -ResourceId $aksResourceId
$aksResourceGroup = Get-ResourceIdResourceGroup -ResourceId $aksResourceId
$aksName = Get-ResourceIdName -ResourceId $aksResourceId
$hostingIdentitySubscriptionId = Get-ResourceIdSubscription -ResourceId $hostingIdentityResourceId
$hostingIdentityResourceGroup = Get-ResourceIdResourceGroup -ResourceId $hostingIdentityResourceId
$hostingIdentityName = Get-ResourceIdName -ResourceId $hostingIdentityResourceId
$workloadIdentitySubscriptionId = Get-ResourceIdSubscription -ResourceId $workloadIdentityResourceId
$workloadIdentityResourceGroup = Get-ResourceIdResourceGroup -ResourceId $workloadIdentityResourceId
$workloadIdentityName = Get-ResourceIdName -ResourceId $workloadIdentityResourceId
$storageAccountSubscriptionId = Get-ResourceIdSubscription -ResourceId $storageAccountResourceId
$storageAccountResourceGroup = Get-ResourceIdResourceGroup -ResourceId $storageAccountResourceId
$storageAccountName = Get-ResourceIdName -ResourceId $storageAccountResourceId
$acrSubscriptionId = Get-ResourceIdSubscription -ResourceId $acrResourceId
$acrResourceGroup = Get-ResourceIdResourceGroup -ResourceId $acrResourceId
$acrName = Get-ResourceIdName -ResourceId $acrResourceId
$agentSubnetSubscriptionId = Get-ResourceIdSubscription -ResourceId $agentSubnetResourceId
$agentSubnetResourceGroup = Get-ResourceIdResourceGroup -ResourceId $agentSubnetResourceId
$vnetName = Get-SubnetVirtualNetworkName -SubnetId $agentSubnetResourceId
$subnetName = Get-ResourceIdName -ResourceId $agentSubnetResourceId
$vnetResourceId = $agentSubnetResourceId.Substring(0, $agentSubnetResourceId.LastIndexOf("/subnets/"))
$applicationInsightsSubscriptionId = Get-ResourceIdSubscription -ResourceId $applicationInsightsResourceId
$applicationInsightsResourceGroup = Get-ResourceIdResourceGroup -ResourceId $applicationInsightsResourceId
$applicationInsightsName = Get-ResourceIdName -ResourceId $applicationInsightsResourceId
$logAnalyticsWorkspaceResourceId = "/subscriptions/$applicationInsightsSubscriptionId" +
    "/resourceGroups/$applicationInsightsResourceGroup" +
    "/providers/Microsoft.OperationalInsights/workspaces/$logAnalyticsWorkspaceName"

$mode = "preview"
if ($Apply.IsPresent) {
    $mode = "apply"
}

Write-Host @"
Mode:                         $mode
Creation subscription:        $resourceSubscriptionId
Location for new resources:   $location
Resource group action:        reuse if present; create if missing
Hosting identity action:      reuse if present; create if missing
Workload identity action:     reuse if present; create if missing
Storage account action:       reuse if present; create if missing
Container registry action:    reuse if present; create if missing
Agent subnet action:          reuse if present; create if missing
Application Insights action:  reuse supplied component; otherwise create if missing
AKS action:                   external (read kubelet identity only)

FOUNDRY_RESOURCE_GROUP_ID=$foundryResourceGroupId
AKS_RESOURCE_ID=$aksResourceId
HOSTING_IDENTITY_RESOURCE_ID=$hostingIdentityResourceId
WORKLOAD_IDENTITY_RESOURCE_ID=$workloadIdentityResourceId
STORAGE_ACCOUNT_RESOURCE_ID=$storageAccountResourceId
ACR_RESOURCE_ID=$acrResourceId
AGENT_SUBNET_RESOURCE_ID=$agentSubnetResourceId
APPLICATIONINSIGHTS_RESOURCE_ID=$applicationInsightsResourceId
"@

if (-not $Apply.IsPresent) {
    Write-Host ""
    Write-Host "Preview only. Re-run with -Apply to create missing resources and role assignments."
    exit 0
}

if ($null -eq (Get-Command "az" -ErrorAction SilentlyContinue)) {
    throw "Azure CLI is required with -Apply."
}

Ensure-AzdEnvironment

Invoke-LoggedCommand -Command "az" -Arguments @(
    "account", "set",
    "--subscription", $resourceSubscriptionId
)

$kubeletPrincipalId = Invoke-NativeCapture -Command "az" -Arguments @(
    "aks", "show",
    "--subscription", $aksSubscriptionId,
    "--resource-group", $aksResourceGroup,
    "--name", $aksName,
    "--query", "identityProfile.kubeletidentity.objectId",
    "-o", "tsv"
)
if ([string]::IsNullOrWhiteSpace($kubeletPrincipalId)) {
    throw "AKS cluster does not expose a kubelet managed identity: $aksResourceId"
}

if (-not (Test-AzCommand -Arguments @(
    "group", "show",
    "--subscription", $resourceSubscriptionId,
    "--name", $resourceGroup,
    "--output", "none"
))) {
    Invoke-LoggedCommand -Command "az" -Arguments @(
        "group", "create",
        "--subscription", $resourceSubscriptionId,
        "--name", $resourceGroup,
        "--location", $location,
        "--output", "none"
    )
}
else {
    Write-Host "Reusing resource group: $foundryResourceGroupId"
}

if (-not (Test-AzCommand -Arguments @(
    "identity", "show",
    "--ids", $hostingIdentityResourceId,
    "--output", "none"
))) {
    Invoke-LoggedCommand -Command "az" -Arguments @(
        "identity", "create",
        "--subscription", $hostingIdentitySubscriptionId,
        "--resource-group", $hostingIdentityResourceGroup,
        "--name", $hostingIdentityName,
        "--location", $location,
        "--output", "none"
    )
}
else {
    Write-Host "Reusing hosting identity: $hostingIdentityResourceId"
}

if (-not (Test-AzCommand -Arguments @(
    "identity", "show",
    "--ids", $workloadIdentityResourceId,
    "--output", "none"
))) {
    Invoke-LoggedCommand -Command "az" -Arguments @(
        "identity", "create",
        "--subscription", $workloadIdentitySubscriptionId,
        "--resource-group", $workloadIdentityResourceGroup,
        "--name", $workloadIdentityName,
        "--location", $location,
        "--output", "none"
    )
}
else {
    Write-Host "Reusing workload identity: $workloadIdentityResourceId"
}

if (-not (Test-AzCommand -Arguments @(
    "storage", "account", "show",
    "--ids", $storageAccountResourceId,
    "--output", "none"
))) {
    Invoke-LoggedCommand -Command "az" -Arguments @(
        "storage", "account", "create",
        "--subscription", $storageAccountSubscriptionId,
        "--resource-group", $storageAccountResourceGroup,
        "--name", $storageAccountName,
        "--location", $location,
        "--kind", "StorageV2",
        "--sku", "Standard_LRS",
        "--https-only", "true",
        "--min-tls-version", "TLS1_2",
        "--allow-blob-public-access", "false",
        "--public-network-access", "Enabled",
        "--default-action", "Allow",
        "--output", "none"
    )
}
else {
    Write-Host "Reusing storage account: $storageAccountResourceId"
}

if (-not (Test-AzCommand -Arguments @(
    "monitor", "app-insights", "component", "show",
    "--ids", $applicationInsightsResourceId,
    "--output", "none"
))) {
    if ($applicationInsightsWasProvided) {
        throw "APPLICATIONINSIGHTS_RESOURCE_ID does not identify an existing Application Insights resource: " +
            $applicationInsightsResourceId
    }

    if (-not (Test-AzCommand -Arguments @(
        "monitor", "log-analytics", "workspace", "show",
        "--subscription", $applicationInsightsSubscriptionId,
        "--resource-group", $applicationInsightsResourceGroup,
        "--workspace-name", $logAnalyticsWorkspaceName,
        "--output", "none"
    ))) {
        Invoke-LoggedCommand -Command "az" -Arguments @(
            "monitor", "log-analytics", "workspace", "create",
            "--subscription", $applicationInsightsSubscriptionId,
            "--resource-group", $applicationInsightsResourceGroup,
            "--workspace-name", $logAnalyticsWorkspaceName,
            "--location", $applicationInsightsLocation,
            "--sku", "PerGB2018",
            "--retention-time", "90",
            "--output", "none"
        )
    }

    Invoke-LoggedCommand -Command "az" -Arguments @(
        "monitor", "app-insights", "component", "create",
        "--subscription", $applicationInsightsSubscriptionId,
        "--resource-group", $applicationInsightsResourceGroup,
        "--app", $applicationInsightsName,
        "--location", $applicationInsightsLocation,
        "--kind", "web",
        "--application-type", "web",
        "--workspace", $logAnalyticsWorkspaceResourceId,
        "--output", "none"
    )
}
else {
    Write-Host "Reusing Application Insights: $applicationInsightsResourceId"
}

$applicationInsightsConnectionString = Invoke-NativeCapture -Command "az" -Arguments @(
    "monitor", "app-insights", "component", "show",
    "--ids", $applicationInsightsResourceId,
    "--query", "connectionString",
    "-o", "tsv"
)
if ([string]::IsNullOrWhiteSpace($applicationInsightsConnectionString)) {
    throw "Application Insights did not return a connection string: $applicationInsightsResourceId"
}

if (-not (Test-AzCommand -Arguments @(
    "acr", "show",
    "--subscription", $acrSubscriptionId,
    "--resource-group", $acrResourceGroup,
    "--name", $acrName,
    "--output", "none"
))) {
    Invoke-LoggedCommand -Command "az" -Arguments @(
        "acr", "create",
        "--subscription", $acrSubscriptionId,
        "--resource-group", $acrResourceGroup,
        "--name", $acrName,
        "--location", $location,
        "--sku", "Basic",
        "--admin-enabled", "false",
        "--output", "none"
    )
}
else {
    Write-Host "Reusing container registry: $acrResourceId"
}

$azureContainerRegistryEndpoint = Invoke-NativeCapture -Command "az" -Arguments @(
    "acr", "show",
    "--subscription", $acrSubscriptionId,
    "--resource-group", $acrResourceGroup,
    "--name", $acrName,
    "--query", "loginServer",
    "-o", "tsv"
)
if ([string]::IsNullOrWhiteSpace($azureContainerRegistryEndpoint)) {
    throw "Container registry did not return a login server: $acrResourceId"
}

if (-not (Test-AzCommand -Arguments @(
    "network", "vnet", "show",
    "--ids", $vnetResourceId,
    "--output", "none"
))) {
    Invoke-LoggedCommand -Command "az" -Arguments @(
        "network", "vnet", "create",
        "--subscription", $agentSubnetSubscriptionId,
        "--resource-group", $agentSubnetResourceGroup,
        "--name", $vnetName,
        "--location", $location,
        "--address-prefixes", $vnetPrefix,
        "--output", "none"
    )
}

if (-not (Test-AzCommand -Arguments @(
    "network", "vnet", "subnet", "show",
    "--subscription", $agentSubnetSubscriptionId,
    "--resource-group", $agentSubnetResourceGroup,
    "--vnet-name", $vnetName,
    "--name", $subnetName,
    "--output", "none"
))) {
    Invoke-LoggedCommand -Command "az" -Arguments @(
        "network", "vnet", "subnet", "create",
        "--subscription", $agentSubnetSubscriptionId,
        "--resource-group", $agentSubnetResourceGroup,
        "--vnet-name", $vnetName,
        "--name", $subnetName,
        "--address-prefixes", $subnetPrefix,
        "--delegations", "Microsoft.App/environments",
        "--output", "none"
    )
}
else {
    Write-Host "Reusing agent subnet: $agentSubnetResourceId"
}

$hostingPrincipalId = Invoke-NativeCapture -Command "az" -Arguments @(
    "identity", "show",
    "--ids", $hostingIdentityResourceId,
    "--query", "principalId",
    "-o", "tsv"
)
$workloadPrincipalId = Invoke-NativeCapture -Command "az" -Arguments @(
    "identity", "show",
    "--ids", $workloadIdentityResourceId,
    "--query", "principalId",
    "-o", "tsv"
)

$readerRoleId = "acdd72a7-3385-48ef-bd42-f606fba81ae7"
$aksContributorRoleId = "ed7f3fbd-7b88-4dd4-9017-9adb7ce333f8"
$federatedIdentityCredentialContributorRoleId = "7e559ce2-48d7-4b27-9128-fa1b247f1308"
$storageBlobDataContributorRoleId = "ba92f5b4-2d11-453d-a403-e96b0029c9fe"
$aksRbacClusterAdminRoleId = "b1ff04bb-8a4e-4dc4-8eb5-8693973ce19b"
$acrPullRoleId = "7f951dda-4ed3-4680-a7ca-43fe172d538d"
$containerRegistryRepositoryReaderRoleId = "b93aa761-3e63-49ed-ac28-beffa264f7ac"

$acrRoleAssignmentMode = Invoke-NativeCapture -Command "az" -Arguments @(
    "acr", "show",
    "--subscription", $acrSubscriptionId,
    "--resource-group", $acrResourceGroup,
    "--name", $acrName,
    "--query", "roleAssignmentMode",
    "-o", "tsv"
)

switch ($acrRoleAssignmentMode) {
    { $_ -in @("AbacRepositoryPermissions", "rbac-abac") } {
        $registryPullRoleId = $containerRegistryRepositoryReaderRoleId
        break
    }
    { [string]::IsNullOrEmpty($_) -or $_ -in @("LegacyRegistryPermissions", "legacy-registry-permissions") } {
        $registryPullRoleId = $acrPullRoleId
        break
    }
    default {
        throw "Unsupported ACR role assignment mode '$acrRoleAssignmentMode': $acrResourceId"
    }
}

Ensure-RoleAssignment -Scope $foundryResourceGroupId -PrincipalId $hostingPrincipalId -RoleId $readerRoleId
Ensure-RoleAssignment -Scope $aksResourceId -PrincipalId $hostingPrincipalId -RoleId $aksContributorRoleId
Ensure-RoleAssignment -Scope $aksResourceId -PrincipalId $hostingPrincipalId -RoleId $aksRbacClusterAdminRoleId
Ensure-RoleAssignment -Scope $acrResourceId -PrincipalId $kubeletPrincipalId -RoleId $registryPullRoleId
Ensure-RoleAssignment `
    -Scope $workloadIdentityResourceId `
    -PrincipalId $hostingPrincipalId `
    -RoleId $federatedIdentityCredentialContributorRoleId
Ensure-RoleAssignment `
    -Scope $storageAccountResourceId `
    -PrincipalId $workloadPrincipalId `
    -RoleId $storageBlobDataContributorRoleId

Write-AzdEnvironment

Write-Host ""
Write-Host "All required Azure resources have been created successfully, and the necessary permissions have been granted."
