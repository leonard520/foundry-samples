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

## Provision and deploy

```bash
azd provision
azd deploy
azd ai agent invoke "Hi"
```

The `ai-project` service provisions the Foundry project configuration, BYO AKS
hosting binding, and model deployment. Because BYO AKS does not support
code-based agent deployment, the `agent-framework-agent-basic-responses-byoaks`
service uses `language: docker` and Azure Container Registry remote build. The
Docker build context is `src/agent-framework-agent-basic-responses`, and the
resulting image is deployed as a hosted agent using the Responses protocol.
