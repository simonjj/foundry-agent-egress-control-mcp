# Playwright Workspaces migration plan

## Goal

Replace only the current Playwright browser implementation hosted in an Azure
Container Apps Sandbox with a shared Microsoft Playwright Workspace exposed
through its remote MCP endpoint and a dedicated Microsoft Foundry Toolbox.

Preserve:

- the VNet-injected Foundry Hosted Agent;
- the internal Nginx inference gateway;
- the tenant-aware MCP broker;
- delegated Entra validation and customer routing for Python/search tools;
- the dedicated Python ACA Sandbox;
- the existing hub-and-spoke network and private endpoints; and
- the `network_access_mode` deployment option.

The resulting browser path is:

```text
Foundry Hosted Agent
  -> Playwright Foundry Toolbox
  -> project-scoped Custom Keys connection
  -> westus3 Playwright Workspace remote MCP
  -> managed Playwright browser session
```

The retained customer-aware Python/search path is:

```text
Foundry Hosted Agent
  -> tenant broker Foundry Toolbox
  -> delegated user token
  -> tenant-aware MCP broker
  -> customer-specific Python ACA Sandbox
```

## Confirmed design decisions

| Decision | Selected value |
|---|---|
| Workspace tenancy | One shared Playwright Workspace |
| Browser routing | Direct Foundry Toolbox to PWW remote MCP |
| Browser tool policy | Curated allowlist, approval required for every tool |
| PWW credential storage | Project-scoped Foundry Custom Keys connection |
| Workspace region | `westus3` |
| Deployment scope | Recreate and validate the complete private-tenant proof |
| Legacy preservation | Annotated Git tag `playwright-on-sandboxes` |

## Important security boundary change

Browser calls will no longer pass through the tenant-aware MCP broker.

The broker will continue to authenticate users and select customer routes for
Python/search. The shared Playwright Workspace will use one project connection,
workspace, subnet/network boundary, quota, reporting boundary, and token owner.

This is acceptable for the selected shared-workspace proof, but it is not
infrastructure-level browser isolation between customers. Customer-specific
browser routing would require separate Foundry agents/toolboxes, a broker in the
browser path, or separate Workspaces.

## Baseline and source references

Current repository baseline:

```text
branch: feature/tenant-aware-mcp-broker
commit: e2e8c9bc381cf416637945d3975dfaf9d03864b7
tag to create: playwright-on-sandboxes
```

Microsoft sample:

```text
Azure/playwright-workspaces
samples/remote-mcp/foundry-hosted-agents
```

The sample proves:

- conversion of the PWW browser WebSocket URL to the remote MCP URL;
- `x-api-key` authentication to the PWW remote MCP server;
- creation of an MCP-backed Foundry Toolbox version;
- use of that Toolbox from an Agent Framework agent; and
- `require_approval="always"` metadata.

The sample does not provision the Workspace, create or rotate access tokens,
store credentials in a Foundry connection, restrict tools, persist/promote a
Toolbox version, deploy a Hosted Agent, compose multiple Toolboxes, or validate
private networking.

## Release gates

Do not remove the browser Sandbox implementation until both gates pass.

### Gate 1: live MCP inventory

Provision a canary Workspace and authenticated connection, call `tools/list`,
and capture the exact PWW remote MCP tool names.

The production Toolbox allowlist must be created from the reviewed live
inventory. Do not assume upstream `@playwright/mcp` names exactly match the
managed PWW remote MCP service.

Initial policy intent:

- allow session create/close;
- allow navigation, back navigation, snapshot, find, click, hover, typing,
  form fill, option selection, key press, wait, and tab operations;
- optionally allow screenshot and network-request inspection after review;
- deny arbitrary JavaScript evaluation;
- deny arbitrary Playwright code execution;
- deny file upload/download;
- deny storage-state or cookie export;
- deny network mocking and request-body capture; and
- deny any unreviewed tool.

### Gate 2: approval enforcement

Prove that the deployed Foundry Hosted Agent runtime:

1. pauses before each PWW tool call;
2. displays the exact tool and arguments;
3. waits for an explicit approve/reject decision;
4. performs no browser activity after rejection; and
5. requests approval again for each subsequent browser action.

