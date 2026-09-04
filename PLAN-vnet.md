# VNet-Isolated Agent Architecture: Tactical Delivery Plan

## Purpose

Create a second, parallel deployment of the Craigslist Agent that represents a
State Street-style hub-and-spoke network architecture.

The new deployment must:

- use Terraform as the infrastructure source of truth;
- deploy into the new resource group `ss-agent-vnets`;
- keep the currently deployed `ss-agent-day3` environment unchanged;
- use the existing Craigslist Agent as the application baseline;
- place the Foundry Hosted Agent runtime in an injected VNet;
- make controllable backend paths private;
- replace APIM with an internal Nginx-based pass-through gateway;
- make the Python code-interpreter Sandbox endpoint private;
- keep browser automation and search functional through explicitly designed
  private tool adapters or documented network exceptions;
- provide end-to-end deployment, network, tool, and observability tests; and
- publish the implementation and operational documentation to the repository.

## Implementation status - September 4, 2026

The infrastructure, Hosted Agent, internal Nginx gateway, private interpreter
Sandbox, private browser Sandbox, governed Craigslist search, private
monitoring path, automated tests, and final network lockdown are deployed.

Acceptance testing showed that the Hosted Agent Responses endpoint follows the
Foundry account network policy: after `publicNetworkAccess=Disabled`, requests
from outside the private network return `403` and require private endpoint
reachability. The earlier assumption that this endpoint remained a public
platform exception was not true for this deployment and is superseded below.

The current application baseline is tagged:

```text
agent-framework-CL-agent
```

at commit:

```text
aa7fa70a738a6762df15006ecf4a5ab28ceeab53
```

## Feasibility conclusion

A substantially private architecture is implementable, but the exact
requirement "only the UI is reachable and every backend hop is private" cannot
currently be met without replacing or constraining some managed Foundry
features.

| Requirement | Verified platform position on September 4, 2026 | Plan |
|---|---|---|
| Hosted Agent runtime egress through a customer VNet | Supported through Foundry account-level network injection | Use a dedicated `/24` agent subnet |
| Foundry account/project/model data plane | Supported through an account-level private endpoint | Disable public network access and create/link required private DNS |
| Dedicated Hosted Agent invocation endpoint | Follows the Foundry account network policy and returns `403` outside the private network after lockdown | Invoke from a private client path and require Entra authentication |
| Python Sandbox ingress | Supported through an Express Container Apps environment private endpoint | Link a new Sandbox Group to a private Express environment |
| Sandbox egress through a customer VNet | Supported through Sandbox Group `vnetConnections` | Attach a dedicated `/23` delegated subnet |
| Built-in Foundry Browser Automation in a network-isolated project | Not supported | Make the existing self-hosted Playwright MCP Sandbox the active browser tool |
| Playwright Workspace VNet injection | Preview `subnetId` support exists, but does not remove the Foundry Browser Automation limitation | Keep as an optional experiment, not the primary browser design |
| Foundry Bing-backed web search in a strict private network | Uses Microsoft-managed public service paths and does not respect customer private endpoints | Replace with a private search MCP adapter plus controlled firewall egress, or disable it in strict mode |
| Work IQ in a network-isolated Foundry project | Not supported | Do not claim Work IQ support in the private profile without a supported customer endpoint |

## Recommended implementation profile

Use a **private-by-default reference profile with two explicitly documented
egress dependencies**:

1. Public-web search requires controlled outbound access from a private search
   adapter; it cannot be private end-to-end because the target is the public web.
2. Azure control-plane and Entra authentication endpoints remain public
   platform dependencies.

Everything else under customer control should use private addressing, private
DNS, VNet peering, managed identity, and public network access disabled where
the service supports it.

## Target topology

```text
Authorized user
      |
      v
Application Gateway WAF v2 (only public application endpoint)
      |
      v
Internal agent UI/backend in ingress spoke
      |
      +------ Entra/TLS ------> Hosted Agent invocation endpoint
                                 (private after Foundry lockdown)
                                         |
                                         v
                         Foundry Hosted Agent injected subnet
                                         |
                  +----------------------+-----------------------+
                  |                      |                       |
                  v                      v                       v
         Internal Nginx gateway   Private Python MCP     Private browser MCP
                  |                 ACA Sandbox             ACA Sandbox
                  v                      |                       |
       Foundry account private           +-----------+-----------+
       endpoint and model                            |
                                                   v
                                      Sandbox Group VNet egress
                                                   |
                                                   v
                                       Hub firewall/private services
```

### Network layout

Use non-overlapping RFC 1918 address spaces. Treat these as defaults and expose
them as Terraform variables.

