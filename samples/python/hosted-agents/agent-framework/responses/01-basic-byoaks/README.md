# Basic Hosted Agent on BYO AKS

This sample combines the basic Python Agent Framework Responses agent with a
Microsoft Foundry project configured to use customer-managed AKS agent hosting.
The `azure.yaml` is a unified project manifest, so `azd ai agent init` downloads
this sample's referenced source files without cloning the full repository.

## Initialize from GitHub

```bash
mkdir my-basic-byoaks-agent
cd my-basic-byoaks-agent

azd ai agent init \
  --deploy-mode container \
  -m https://github.com/leonard520/foundry-samples/blob/main/samples/python/hosted-agents/agent-framework/responses/01-basic-byoaks/azure.yaml
```

Keep `--deploy-mode container` when automating initialization. Without it,
non-interactive `azd ai agent init` defaults detected Python projects back to
code deployment, which is not supported by BYO AKS agent hosting.

## Configure BYO AKS resources

Set each value to the full Azure resource ID of the existing resource:

```bash
azd env set AKS_RESOURCE_ID "<aks-resource-id>"
azd env set AGENT_SUBNET_RESOURCE_ID "<agent-subnet-resource-id>"
azd env set HOSTING_IDENTITY_RESOURCE_ID "<hosting-management-identity-resource-id>"
azd env set STORAGE_ACCOUNT_RESOURCE_ID "<storage-account-resource-id>"
azd env set WORKLOAD_IDENTITY_RESOURCE_ID "<workload-identity-resource-id>"
azd env set AZURE_AI_MODEL_DEPLOYMENT_NAME "gpt-5.4-mini"
```

The manifest declares a `gpt-5.4-mini` model deployment. If the active Foundry
project already has a compatible deployment with a different name, set
`AZURE_AI_MODEL_DEPLOYMENT_NAME` to that deployment name instead.

## Provision and deploy with an ACR remote build

```bash
azd provision
bash ./scripts/deploy-remote.sh
azd ai agent invoke "Hi"
```

The `ai-project` service provisions the Foundry project configuration, BYO AKS
hosting binding, and model deployment. Because BYO AKS does not support
code-based agent deployment, the `agent-framework-agent-basic-responses-byoaks`
service uses a container image.

For an existing network-injected Foundry project, `azd ai agent init` disables
its built-in source-container remote build and a plain `azd deploy` requires a
local Docker daemon. `scripts/deploy-remote.sh` avoids that path: it submits the
Dockerfile and source context to Azure Container Registry with `az acr build`,
then passes the resulting image directly to `azd deploy --from-package`.

The script defaults to a UTC timestamp image tag. To provide a tag explicitly:

```bash
bash ./scripts/deploy-remote.sh my-tag
```

ACR Tasks remote build requires permission for
`Microsoft.ContainerRegistry/registries/scheduleRun/action`. It also requires
an ACR configuration that permits ACR Tasks; a registry with restrictive
network rules may need an ACR task agent pool or a different build service.