`require_approval="always"` is metadata. A system-prompt instruction alone is
not enforcement. If the current Hosted Agent/Playground runtime cannot enforce
approval, stop and request a user decision before changing the policy or
removing the Sandbox implementation.

## Phase 1: preserve the Sandbox implementation

1. Verify the worktree is clean and synchronized.
2. Create an annotated tag on `e2e8c9b`:

   ```powershell
   git tag -a playwright-on-sandboxes e2e8c9b `
     -m "Preserve Playwright on ACA Sandboxes implementation"
   git push origin playwright-on-sandboxes
   ```

3. Verify the remote tag resolves to the expected commit.
4. Create a new implementation branch from the tag:

   ```powershell
   git switch -c feature/playwright-workspaces
   ```

Rollback source:

```powershell
git switch --detach playwright-on-sandboxes
```

## Phase 2: provision the shared Playwright Workspace

### Terraform

Add a PWW resource to `infrastructure/terraform-vnet`:

```hcl
resource "azapi_resource" "playwright_workspace" {
  type      = "Microsoft.LoadTestService/playwrightWorkspaces@2025-09-01"
  name      = local.playwright_workspace_name
  parent_id = azurerm_resource_group.main.id
  location  = var.playwright_location

  body = {
    properties = {
      localAuth       = "Enabled"
      regionalAffinity = "Disabled"
    }
  }

  response_export_values = [
    "properties.workspaceId",
    "properties.dataplaneUri",
    "properties.provisioningState",
  ]
}
```

Use stable API `2025-09-01`. VNet injection is available only through a newer
preview contract and is not needed for the current public Craigslist target.
The Foundry-to-PWW MCP call remains an outbound HTTPS call to the public
`westus3.mcp.playwright.microsoft.com` service.

Add:

- `playwright_location`, default `westus3`;
- a deterministic, 24-character-or-shorter Workspace name;
- provider registration dependency for `Microsoft.LoadTestService`;
- `Playwright Workspace Contributor` for the deployment principal used to
  create access tokens;
- Workspace resource ID, Workspace GUID, data-plane URI, browser service URL,
  and derived MCP URL outputs; and
- explicit tags identifying the shared browser service.

Do not put the PWW access token in Terraform. It is returned only at creation
time and would otherwise remain in Terraform state.

### Provisioning validation

Block later stages until:

```text
location == westus3
provisioningState == Succeeded
workspaceId is nonempty
dataplaneUri is nonempty
localAuth == Enabled
regionalAffinity == Disabled
```

## Phase 3: automate token and connection bootstrap

Add a post-Terraform helper, preferably:

```text
scripts/configure-playwright-workspace-mcp.py
```

Responsibilities:

1. Read nonsecret Workspace and Foundry coordinates from Terraform/azd.
2. Authenticate with `DefaultAzureCredential`.
3. Acquire a data-plane token for:

   ```text
   https://playwright.microsoft.com/.default
   ```

4. Create a bounded-lifetime PWW access token using:

   ```text
   PUT {dataplaneUri}/playwrightworkspaces/{workspaceId}/access-tokens/{tokenId}
       ?api-version=2025-09-01
   ```

5. Capture the returned `jwtToken` only in process memory.
6. Create a project-scoped Foundry Custom Keys connection:

   ```text
   name: playwright-mcp-key-<rotation>
   target: <derived PWW remote MCP URL>
   header: x-api-key=<jwtToken>
   ```

7. Retrieve the connection ID without printing credentials.
8. Clear token variables and close credentials before exit.

Requirements:

- no token in Terraform state;
- no token in `.env`, logs, command tracing, process output, or Git;
- redact HTTP request/response bodies containing the token;
- fail if the connection response exposes credentials;
- idempotent detection of an existing active rotation;
- blue/green connection naming for safe rotation; and
- a cleanup operation that revokes old tokens only after promotion succeeds.

Add a separate `--rotate` path or companion script implementing:

1. token B;
2. connection B;
3. Toolbox version B;
4. canary validation;
5. Toolbox promotion;
6. Hosted Agent validation;
7. token A revocation; and
8. delayed connection A deletion.

## Phase 4: discover and configure the PWW Toolbox

Use a temporary discovery Toolbox or a direct authenticated MCP client to call
`tools/list`.

Persist only nonsecret evidence:

- PWW service version/date;
- exact tool names;
- reviewed allowed set;
- explicitly denied high-risk set; and
- discovery timestamp.

Add a persistent Toolbox named:

```text
playwright-browser-automation
```

Create immutable versions with:

```python
MCPToolboxTool(
    server_label="playwright",
    server_url=playwright_mcp_url,
    project_connection_id=connection.id,
    allowed_tools=reviewed_allowlist,
    require_approval="always",
)
```

Use:

```text
canary:
{projectEndpoint}/toolboxes/playwright-browser-automation/versions/{version}/mcp?api-version=v1