| Network | Default address space | Purpose |
|---|---|---|
| Hub VNet | `10.60.0.0/16` | Central DNS, routing, optional Azure Firewall, VPN/ExpressRoute integration |
| Ingress spoke | `10.61.0.0/16` | Application Gateway and private UI/backend |
| Agent spoke | `10.62.0.0/16` | Foundry Hosted Agent injected subnet and Foundry private endpoints |
| Tools spoke | `10.63.0.0/16` | Internal Nginx gateway, Express environment private endpoint, Sandbox egress, browser/search tools |
| Shared-services spoke | `10.64.0.0/16` | ACR, Key Vault, Monitor Private Link Scope, Storage, and other shared private endpoints |

Recommended subnets:

| Subnet | Default CIDR | Configuration |
|---|---|---|
| `snet-appgw` | `10.61.0.0/24` | Application Gateway only |
| `snet-ui-aca` | `10.61.2.0/23` | Workload-profile ACA environment for the UI/backend |
| `snet-foundry-agent` | `10.62.0.0/24` | Dedicated Foundry injection; delegate to `Microsoft.App/environments` |
| `snet-foundry-pe` | `10.62.2.0/27` | Foundry private endpoints |
| `snet-tools-aca` | `10.63.0.0/23` | Internal ACA environment for Nginx/search services |
| `snet-sandbox-egress` | `10.63.4.0/23` | Empty Sandbox Group VNet connection subnet; delegate as required |
| `snet-sandbox-pe` | `10.63.6.0/27` | Express environment private endpoint |
| `snet-shared-pe` | `10.64.0.0/24` | ACR, Key Vault, Storage, and monitoring private endpoints |

Do not place unrelated workloads in the Foundry injection subnet or Sandbox
egress subnet.

## Repository and state strategy

### Preserve the existing deployment

- Do not rename, move, import, or modify resources in `ss-agent-day3`.
- Do not reuse its Terraform state.
- Do not change the current Hosted Agent version as part of the VNet work.
- Do not delete either existing Sandbox.
- Keep `agent-framework-CL-agent` as the immutable baseline tag.

### Create a parallel Terraform root

Add:

```text
infrastructure/terraform-vnet/
|-- backend.tf
|-- data.tf
|-- locals.tf
|-- main.tf
|-- networking.tf
|-- private-dns.tf
|-- foundry.tf
|-- gateway.tf
|-- sandbox.tf
|-- ui.tf
|-- observability.tf
|-- role-assignments.tf
|-- outputs.tf
|-- variables.tf
|-- versions.tf
|-- terraform.tfvars.example
`-- policies/
```

Use a separate remote-state key such as:

```text
foundry-agent/ss-agent-vnets.tfstate
```

Do not perform high-risk state work in a local state file inside OneDrive.

### ACA module boundary

Do not consume the current local
`express-end-to-end-feature-test\terraform-provider-aca` checkout directly. It
contains unrelated uncommitted Express work.

Use:

- a clean, pinned upstream ACA module commit for stable VNet, managed
  environment, and Container App primitives;
- AzureRM for standard VNets, peerings, private endpoints, DNS, ACR, monitoring,
  identities, and Application Gateway;
- AzAPI for Foundry network injection, Sandbox Groups, Sandbox Group
  `vnetConnections`, Express-mode properties, and preview properties that
  AzureRM does not support; and
- ACA CLI/data-plane scripts for individual Sandbox disk and Sandbox creation.

Record every module commit and API version in `.terraform.lock.hcl` or source
URLs. Do not use an unpinned `main` branch.

## Tactical work breakdown

## Phase 0: Repository baseline and implementation branch

### T0.1 Confirm the baseline

- [x] Confirm `main` is clean and synchronized with `origin/main`.
- [x] Create annotated tag `agent-framework-CL-agent`.
- [ ] Push the tag with the completed VNet implementation.
- [ ] Record the existing resource group, agent version, Sandbox IDs, endpoints,
  and zero-drift result in `CONFIRM-vnet.md`.

Exit criterion:

- the existing deployment is reproducible and can be compared after every VNet
  deployment step.

### T0.2 Create the work branch

- [ ] Fetch `origin`.
- [ ] Create `feature/state-street-vnet-architecture` from `main`.
- [ ] Confirm the ACA module's dirty checkout is not referenced from Terraform.
- [ ] Add the new Terraform root without modifying existing Terraform resource
  addresses.

Exit criterion:

- all new work is isolated from the existing deployment and module WIP.

## Phase 1: Resolve the platform feasibility gates

Complete these spikes before building the full topology.

### T1.1 Hosted Agent private-network spike

- [ ] Create a minimal temporary Foundry account using account-level
  `networkInjections` with scenario `agent`.
- [ ] Use a dedicated subnet delegated to `Microsoft.App/environments`.
- [ ] Create the Foundry account private endpoint and required private DNS zones.
- [ ] Disable Foundry public network access.
- [ ] Deploy a minimal Hosted Agent revision.
- [ ] Test project/model resolution from inside and outside the peered VNets.
- [x] Confirm the dedicated Hosted Agent invocation endpoint returns `403`
  outside the private network after Foundry lockdown.
- [ ] Capture DNS results, HTTP status, effective routes, and service limitations.
- [ ] Remove only the temporary spike resources after explicit review.

Decision gate:

- continue with Hosted Agents because the invocation endpoint is governed by
  the Foundry private-network policy in this deployment.

### T1.2 Sandbox private-ingress spike

- [ ] Create an Express Container Apps managed environment.
- [ ] Create its private endpoint using group ID `managedEnvironments`.
- [ ] Create/link `privatelink.<region>.azurecontainerapps.io`.
- [ ] Wait for private endpoint approval.
- [ ] Disable managed-environment public network access.
- [ ] Create a new Sandbox Group.
- [ ] Set `properties.environmentId` once to the Express environment.
- [ ] Create a test Sandbox port.
- [ ] Confirm private DNS resolves to the shared private endpoint.
- [ ] Confirm the port works from a peered VNet.
- [ ] Confirm it fails from an unconnected public client.

Decision gate:

- do not continue if the target region does not support the required stable or
  preview API contract.

### T1.3 Sandbox egress spike

- [ ] Create `Microsoft.App/sandboxGroups/vnetConnections`.
- [ ] Attach the dedicated Sandbox egress subnet.
- [ ] Create a Sandbox with `CustomerVnetConnectionName`.
- [ ] Confirm the connection is immutable for the Sandbox.
- [ ] Reach a private test endpoint through the VNet connection.
- [ ] Confirm default-deny policy blocks unapproved hosts.
- [ ] Confirm hub UDR/firewall handling does not break Sandbox control traffic.

### T1.4 Browser decision

- [ ] Prove that built-in Browser Automation is rejected or unavailable in the
  network-isolated project.
- [ ] Promote the existing self-hosted Playwright MCP image to the active browser
  implementation.
- [ ] Test Chromium startup and access to private/public approved targets from
  the Sandbox VNet connection.
- [ ] Keep Azure Playwright Workspace VNet injection as an optional experiment,
  not a dependency of the primary design.

### T1.5 Search decision

- [ ] Confirm whether State Street can provide a private WebIQ/search endpoint.
- [ ] If available, define its private DNS, authentication, and response contract.
- [ ] Otherwise create a private search MCP adapter in the tools spoke.
- [ ] Route adapter internet egress through Azure Firewall/NAT with an explicit
  allow-list and logging.
- [ ] Mark this as a controlled public-egress exception.
- [ ] Provide a strict mode that disables search entirely.

Exit criterion for Phase 1:

- each unsupported requirement has an accepted replacement or documented
  exception before production Terraform is written.

## Phase 2: Bootstrap remote Terraform state

### T2.1 Add a bootstrap stack

Add:

```text
infrastructure/terraform-vnet-bootstrap/
```

Create:

- [ ] state resource group;
- [ ] storage account with public access disabled where the execution environment
  can support private access;
- [ ] state container;
- [ ] versioning and soft delete;
- [ ] state access RBAC; and
- [ ] optional private endpoint/private DNS for the state account.

### T2.2 Configure the main backend

- [ ] Add `backend.tf`.
- [ ] Use key `foundry-agent/ss-agent-vnets.tfstate`.
- [ ] Document backend initialization parameters.
- [ ] Verify state locking and version recovery.
- [ ] Ensure plans and state are excluded from Git.

Exit criterion:

- two concurrent Terraform writers cannot modify the deployment and a previous
  state version can be restored.

## Phase 3: Hub-and-spoke networking

### T3.1 Create network resources

- [ ] Create hub, ingress, agent, tools, and shared-services VNets.
- [ ] Create all required subnets with explicit address prefixes.
- [ ] Add required subnet delegations.
- [ ] Create bidirectional hub/spoke peerings.
- [ ] Disable unnecessary direct spoke-to-spoke peering.
- [ ] Configure route tables so controlled egress crosses the hub.
- [ ] Add NSGs with least-privilege rules.
- [ ] Enable VNet flow logs where supported.

### T3.2 Central DNS

- [ ] Create/link private DNS zones for:
  - [ ] `privatelink.services.ai.azure.com`;
  - [ ] `privatelink.openai.azure.com`;
  - [ ] `privatelink.cognitiveservices.azure.com`;
  - [ ] `privatelink.azurecr.io`;
  - [ ] `privatelink.<region>.azurecontainerapps.io`;
  - [ ] Key Vault, Storage, Search, Cosmos DB, and monitoring zones actually used.
- [ ] Link zones to every VNet that must resolve them.
- [ ] Add Azure DNS Private Resolver when on-premises resolution is in scope.
- [ ] Document conditional forwarders for corporate DNS.

### T3.3 Egress control

- [ ] Decide whether the sample deploys Azure Firewall or accepts a supplied hub
  firewall ID.
- [ ] Prefer an input for an existing enterprise firewall; make sample firewall
  creation optional because of cost.
- [ ] Configure UDRs for UI/backend, gateway, browser, and search adapter subnets.
- [ ] Add only required service tags/FQDN rules.
- [ ] Do not perform TLS interception on Foundry runtime traffic.

Exit criterion:

- private DNS and routing tests pass before Foundry or Sandbox workloads are
  deployed.

## Phase 4: Shared private services

### T4.1 ACR

- [ ] Create a new Premium ACR for `ss-agent-vnets`.
- [ ] Disable admin credentials and anonymous pull.
- [ ] Create a private endpoint in the shared-services spoke.
- [ ] Link `privatelink.azurecr.io`.
- [ ] Disable public network access after the private build/pull path is proven.
- [ ] Grant only required identities `AcrPull` or build permissions.

### T4.2 Secrets

- [ ] Create Key Vault with RBAC authorization.
- [ ] Create a private endpoint and private DNS.
- [ ] Disable public access after deployment access is proven.
- [ ] Keep MCP tokens and UI secrets out of Terraform command arguments and logs.
- [ ] Prefer managed identity and Key Vault references over environment-value
  copies.

### T4.3 Observability

- [ ] Create Log Analytics and Application Insights.
- [ ] Create Azure Monitor Private Link Scope when strict private ingestion/query
  is required.
- [ ] Connect Application Insights to Foundry.
- [ ] Add diagnostic settings for VNets, private endpoints, Application Gateway,
  Container Apps, ACR, and Key Vault.
- [ ] Decide whether public Azure Monitor ingestion/query is an accepted
  management-plane exception.

Exit criterion:

- ACR, secrets, and telemetry are reachable through approved private paths.

## Phase 5: Network-isolated Foundry account and project

### T5.1 Foundry account

- [ ] Create a new `AIServices` account in `ss-agent-vnets`.
- [ ] Use a current validated management API such as
  `Microsoft.CognitiveServices/accounts@2026-05-01`.
- [ ] Configure:

```json
{
  "publicNetworkAccess": "Disabled",
  "networkAcls": {
    "defaultAction": "Deny"
  },
  "networkInjections": [
    {
      "scenario": "agent",
      "subnetArmId": "<snet-foundry-agent>",
      "useMicrosoftManagedNetwork": false
    }
  ]
}
```

- [ ] Create the account private endpoint using group ID `account`.
- [ ] Configure all required Foundry/OpenAI/Cognitive Services private DNS zones.
- [ ] Create a new project; do not reuse the pre-June 25, 2026 project.
- [ ] Connect the private ACR and observability resources.
- [ ] Deploy the pinned model and capacity.

### T5.2 RBAC

- [ ] Grant deployer project administration only where required.
- [ ] Grant Hosted Agent/project identities ACR pull and minimum Foundry roles.
- [ ] Grant the Nginx token-broker identity the minimum project/model role.
- [ ] Avoid broad subscription-scoped assignments.
- [ ] Use statically keyed Terraform maps for role assignments.

### T5.3 Network validation

- [ ] Resolve the Foundry hostname from the agent and tools spokes.
- [ ] Confirm the resolved address is private.
- [ ] Confirm model requests succeed from authorized private sources.
- [ ] Confirm project/model requests fail from an unconnected public client.

Exit criterion:

- the project/model data plane and supporting services have no supported public
  access path.

## Phase 6: Internal Nginx gateway

### T6.1 Add gateway source

Add:

```text
src/gateway/
|-- Dockerfile
|-- nginx.conf
|-- token-broker/
|   |-- app.py
|   `-- requirements.txt
`-- health/
```

The design should use:

- Nginx for streaming reverse proxy behavior;
- a localhost token-broker sidecar or companion process using Azure Identity;
- Nginx `auth_request` or an equivalent internal call to obtain a current token;
- `Authorization: Bearer <token>` injected only on the upstream request;
- no subscription keys;
- SSE buffering disabled;
- request/body/time limits;
- correlation IDs; and
- structured access/error logs with token/header redaction.

Do not implement a static token cache in Nginx configuration.

### T6.2 Deploy gateway privately

- [ ] Use a clean, pinned ACA module for the internal managed environment and
  Container App where practical.
- [ ] Deploy the gateway into `snet-tools-aca`.
- [ ] Configure internal-only ingress.
- [ ] Assign a managed identity.
- [ ] Grant minimum Foundry access.
- [ ] Resolve the Foundry backend through its private endpoint.
- [ ] Expose only the internal gateway FQDN/private address to the agent subnet.
- [ ] Add readiness/liveness probes.

### T6.3 Gateway tests

- [ ] Direct internal request streams a complete Foundry response.
- [ ] Nginx preserves SSE and correlation headers.
- [ ] Token acquisition refreshes before expiry.
- [ ] Requests without expected caller/network context are rejected.
- [ ] Gateway is not reachable from the public internet.
- [ ] Foundry backend traffic resolves to a private IP.

Exit criterion:

- the gateway fully replaces APIM for the new deployment without changing the
  old APIM deployment.

## Phase 7: Private ACA Sandbox platform

### T7.1 Express environment private ingress

- [ ] Create a new Express-mode managed environment.
- [ ] Create a private endpoint with group ID `managedEnvironments`.
- [ ] Configure `privatelink.<region>.azurecontainerapps.io`.
- [ ] Approve and validate the private endpoint.
- [ ] Disable environment public network access.

### T7.2 Sandbox Group

- [ ] Create a new Sandbox Group through AzAPI.
- [ ] Link `properties.environmentId` to the Express environment exactly once.
- [ ] Add the Sandbox Group VNet connection through AzAPI.
- [ ] Attach `snet-sandbox-egress`.
- [ ] Assign Sandbox Group Data Owner to the deployment identity.
- [ ] Assign ACR pull to the group managed identity.
- [ ] Add deletion protection and explicit cleanup documentation.

Use a validated API version:

- prefer stable `2026-07-01` after a regional plan/apply spike;
- fall back to `2026-02-01-preview` only if the stable contract is unavailable.

### T7.3 Refactor Sandbox deployment profiles

- [ ] Remove hard-coded `state-street-day3` labels from
  `scripts/deploy-sandbox.ps1`.
- [ ] Add deployment/environment/profile labels as parameters.
- [ ] Add `CustomerVnetConnectionName` to each Sandbox manifest.
- [ ] Derive configuration fingerprints from normalized profile configuration.
- [ ] Select exposed endpoints by named/numbered port, never array position.
- [ ] Preserve existing Sandboxes and add no destroy provisioner.
- [ ] Require pre-authenticated `az` and `aca`.
- [ ] Keep registry-token fallback disabled by default.
- [ ] Ensure temporary manifests are always removed.

### T7.4 Python code interpreter

- [ ] Build the current `src/interpreter` image with `wslc`.
- [ ] Run it locally and execute MCP protocol tests.
- [ ] Publish the immutable image to the new private ACR.
- [ ] Import/reuse the Sandbox disk.
- [ ] Create the Python Sandbox with:
  - [ ] private ingress through the Express environment;
  - [ ] VNet egress connection;
  - [ ] default-deny egress;
  - [ ] only approved private dependencies/hosts;
  - [ ] no auto-delete; and
  - [ ] bearer authentication or a stronger private identity control.
- [ ] Resolve and export the private MCP and health URLs.

### T7.5 Browser MCP

- [ ] Build the current `src/browser` image with `wslc`.
- [ ] Run Chromium/MCP tests locally.
- [ ] Deploy it as the active private browser Sandbox.
- [ ] Restrict egress to explicitly approved browser targets.
- [ ] Confirm it is reachable privately from the Foundry injected subnet.
- [ ] Remove the built-in Playwright Workspace tool from the private agent
  configuration.

### T7.6 Search MCP

- [ ] Add `src/search` only if a private WebIQ endpoint is unavailable.
- [ ] Expose it as a private MCP/OpenAPI tool.
- [ ] Use managed identity or Key Vault-backed credentials.
- [ ] Route public-web requests through controlled hub egress.
- [ ] Log destinations and decisions without logging secrets/query content by
  default.
- [ ] Add a strict mode in which the tool is not registered.

Exit criterion:

- Python, browser, and optional search tools are reachable privately from the
  agent subnet and unreachable publicly.

## Phase 8: Agent and UI changes

### T8.1 Create a separate agent deployment profile

- [ ] Keep `src/agent` shared where behavior is identical.
- [ ] Add explicit environment-driven tool selection:

```text
PRIVATE_FOUNDRY_GATEWAY_ENDPOINT
PYTHON_MCP_SERVER_URL
PYTHON_MCP_AUTH_TOKEN
BROWSER_MCP_SERVER_URL
BROWSER_MCP_AUTH_TOKEN
SEARCH_MCP_SERVER_URL
SEARCH_MCP_AUTH_TOKEN
ENABLE_PRIVATE_BROWSER
ENABLE_PRIVATE_SEARCH
```

- [ ] Point `FoundryChatClient` to the internal Nginx gateway.
- [ ] Register the private Python MCP.
- [ ] Register the private browser MCP instead of built-in Browser Automation.
- [ ] Register the private search adapter when enabled.
- [ ] Preserve tool-specific descriptions and least-privilege allow-lists.
- [ ] Keep browser behavior read-only.
- [ ] Make the active profile visible in telemetry.

### T8.2 Add a second `azure.yaml` service/profile

- [ ] Use a separate Hosted Agent name such as `craigslist-agent-vnet`.
- [ ] Use a separate `azd` environment such as `state-street-vnets`.
- [ ] Ensure deployment cannot overwrite `craigslist-agent` version 4.
- [ ] Export only the new Terraform root's outputs to this environment.
- [ ] Keep secrets out of `azure.yaml` defaults and Git.

### T8.3 User UI

- [ ] Decide whether the deliverable uses the Foundry portal over corporate
  VPN/ExpressRoute or deploys a custom UI.
- [ ] For the complete architecture, add a minimal UI/backend under `src/ui`.
- [ ] Deploy it to an internal ACA environment.
- [ ] Publish only Application Gateway WAF v2.
- [ ] Require Microsoft Entra authentication.
- [ ] Validate session/conversation ownership server-side.
- [ ] Do not send Foundry or MCP credentials to the browser.
- [ ] Do not expose gateway or tool endpoints publicly.

Exit criterion:

- users can reach only the intended UI, while internal gateway and tool endpoints
  remain private. The Hosted Agent platform endpoint exception is documented and
  protected by Entra ID.

## Phase 9: Deployment automation

### T9.1 Add deployment scripts

Add:

```text
scripts/deploy-vnet.ps1
scripts/deploy-vnet-bootstrap.ps1
scripts/test-vnet-networking.ps1
scripts/test-vnet-tools.ps1
scripts/test-vnet-agent.ps1
scripts/query-vnet-observability.ps1
scripts/show-vnet-egress.ps1
```

`deploy-vnet.ps1` should perform:

1. prerequisite/version checks;
2. Azure/ACA authentication checks without interactive login inside Terraform;
3. backend initialization;
4. `terraform fmt -check`;
5. `terraform validate`;
6. saved plan generation;
7. a plan safety check for unexpected deletes/replacements;
8. Terraform apply;
9. local image builds with `wslc` where requested;
10. ACR publication/import;
11. Sandbox deployment and private endpoint discovery;
12. output export to the VNet-specific `azd` environment;
13. Hosted Agent and UI deployment;
14. network isolation tests;
15. tool/end-to-end tests; and
16. final zero-drift plan.

### T9.2 Parameterization

Expose:

- subscription and tenant IDs;
- resource group;
- region;
- address spaces/subnets;
- existing hub/firewall IDs;
- Foundry/model names and capacity;
- whether to deploy a sample firewall;
- whether to deploy a custom UI;
- whether controlled public search is enabled;
- API versions for preview resources;
- module source/version; and
- explicit cleanup/protection controls.

No State Street-specific value should be embedded in reusable scripts except
documented sample defaults.

## Phase 10: Test plan

## Local tests

### T10.1 Existing tests

- [ ] `python -m unittest discover -s tests -v`
- [ ] PowerShell parser validation for all scripts.
- [ ] `node --check src\browser\server.mjs`
- [ ] dependency-lock consistency.

### T10.2 Container tests with `wslc`

- [ ] `wslc version`
- [ ] build the agent image;
- [ ] build/run the Python MCP image;
- [ ] build/run the browser MCP image;
- [ ] build/run Nginx and token broker;
- [ ] build/run the optional search adapter;
- [ ] call `/health`;
- [ ] initialize MCP and list tools;
- [ ] execute `run_python`;
- [ ] launch Chromium and inspect `example.com`; and
- [ ] verify local token/header redaction.

## Terraform tests

### T10.3 Static and plan tests

- [ ] `terraform fmt -check -recursive`
- [ ] `terraform validate`
- [ ] plan from an empty state;
- [ ] plan against the deployed state;
- [ ] assert no references to the dirty local ACA module;
- [ ] assert no broad/public CIDR ingress on gateway/tools;
- [ ] assert Foundry/ACR/Key Vault public access is disabled;
- [ ] assert private DNS links exist;
- [ ] assert no Sandbox data-plane delete commands exist;
- [ ] assert `terraform destroy` is blocked for protected Sandbox resources; and
- [ ] scan the plan for unexpected replacement/deletion.

## Network tests

### T10.4 Positive private-path tests

Run from a VM/runner in the peered network:

- [ ] resolve Foundry, ACR, Key Vault, gateway, Python MCP, and browser MCP names;
- [ ] confirm private IP results;
- [ ] connect to each required port;
- [ ] invoke the gateway and receive a streamed model response;
- [ ] invoke Python MCP;
- [ ] invoke browser MCP;
- [ ] invoke private WebIQ/search adapter if enabled;
- [ ] verify telemetry ingestion; and
- [ ] inspect effective routes and NSG flow logs.

### T10.5 Negative isolation tests

Run from an unconnected public client:

- [ ] Foundry account/project endpoint fails;
- [ ] ACR data plane fails;
- [ ] Key Vault data plane fails;
- [ ] Nginx gateway fails;
- [ ] Python Sandbox port fails;
- [ ] browser Sandbox port fails;
- [ ] search adapter fails;
- [ ] only Application Gateway/UI succeeds; and
- [ ] dedicated Hosted Agent endpoint behavior is recorded as the known platform
  exception.

### T10.6 DNS and routing tests

- [ ] Validate every private DNS A record.
- [ ] Validate links to all required spokes.
- [ ] Validate on-premises conditional forwarding when in scope.
- [ ] Validate next hops through the hub.
- [ ] Confirm no asymmetric route breaks Private Link.
- [ ] Confirm firewall logs show only approved public search/browser destinations.

## End-to-end agent tests

### T10.7 Tool checks

Test tools independently:

```text
Use run_python to calculate 17 * 23 and include CODE_TOOL_OK.
Use private browser automation to open https://example.com and include BROWSER_TOOL_OK.
Use the configured private search adapter to find an official Microsoft Foundry URL and include SEARCH_TOOL_OK.
```

Then test combined routing:

```text
Find current listings through the approved search path, inspect a result through
the private browser tool, use Python to compare the prices, include all source
URLs, and include ALL_PRIVATE_TOOLS_OK.
```

Expected:

- [ ] `391`;
- [ ] `Example Domain`;
- [ ] an approved source URL;
- [ ] all markers;
- [ ] no built-in Browser Automation call;
- [ ] no direct Python/public Sandbox call;
- [ ] no `401`, `403`, DNS, serialization, or response failure; and
- [ ] trace attributes identify the VNet profile.

### T10.8 Existing deployment regression

After the new deployment:

- [ ] run the existing `ss-agent-day3` streaming and tool tests;
- [ ] confirm Hosted Agent version 4 remains available;
- [ ] confirm both original Sandbox IDs remain unchanged;
- [ ] run the original Terraform zero-drift plan; and
- [ ] confirm no shared resource was accidentally adopted by the new state.

Exit criterion:

- both old and new deployments pass independently.

## Phase 11: Observability and operational proof

### T11.1 Telemetry

- [ ] Emit OpenTelemetry spans from UI/backend, gateway, agent, and MCP tools.
- [ ] Carry a correlation ID end-to-end.
- [ ] Record model and tool duration/token metrics.
- [ ] Add network profile, gateway, tool endpoint type, and Sandbox ID attributes.
- [ ] Disable sensitive prompt/response telemetry by default.
- [ ] Query Application Insights for every test marker.

### T11.2 Network evidence

Collect:

- [ ] private endpoint connection states;
- [ ] DNS lookups and private IPs;
- [ ] Application Gateway access logs;
- [ ] gateway access logs;
- [ ] firewall allow/deny decisions;
- [ ] Sandbox egress decisions;
- [ ] VNet/NSG flow evidence; and
- [ ] public negative-test results.

### T11.3 Runbooks

- [ ] identity/RBAC propagation failures;
- [ ] private DNS failures;
- [ ] private endpoint pending/rejected states;
- [ ] Sandbox environment-link failures;
- [ ] Sandbox VNet connection failures;
- [ ] Nginx token refresh failures;
- [ ] Hosted Agent quota/rate limits;
- [ ] browser startup failures;
- [ ] controlled public-search exception failures; and
- [ ] state recovery/rollback.

## Phase 12: Documentation

### T12.1 Repository documentation

- [ ] Add a rendered VNet architecture image.
- [ ] Update `README.md` with both deployment profiles.
- [ ] Add `CONFIRM-vnet.md` with manual end-to-end confirmation.
- [ ] Add a component/network responsibility table.
- [ ] Add address-space and private DNS tables.
- [ ] Document all public/private access decisions.
- [ ] Document the Hosted Agent and web-search exceptions prominently.
- [ ] Document Nginx token-broker behavior.
- [ ] Document strict mode versus controlled-public-search mode.
- [ ] Add deployment, redeployment, rollback, and explicit cleanup instructions.
- [ ] State that Sandbox Group `environmentId` cannot be moved after linking.

### T12.2 Skill comparison

Document:

- the official `aca-sandboxes` skill is the preferred current Sandbox-specific
  operational guide;
- `express-and-sandbox-usage` is broader for Express, logging, REST/Kusto, and
  troubleshooting but lacks Terraform/hub-spoke composition and includes some
  stale Sandbox command guidance;
- `wsl-containers` is the preferred local Linux container build/test workflow
  for this project but does not cover Azure networking; and
- implementation commands must be checked against the current official skill
  and CLI help before use.

## Phase 13: Repository review and publication

### T13.1 Pre-publication review

- [ ] Run a high-confidence code review.
- [ ] Run a security review for exposed endpoints, credentials, proxy headers,
  SSRF, and browser/search egress.
- [ ] Scan tracked/untracked files for tokens, state, plans, manifests, local
  module paths, node modules, and generated profiles.
- [ ] Confirm all Terraform/module sources are pinned.
- [ ] Confirm no `ss-agent-day3` state/resource address changed.
- [ ] Confirm all expected tests and zero-drift plans pass.

### T13.2 Commit and push

- [ ] Stage only intended source, Terraform, tests, images, and documentation.
- [ ] Commit with the required Copilot trailers.
- [ ] Push `feature/state-street-vnet-architecture`.
- [ ] Push tag `agent-framework-CL-agent`.
- [ ] Open a pull request with:
  - [ ] architecture summary;
  - [ ] known platform exceptions;
  - [ ] deployment evidence;
  - [ ] old/new regression results;
  - [ ] private-path/negative-path test evidence; and
  - [ ] cleanup warning.
- [ ] Merge only after review and re-run final plans from `main`.

## Phase 14: Rollback and cleanup

### Rollback

- [ ] Keep `ss-agent-day3` as the working fallback.
- [ ] Disable user routing to the new UI/gateway without deleting resources.
- [ ] Retain the new Terraform state for investigation.
- [ ] Roll back the Hosted Agent/UI image or configuration independently.
- [ ] Do not relink a Sandbox Group to another environment; create a replacement
  group when required.

### Cleanup

Cleanup is never part of a normal failed deployment retry.

Before deleting anything:

- [ ] inventory Sandbox IDs, disks, snapshots, files, volumes, private endpoints,
  DNS records, and state;
- [ ] export required evidence/data;
- [ ] present an explicit resource deletion list;
- [ ] require separate operator approval;
- [ ] delete selected Sandbox data-plane resources explicitly;
- [ ] remove protection only after data-plane cleanup; and
- [ ] destroy the ARM platform last.

## Five implementation decisions

These are the five decisions to settle at the start of implementation. The
recommended defaults are shown.

| # | Decision | Recommended default |
|---|---|---|
| 1 | Keep Foundry Hosted Agents with private Foundry data-plane access | Yes; the deployed Responses endpoint is blocked outside the private network after lockdown |
| 2 | Browser implementation | Use the private self-hosted Playwright MCP Sandbox; disable built-in Browser Automation |
| 3 | Search implementation | Prefer a State Street private WebIQ endpoint; otherwise use a private adapter with controlled public egress and explicit exception |
| 4 | User interface | Deploy a minimal private UI/backend behind public Application Gateway WAF v2 |
| 5 | Hub services | Accept existing hub/firewall/DNS IDs as inputs; make sample creation optional |

If decision 1 is rejected, the architecture must use a customer-hosted Agent
Framework runtime in internal ACA instead of a Foundry Hosted Agent.

## Definition of done

The VNet iteration is complete only when:

- `ss-agent-day3` remains unchanged and functional;
- the new deployment exists entirely in `ss-agent-vnets` and separate state;
- the Foundry Hosted Agent uses the dedicated injected subnet;
- Foundry account/project/model access resolves through private endpoints;
- Nginx replaces APIM for the new model route;
- Nginx and its token broker are internal-only and preserve streaming;
- the Python MCP Sandbox port is private;
- the browser MCP Sandbox is the active browser tool and is private;
- search either uses an approved private endpoint or has a clearly tested
  controlled-public-egress exception;
- only the intended UI/Application Gateway is user-reachable;
- positive private-path and negative public-path tests pass;
- all three functional tool paths pass end-to-end;
- observability and network evidence are available;
- final plans for both Terraform roots report zero drift;
- no Sandbox or existing resource was implicitly deleted;
- documentation and runbooks are complete; and
- the reviewed branch and baseline tag are published.

## Authoritative references

- [Foundry agent networking options](https://learn.microsoft.com/en-us/azure/foundry/agents/concepts/networking-options)
- [Foundry agent networking deep dive](https://learn.microsoft.com/en-us/azure/foundry/agents/concepts/agents-networking-deep-dive)
- [Configure Foundry private link](https://learn.microsoft.com/en-us/azure/foundry/how-to/configure-private-link)
- [Foundry tool network isolation](https://learn.microsoft.com/en-us/azure/foundry/agents/how-to/tools/toolbox-network-isolation)
- [Foundry Browser Automation](https://learn.microsoft.com/en-us/azure/foundry/agents/how-to/tools/browser-automation-hosted-agent-quickstart)
- [ACA Sandbox private endpoints](https://sandboxes.azure.com/docs/sandboxes/private-endpoints)
- [ACA Sandbox VNet connection](https://sandboxes.azure.com/docs/sandboxes/sandbox/vnet)
- [Official ACA Sandbox agent skill](https://sandboxes.azure.com/docs/sandboxes/quickstart/agent-skills)
- [ACA private endpoint](https://learn.microsoft.com/en-us/azure/container-apps/how-to-use-private-endpoint)
- [ACA private endpoint DNS](https://learn.microsoft.com/en-us/azure/container-apps/private-endpoints-with-dns)
- [ACA networking](https://learn.microsoft.com/en-us/azure/container-apps/networking)
- [ACA managed identity](https://learn.microsoft.com/en-us/azure/container-apps/managed-identity)
- [APIM VNet concepts](https://learn.microsoft.com/en-us/azure/api-management/virtual-network-concepts)
- [APIM managed-identity policy](https://learn.microsoft.com/en-us/azure/api-management/authentication-managed-identity-policy)
- [Azure/terraform-provider-aca](https://github.com/Azure/terraform-provider-aca)
- [Sandbox Group REST specification](https://github.com/Azure/azure-rest-api-specs/blob/main/specification/app/resource-manager/Microsoft.App/ContainerApps/SandboxGroup.tsp)
- [Playwright Workspace REST specification](https://github.com/Azure/azure-rest-api-specs/blob/main/specification/loadtestservice/resource-manager/Microsoft.LoadTestService/playwright/main.tsp)
