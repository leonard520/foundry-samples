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

When prompted for a Foundry project, choose **Create a new project**. This
manifest is a greenfield BYO AKS template: its `agentHosting` block provisions
the account-level AKS runtime binding and cannot be combined with an existing
project `endpoint`.

`--deploy-mode container` is required so init removes any detected Python
`codeConfiguration` and keeps this as an image-based deployment.

## Configure BYO AKS resources

Set each value to the full Azure resource ID of the existing resource:

```bash
azd env set AKS_RESOURCE_ID "<aks-resource-id>"
azd env set AGENT_SUBNET_RESOURCE_ID "<agent-subnet-resource-id>"
azd env set HOSTING_IDENTITY_RESOURCE_ID "<hosting-management-identity-resource-id>"
azd env set STORAGE_ACCOUNT_RESOURCE_ID "<storage-account-resource-id>"
azd env set WORKLOAD_IDENTITY_RESOURCE_ID "<workload-identity-resource-id>"
azd env set AZURE_AI_MODEL_DEPLOYMENT_NAME "gpt-5.4-mini"
azd env set AZD_AGENT_SKIP_ACR false
```

The manifest declares a `gpt-5.4-mini` model deployment. If the active Foundry
project already has a compatible deployment with a different name, set
`AZURE_AI_MODEL_DEPLOYMENT_NAME` to that deployment name instead.

## Provision and deploy with an ACR remote build

```bash
azd provision
azd deploy
azd ai agent invoke "Hi"
```

The `ai-project` service provisions the Foundry project configuration, BYO AKS
hosting binding, and model deployment. Because BYO AKS does not support
code-based agent deployment, the `agent-framework-agent-basic-responses-byoaks`
service uses `language: docker`, targets `linux/amd64`, and sets
`docker.remoteBuild: true`. `AZD_AGENT_SKIP_ACR=false` ensures azd uses the
configured Azure Container Registry instead of skipping its ACR packaging
path. A normal `azd deploy` then uploads the Docker build context and runs the
build remotely in ACR.

Before deploying, verify the generated Agent service has all three invariants:

```yaml
language: docker
docker:
  platform: linux/amd64
  remoteBuild: true
```

It must not contain `codeConfiguration`. Also verify that
`azd env get-value AZURE_CONTAINER_REGISTRY_ENDPOINT` returns the provisioned
ACR endpoint. If init stamped an `endpoint` onto `services.ai-project`, an
existing project was selected and this greenfield template must be initialized
again with **Create a new project**.

ACR Tasks remote build requires permission for
`Microsoft.ContainerRegistry/registries/scheduleRun/action`. It also requires
an ACR configuration that permits ACR Tasks; a registry with restrictive
network rules may need an ACR task agent pool or a different build service.