production:
{projectEndpoint}/toolboxes/playwright-browser-automation/mcp?api-version=v1
```

Validate the version-specific endpoint before promoting it as the Toolbox
default. Do not delete the production version on normal process shutdown.

Keep the PWW Toolbox separate from the tenant-broker Toolbox so each has an
independent credential, version, promotion, and rollback lifecycle.

## Phase 5: compose both Toolboxes in the Hosted Agent

Refactor `src/agent/main.py` to support multiple named Foundry Toolboxes.

Recommended environment contract:

```text
TENANT_BROKER_TOOLBOX_ENDPOINT
TENANT_BROKER_TOOLBOX_ALLOWED_TOOLS
PLAYWRIGHT_TOOLBOX_ENDPOINT
PLAYWRIGHT_TOOLBOX_ALLOWED_TOOLS
```

Retain compatibility with `TOOLBOX_ENDPOINT`, `TOOLBOX_NAME`, and
`TOOLBOX_ALLOWED_TOOLS` during the transition.

Construct:

```python
tools = [
    LoggedFoundryToolbox(
        credential,
        url=tenant_broker_toolbox_endpoint,
        name="tenant_broker",
        allowed_tools=tenant_broker_allowed_tools,
    ),
    LoggedFoundryToolbox(
        credential,
        url=playwright_toolbox_endpoint,
        name="playwright_browser",
        allowed_tools=playwright_allowed_tools,
    ),
]
```

Update agent instructions to:

- use broker tools for customer context, Python, and Craigslist search;
- use PWW tools for browser rendering and interaction;
- create a browser session before browser operations;
- close the session after completing the task;
- never reuse session IDs across requests or conversations;
- require explicit approval for every browser tool; and
- report cleanup failures rather than silently abandoning sessions.

Do not expose the PWW access token, project connection, Workspace ID, or raw
connection metadata to the model.

Update the personal identity deployment profile to declare/reference both
Toolboxes and export both unversioned consumer endpoints.

## Phase 6: remove the Playwright-on-Sandbox path

Only begin after both release gates pass.

### Browser source

Delete:

```text
src/browser/Dockerfile
src/browser/package.json
src/browser/package-lock.json
src/browser/server.mjs
```

Remove ignored local `src/browser/node_modules` during cleanup.

### VNet Terraform

Remove:

- `random_password.browser_mcp_token`;
- browser source-file and image locals;
- browser image build resource;
- browser Sandbox deployment resource;
- browser Sandbox external data source;
- browser Sandbox ID, URL, and token outputs;
- browser token secret/env from the broker Container App; and
- browser URL/token fields from `CUSTOMER_ROUTES_JSON`.

Keep:

- Express Sandbox environment and private endpoint;
- Sandbox Group and VNet connection;
- sandbox managed identity and ACR access;
- Python image and Sandbox deployment; and
- Craigslist allowlist for Python search.

Update descriptions that currently claim both interpreter and browser
Sandboxes are deployed.

### Broker

In `src/broker/routing.py`:

- remove `browser_mcp_url` and `browser_token` from `CustomerRoute`;
- remove browser token-env and URL parsing; and
- preserve fail-closed Python/customer routing.

In `src/broker/server.py`:

- remove browser dispatch from `_call_sandbox_tools`;
- remove broker tool `browse_url`; and
- retain `customer_context`, `run_python`, and `search_craigslist`.

Update broker tests for the Python-only customer route.

### Agent

Remove:

- `BROWSER_MCP_SERVER_URL`;
- `BROWSER_MCP_AUTH_TOKEN`; and
- ACA Sandbox browser-tool construction.

Retain the original non-VNet profile's managed Playwright connection only if it
remains an intentional legacy architecture. Do not let that fallback activate
in the tenant-aware deployment.

### Deployment scripts

Update:

- `scripts/deploy-sandbox-vnet.py` to remove the browser profile;
- `scripts/deploy-vnet.ps1` to stop exporting browser Sandbox values and to run
  PWW token/connection/Toolbox bootstrap;
- `scripts/test-vnet-network.ps1` to test only Python Sandbox private health;
- `scripts/test-vnet-agent.ps1` to validate PWW browser tools; and
- any image-build scripts or acceptance scripts referencing `src/browser`.

Do not remove the Python/search Sandbox deployment path.

## Phase 7: redeploy the private-tenant proof

The previous private deployment was intentionally torn down, so this is a clean
deployment rather than an in-place Terraform resource migration.

Target:

```text
subscription: private subscription selected explicitly
tenant: private tenant selected explicitly
region: centralus for Foundry/ACA
PWW region: westus3
network access: playground for customer demonstration, then private when asked
```

Deployment sequence:

1. Verify active Azure subscription and tenant before creating resources.
2. Register required providers, including `Microsoft.LoadTestService`.
3. Apply Terraform bootstrap.
4. Build/deploy Nginx, broker, and Python Sandbox images/resources.
5. Wait for PWW Workspace readiness.
6. Create the PWW access token and Custom Keys connection.
7. Discover tools and create the canary PWW Toolbox version.
8. Validate the canary endpoint and approval behavior.
9. Promote the PWW Toolbox version.
10. Configure the broker OAuth connection and tenant-broker Toolbox.
11. Deploy the Hosted Agent with both Toolbox endpoints.
12. Grant the Hosted Agent identity required Foundry roles.
13. Run combined E2E validation.
14. Apply final `network_access_mode`.
15. Run Terraform drift validation.

Never infer the Azure account context. Every destructive or provisioning command
must explicitly set and verify subscription and tenant first.

## Phase 8: validation

### Unit and static validation

- broker authentication tests remain green;
- routing tests prove Python-only customer routes;
- PWW URL derivation tests cover scheme, host, path, and malformed input;
- connection/bootstrap code redacts token values;
- multiple-Toolbox agent construction is tested;
- browser Sandbox references are absent from active VNet deployment code;
- Terraform formatting and validation pass;
- Python, Node, and PowerShell syntax checks pass; and
- secret scanning finds no PWW token.

### Workspace and connection validation

- Workspace is `Succeeded` in `westus3`;
- local auth is enabled;
- regional affinity is disabled;
- token is active and has bounded expiry;
- connection exists at project scope;
- connection reads do not return the secret;
- invalid token fails with `401` or `403`; and
- correct connection can initialize MCP and list tools.

### Toolbox validation

- only the reviewed tool names are exposed;
- denied high-risk tools are absent;
- every browser tool reports approval required;
- canary version works before promotion;
- unversioned endpoint resolves to promoted version; and
- tenant-broker and PWW tools have distinct names/prefixes.

### Approval validation

- rejection causes no browser request;
- approval performs exactly the displayed action;
- every browser action requires approval;
- prompt instructions cannot bypass approval; and
- traces record approved/rejected actions without secrets.

### Combined E2E prompt

Use a deterministic variant:

```text
Demonstrate the complete customer-aware tool flow:

