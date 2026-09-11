#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project_dir="$(cd "${script_dir}/.." && pwd)"
agent_dir="${project_dir}/src/agent-framework-agent-basic-responses"
service_name="agent-framework-agent-basic-responses-byoaks"

registry_endpoint="$(cd "${project_dir}" && azd env get-value AZURE_CONTAINER_REGISTRY_ENDPOINT)"
registry_endpoint="${registry_endpoint#https://}"
registry_endpoint="${registry_endpoint%/}"

if [[ -z "${registry_endpoint}" ]]; then
    echo "AZURE_CONTAINER_REGISTRY_ENDPOINT is not set. Run azd provision first." >&2
    exit 1
fi

registry_name="${registry_endpoint%%.*}"
image_repository="agents/${service_name}"
image_tag="${1:-$(date -u +%Y%m%d%H%M%S)}"
image_name="${image_repository}:${image_tag}"
image_reference="${registry_endpoint}/${image_name}"

echo "Building ${image_reference} with Azure Container Registry..."
(
    cd "${agent_dir}"
    az acr build \
        --registry "${registry_name}" \
        --platform linux/amd64 \
        --image "${image_name}" \
        --file Dockerfile \
        .
)

echo "Deploying ${image_reference} to Microsoft Foundry..."
(
    cd "${project_dir}"
    azd deploy "${service_name}" --from-package "${image_reference}"
)
