# VNet-Isolated Deployment Confirmation

Use this procedure to confirm the parallel `ss-agent-vnets` deployment without
changing or deleting the original `ss-agent-day3` environment.

Do not delete a Sandbox, disk image, Sandbox Group, or Express environment
during confirmation. Sandbox cleanup is always a separate, explicit operator
action.

## 1. Select the deployment

```powershell
$root = (Resolve-Path ".").Path
$deployment = Join-Path $root "deployments\vnet"
$infra = Join-Path $root "infrastructure\terraform-vnet"

az account set --subscription "30501c6c-81f6-41ac-a388-d29cf43a020d"
azd env select state-street-vnets --cwd $deployment --no-prompt
```

Expected deployment:

| Item | Value |
|---|---|
| Resource group | `ss-agent-vnets` |
| Region | `centralus` |
| Foundry account | `ss-vnet-ai-k7fncj` |
| Foundry project | `ss-vnet-project` |
| Hosted Agent | `craigslist-agent-vnet`, version 7 |
| Gateway | `ss-vnet-gateway-k7fncj` |
| Sandbox Group | `ss-vnet-sandbox-group-k7fncj` |
| Sandbox VNet connection | `tools-egress` |

## 2. Confirm public access is disabled

```powershell
az rest --method get --url `
  "https://management.azure.com/subscriptions/30501c6c-81f6-41ac-a388-d29cf43a020d/resourceGroups/ss-agent-vnets/providers/Microsoft.CognitiveServices/accounts/ss-vnet-ai-k7fncj?api-version=2025-06-01" `
  --query "properties.{publicNetworkAccess:publicNetworkAccess,defaultAction:networkAcls.defaultAction}"

az acr show --name ssvnetacrk7fncj `
  --query "{publicNetworkAccess:publicNetworkAccess}"

az rest --method get --url `
  "https://management.azure.com/subscriptions/30501c6c-81f6-41ac-a388-d29cf43a020d/resourceGroups/ss-agent-vnets/providers/Microsoft.App/managedEnvironments/ss-vnet-sandbox-env-k7fncj?api-version=2025-10-02-preview" `
  --query "properties.{publicNetworkAccess:publicNetworkAccess,environmentMode:environmentMode}"
```

Expected values:

```text
Foundry: publicNetworkAccess=Disabled, defaultAction=Deny
ACR: publicNetworkAccess=Disabled
Sandbox environment: publicNetworkAccess=Disabled, environmentMode=Express
```

Application Insights and Log Analytics ingestion/query access must also be
disabled outside the Azure Monitor Private Link Scope.

## 3. Confirm private endpoints and DNS

```powershell
az network private-endpoint list `
  --resource-group ss-agent-vnets `
  --query "[].{name:name,state:privateLinkServiceConnections[0].privateLinkServiceConnectionState.status}" `
  --output table
```

All four endpoints must be approved:

```text
ss-vnet-acr-pe
ss-vnet-foundry-pe
ss-vnet-monitor-pe
ss-vnet-sandbox-env-pe
```

Run the internal network check:

```powershell
pwsh .\scripts\test-vnet-network.ps1
```

Expected:

```text
Private gateway and Sandbox network checks passed.
```

This command executes from the internal Nginx Container App and proves that
both private Sandbox endpoints resolve and return healthy responses.

## 4. Confirm the Hosted Agent and tool routing

The Foundry data plane is private after final lockdown. To repeat the full
public-bootstrap acceptance sequence, run the idempotent deployment:

```powershell
pwsh .\scripts\deploy-vnet.ps1
```

The script:

1. temporarily enables bootstrap access;
2. creates or updates the agent;
3. grants the generated hosted-agent instance identity `Cognitive Services User`;
4. validates private gateway and Sandbox networking;
5. validates Python, governed search, browser automation, and SSE;
6. disables public access again; and
7. reruns the internal private-network checks.

Expected tool results:

| Tool | Expected result |
|---|---|
| Python Sandbox | `CODE_TOOL_OK` and `391` |
| Governed Craigslist search | `SEARCH_TOOL_OK` and a Craigslist URL |
| Private browser Sandbox | `BROWSER_TOOL_OK` and `Example Domain` |

The VNet profile must not register Foundry-managed web search or Foundry-managed
Browser Automation. Those managed tools are replaced by the private Sandbox
adapters.

## 5. Confirm the private Nginx path

```powershell
terraform -chdir="$infra" output -raw foundry_gateway_endpoint
az containerapp show `
  --resource-group ss-agent-vnets `
  --name ss-vnet-gateway-k7fncj `
  --query "{fqdn:properties.configuration.ingress.fqdn,external:properties.configuration.ingress.external,environment:properties.environmentId}"
```

The Container App ingress is external only inside its internal Container Apps
environment. The FQDN is not an internet-reachable public application endpoint.

Inspect `src\gateway\default.conf.template` and confirm:

- the original `Authorization` header is preserved;
- the backend host is the Foundry account;
- proxy buffering and request buffering are disabled;
- HTTP/1.1 streaming is enabled; and
- the read/send timeouts accommodate long-running Responses calls.

## 6. Confirm Sandbox VNet attachment and lifecycle

```powershell
terraform -chdir="$infra" output -raw interpreter_sandbox_id
terraform -chdir="$infra" output -raw browser_sandbox_id
terraform -chdir="$infra" output -raw sandbox_vnet_connection_name
```

Expected Sandbox IDs:

```text
Interpreter: e90b872f-557a-47c5-aacd-7ade7b44a265
Browser:     09ad4db6-f4bb-4fad-bc2c-38751213a047
Connection:  tools-egress
```

Confirm both workloads use:

- private Sandbox ingress through the Express environment;
- the `tools-egress` VNet connection;
- default-deny egress;
- only the approved Craigslist/browser hosts;
- auto-suspend disabled; and
- auto-delete disabled.

## 7. Confirm observability

The deployment test generates model and tool traffic. Application Insights
should contain requests, dependencies, and traces after ingestion delay.

Because public query access is disabled, use a private query path or briefly
enable query access under change control, query the data, and immediately
restore `Disabled`. The September 4, 2026 acceptance run recorded:

```text
traces:       2360
requests:       14
dependencies: 1269
```

Counts are evidence from that acceptance window, not permanent expected values.
New validation only requires non-zero recent records.

## 8. Confirm Terraform drift

```powershell
terraform -chdir="$infra" plan `
  -detailed-exitcode `
  -var="network_access_mode=private" `
  -var="enable_sandbox_deployment=true" `
  -var="allow_registry_token_fallback=true"
```

Expected:

```text
No changes. Your infrastructure matches the configuration.
```

Also confirm the original deployment remains unchanged:

```powershell
terraform -chdir=".\infrastructure\terraform" plan -detailed-exitcode
```

Both commands must exit with code `0`.

## 9. Confirm the original profile still works

```powershell
pwsh .\scripts\smoke-test.ps1
pwsh .\scripts\test-agent-streaming.ps1
pwsh .\scripts\test-agent-tools.ps1
```

The original `ss-agent-day3` APIM, Bing-backed search, managed Playwright, and
Python paths must continue to pass.

## Sign-off criteria

The VNet deployment passes when:

- Hosted Agent version 7 is active;
- all three private-profile tool checks pass;
- Foundry, ACR, monitoring, and Sandbox environment public access is disabled;
- all private endpoints are approved;
- the gateway reaches both private Sandbox endpoints;
- Application Insights contains recent agent telemetry;
- both Terraform roots report zero drift;
- the original profile regression tests pass; and
- no existing Sandbox was deleted implicitly.