1. Identify the active customer context.
2. Use Python to calculate 17 * 23.
3. Search Seattle Craigslist for a current bicycle listing.
4. Create a Playwright browser session.
5. Open one result, report its title, and close the browser session.

Use broker tools for customer context, Python, and search.
Use Playwright Workspace tools for browser actions.
Report the customer, Python result, listing URL, and page title.
Finish with the exact marker PWW_MCP_E2E_OK.
```

Expected evidence:

- tenant broker returns `customer-personal`;
- Python returns `391`;
- search returns an allowlisted Craigslist URL;
- approval appears before each browser action;
- PWW returns the expected page title or accessibility snapshot;
- browser session is closed;
- traces show model inference through Nginx;
- broker tools use the delegated OAuth path;
- PWW tools use the separate direct Toolbox path; and
- no browser Sandbox resource exists.

### Negative tests

- unknown broker user cannot use customer Python/search route;
- invalid PWW key fails;
- disallowed PWW tool is not advertised;
- rejected approval performs no action;
- session ID from another conversation cannot be used if the runtime exposes it;
- browser target outside the approved operational policy is rejected or
  explicitly approved according to the accepted PWW limitation;
- revoked token fails after rotation; and
- old Toolbox version is not the production default.

### Drift and cost validation

- Terraform plan returns no infrastructure changes;
- Git worktree is clean;
- active ACR repositories no longer include a browser MCP image built by this
  deployment;
- no browser Sandbox is returned by labels;
- PWW usage appears as browser minutes;
- ACA compute no longer includes the persistent 2-vCPU/4-GiB browser Sandbox;
- token expiry is monitored; and
- Workspace concurrency/usage alerts are configured.

## Documentation and diagrams

Update:

- `README.md`;
- `CONFIRM-vnet.md`;
- `PLAN-vnet.md` where it describes the active browser architecture;
- `docs/tenant-aware-mcp-visuals.md`;
- runtime call-flow SVG;
- security/segmentation SVG; and
- full Azure component SVG.

The updated diagrams must show:

```text
Hosted Agent
  ├─ tenant broker Toolbox -> MCP broker -> Python Sandbox
  └─ Playwright Toolbox -> Custom Keys connection -> PWW remote MCP
```

They must not show:

- a browser ACA Sandbox;
- browser bearer-key injection by the tenant broker; or
- browser traffic flowing through Nginx or the tenant broker.

Retain historical Sandbox diagrams at the `playwright-on-sandboxes` Git tag
rather than presenting both architectures as active in the branch.

## Rollback

### Before PWW promotion

- keep the current production Toolbox default unchanged;
- revoke the canary PWW token;
- delete the canary connection and Toolbox version; and
- leave the Sandbox implementation untouched.

### After code removal but before live acceptance

- restore the source from `playwright-on-sandboxes`;
- redeploy the tagged Terraform and agent profile; and
- recreate the former browser Sandbox and broker route.

### After PWW promotion

- retain the previous PWW token/connection/Toolbox version for a bounded
  rollback window;
- promote the previous Toolbox version if the new version fails;
- revoke the failed token after rollback; and
- use the Git tag only if the managed PWW path itself is unsuitable.

## Commit and push sequence

1. Push annotated `playwright-on-sandboxes` tag.
2. Commit this plan on `feature/playwright-workspaces`.
3. Commit Workspace Terraform and token/connection bootstrap.
4. Commit canary Toolbox discovery and approval validation.
5. Commit multi-Toolbox Hosted Agent integration.
6. Commit browser Sandbox/broker browser-route removal.
7. Commit tests, documentation, and diagrams.
8. Deploy and validate the private-tenant proof.
9. Commit any deployment-derived corrections.
10. Push `feature/playwright-workspaces`.

Each commit must remain free of tokens, Terraform state, generated azd
artifacts, browser storage state, screenshots containing customer data, and
Workspace access credentials.

## Definition of done

Implementation status on September 14, 2026: the shared Workspace, curated
Toolbox, dual-Toolbox agent, independent approval gates, Python/search
regression gate, and browser Sandbox removal are complete in the private
tenant. Azure Monitor does not expose a supported platform-metrics namespace
for `Microsoft.LoadTestService/playwrightWorkspaces`, so rejected-call
zero-minute evidence cannot be collected through `az monitor metrics`; the
runtime evidence is the rejected approval continuation with no `mcp_call`.
The live canary intentionally remains in `playground` network mode.

- annotated `playwright-on-sandboxes` tag exists remotely at `e2e8c9b`;
- new branch contains the reviewed migration plan;
- one shared West US 3 PWW Workspace is provisioned;
- PWW token is stored only in a project Custom Keys connection;
- curated PWW tools are exposed through a persistent promoted Toolbox;
- every browser action requires enforced approval;
- Hosted Agent uses both broker and PWW Toolboxes;
- broker exposes only customer context, Python, and search tools;
- Python Sandbox remains private and customer-routed;
- browser ACA image, token, route, Sandbox, and outputs are removed;
- combined E2E prompt returns `PWW_MCP_E2E_OK`;
- Terraform reports no drift;
- updated diagrams/documentation match the deployed architecture; and
- implementation branch is pushed with a clean worktree.
