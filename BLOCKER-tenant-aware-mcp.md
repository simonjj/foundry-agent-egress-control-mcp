# Tenant-aware MCP identity proof blocker

Date: September 11, 2026

## Current status

The personal-tenant implementation now passes customer-aware tool routing end
to end. Active Hosted Agent `craigslist-agent-personal-identity-proof:11`
successfully called the OAuth2 Toolbox, the private broker, and the
customer-specific Python and browser Sandboxes with the least-privilege tool
allowlist enabled.

Hosted Agent version `9` could initialize the Toolbox and enumerate broker
tools, but it exposed no callable functions to the model. The configured
allowlist used the broker names `customer_context`, `run_python`,
`search_craigslist`, and `browse_url`, while Toolbox advertised the model-facing
names with its connection prefix:

```text
mcp-oauth___browse_url
mcp-oauth___customer_context
mcp-oauth___run_python
mcp-oauth___search_craigslist
mcp-oauth___who_am_i
```

Version `10` removed that redundant client-side name filter to diagnose and
validate the complete broker catalog. Version `11` restores least-privilege
filtering with the exact prefixed names for the four customer tools. Safe
startup logging records the exposed tool names without credentials or identity
claims. The following live checks passed through the full Hosted Agent path:

| Tool | Confirmed result |
|---|---|
| `customer_context` | `customer-personal` |
| `run_python` | stdout `391` |
| `search_craigslist` | `https://www.craigslist.org/view/d/bothell-vintage-motobecane-nomad-mens/w4aJz14EfkrjWq9mViW5Cq` |
| `browse_url` | `Vintage Motobecane Nomad Men's Bicycle - sporting goods - by owner - sale - craigslist` |

The final invocation recorded five real `CallToolRequest` entries. The first
`run_python` request supplied an out-of-range timeout and was rejected by broker
validation before Sandbox routing; the model retried with a valid timeout and
succeeded. The successful Python, search, and browser calls recorded matching
`sandbox_route_started` and `sandbox_route_completed` events.

The selected customer resources are:

- Python Sandbox `ffd11767-ae1f-464a-b217-232205097ffc`
- Browser Sandbox `0f23c1bf-4614-497f-bf76-3ff157175722`
- customer label `customer-personal`
- approved hosts `craigslist.org`, `seattle.craigslist.org`,
  `images.craigslist.org`, and `www.craigslist.org`

The earlier shared Sandboxes and identity reproductions remain preserved.
Cross-user and cross-customer negative authorization tests remain deferred.
Foundry and ACR are intentionally live with public network access `Enabled` and
firewall default action `Allow` for the current development cycle. Terraform
still represents the private desired state; do not apply it or close the live
services until lockdown is explicitly requested.

The personal-tenant identity and private-network proof now passes end to end. A
missing project-level capability host was identified and deployed on September
11, 2026. After that deployment, Toolbox used the VNet/DataProxy path, resolved
the private Container Apps broker hostname, and reached the broker. A renewed
OAuth consent attempt then established usable authorization state despite the
browser callback displaying `Code ... not found`. The next invocation executed
`who_am_i`, completed successfully, and produced authenticated MCP responses
from the private broker.

The earlier `UserEntraToken` path remains blocked independently: Foundry's OBO
service rejects the Hosted Agent caller assertion because its audience is
incorrect. The official Microsoft tenant also blocks explicit per-user consent
for the broker scope with `AADSTS90094`.

## Confirmed

- The protected single-tenant application `ss-tenant-aware-mcp-broker` exists in
  the Microsoft tenant.
- Its application ID URI is
  `api://cccef5ef-0886-429f-90c5-0a99ad041bc7`.
- It exposes the delegated scope `McpBroker.Invoke` and application role
  `McpBroker.Invoke.All`.
- A private proof broker is running in the existing internal Container Apps
  environment.
- The broker health endpoint succeeds privately and unauthenticated MCP requests
  return HTTP `401`.
- The broker expects the v2 access-token audience
  `cccef5ef-0886-429f-90c5-0a99ad041bc7`; the connection requests that API by
  its `api://` scope URI.
- Foundry accepted a `RemoteTool` connection using `UserEntraToken` with the
  broker's custom audience.
- Foundry created a Toolbox containing that connection.
- MAF Hosted Agent `craigslist-agent-tenant:1` successfully deployed with
  Responses protocol `2.0.0` and `FoundryToolbox`.
- Current Foundry documentation says a custom OAuth client secret is optional
  when the OAuth application supports a secretless flow.
- A direct ARM request can omit the client secret and reaches Foundry's hidden
  Connector Gateway, rather than failing connection-schema validation.
- The supported `azd ai connection create --auth-type oauth2` flow succeeds
  when supplied a confidential-client secret.
- Personal connection `mcp-oauth` requests only
  `api://e42bba39-26e4-4d48-9328-65f04935148c/McpBroker.Invoke` plus the
  standard OpenID and refresh scopes.
- Toolbox `personal-agent-oauth-proof:2` is published as the default and
  references `mcp-oauth`.
- Hosted Agent `craigslist-agent-personal-identity-proof:11` is active and uses
  the unversioned OAuth Toolbox endpoint.
- A first invocation emitted a typed `oauth_consent_request`. After the browser
  flow, subsequent calls advanced to MCP tool enumeration without requesting
  consent again.
- The account-level capability host existed and was in `Succeeded` state, but
  the project had no
  `Microsoft.CognitiveServices/accounts/projects/capabilityHosts` resource.
- Microsoft Foundry's Basic VNet reference template creates a project capability
  host even when the project uses platform-managed resources and has no
  Storage, Cosmos DB, or AI Search connection bindings.
- Terraform now deploys project capability host `caphostproj`. Its provisioning
  state is `Succeeded`.
- After `caphostproj` was deployed, the same OAuth2 `who_am_i` invocation no
  longer returned `Name or service not known`. DataProxy reached the private
  broker, whose logs recorded `POST /mcp` and `GET /mcp` requests returning
  HTTP `401`.
- Foundry wrapped the downstream `401` as HTTP `424` with
  `CustomerManagedDownstreamError`, explicitly classifying it as a
  customer-managed downstream response rather than a DataProxy failure.
- The broker now emits bounded authentication rejection categories including
  `missing_bearer`, `invalid_audience`, `missing_scope`, and `invalid_tenant`.
  It logs no bearer token, claim value, tenant identifier, object identifier, or
  user identifier.
- The next Hosted Agent invocation emitted a new `oauth_consent_request`. The
  callback again displayed `Code ... not found`, but Foundry retained the
  authorization state.
- A post-consent invocation completed without another consent request, included
  a `who_am_i` tool call, and produced broker responses `200`, `200`, `202`, and
  `200` with no `broker_auth_rejected` event.
- Because every non-health broker request is gated by `validated_claims()`, the
  successful MCP exchange proves that signature, issuer, audience, delegated
  scope, tenant, and user-object checks passed in the personal tenant.
- Foundry accepted an additive `AgentUserImpersonation` RemoteTool connection
  with the broker audience in both the connection and `generic_mcp` metadata.
- Foundry created isolated Toolbox `tenant-agent-user-proof:1`.
- Hosted Agent `craigslist-agent-tenant-agent-user-proof:1` deployed as a
  multi-protocol M365 Digital Worker with:
  - blueprint client ID `f0b4236c-7e29-4d03-9a28-cea717a55c76`;
  - blueprint principal ID `c3888d3a-fbf5-400d-bb5b-326af50f191d`;
  - instance client and principal ID
    `5ceee671-a52c-4d42-a8e8-d18822abc679`.
- This agent is retained only as an identity reproduction. Its current
  application hosts Responses but not Activity, so it must not be published to
  Microsoft 365 or treated as a production multi-protocol deployment.
- The blueprint declares `McpBroker.Invoke` as required and inheritable, and
  the broker application preauthorizes the blueprint for only that delegated
  scope.
- The broker scope is enabled as a user-consentable delegated scope
  (`type=User`).
- A consent-only Agent ID request using `response_type=none` reaches the
  Microsoft sign-in and consent experience without requiring a client secret.
- When broker preauthorization is removed so that `McpBroker.Invoke` must be
  granted explicitly, Microsoft tenant policy blocks the current user with
  `AADSTS90094`.
- Foundry and ACR were returned to their locked state after the earlier identity
  proof operations. They are currently intentionally public for the active
  customer-routing development cycle, while Terraform retains the private
  desired state.

## UserEntraToken failed proof

The proof was invoked once through `azd` and once with an explicit user access
token whose audience was `https://ai.azure.com`. Both requests reached the Hosted
Agent, but Toolbox connection resolution failed before any request reached the
broker:

```text
Request: POST obotoken.vienna-centralus.svc/obotoken/v1.0/getuseraccesstoken
Status Code: 400 BadRequest
Error Code: UserError
Message: Audience for incoming token is incorrect
```

The failure occurs in Foundry's OBO token service, not in the broker, its private
network path, or its unauthenticated rejection path. A valid delegated token was
never delivered to the broker, so successful JWT validation remains unproven.

## Secretless custom OAuth proof remains blocked

Foundry documentation directs customer-owned MCP audiences to a custom OAuth
connection and now marks the client secret as optional. The installed
`azure.ai.connections` extension `1.0.0-beta.6` still requires
`--client-secret`, so the proof bypassed CLI validation and called the ARM
connections API directly.

The request used the broker client ID, Microsoft tenant authorization and token
endpoints, `McpBroker.Invoke` plus refresh scopes, and the current Foundry portal
metadata:

```json
{
  "oAuthProvider": "custom",
  "type": "custom_MCP"
}
```

Foundry passed the request to its hidden Connector Gateway, which rejected it:

```text
Error Code: ConnectorNamespaceCustomConnectorDirectInvokeRequiresApiDefinitionV3
Message: The custom connector ... uses the 'DirectInvoke' invocation mode,
which requires a version 3.0 API definition. Update the API definition or use
the 'ProxyInvoke' invocation mode, then try again.
```

The same error occurred for project- and account-scoped requests, a fresh
connection name, current stable and preview API versions, an omitted
client-secret property, the portal's empty client-secret value, and attempted
`ProxyInvoke` hints. Replacing the private broker target with the public
Microsoft Learn MCP endpoint produced the same error, ruling out private target
reachability or MCP discovery as the cause of this creation failure. The
current public Foundry connection schema exposes neither an API-definition
payload nor a supported invocation-mode property.

Support-ready reproductions:

| UTC timestamp | Request | Operation ID | Request ID |
|---|---|---|---|
| `2026-09-09T16:11:26.8207197Z` | Exact current portal payload | `3baf9110f9d065b7147e890d1ecc9918` | `2f760868c513181f` |
| `2026-09-09T16:15:42.5000329Z` | Exact payload with a fresh connection name | `49ab2783975b72f71c9e26e9d0b275d9` | `2ea4f9dd95adc891` |
| `2026-09-09T16:33:18.2351450Z` | Exact secretless payload with the public Microsoft Learn MCP target | `c4de96ef852871f0a622227bef9c44b2` | `00d2750cf3ee09b1` |

No `tenant-mcp-broker-oauth-proof` connection persisted, no redirect URI was
generated, and the Entra application and Toolbox were not changed. The tenant
policy still prohibits creating a client secret, but missing-secret validation
is no longer the immediate blocker; the failure is now the Foundry-to-Connector
Gateway API-definition mismatch.

## Secret-backed OAuth2 proof reaches the private network boundary

The personal tenant permits a short-lived confidential-client credential, so
the proof was repeated using the supported `azd ai connection create` command
instead of the secretless ARM payload.

The first connection name,
`personal-mcp-broker-oauth-proof`, was accepted at deployment time but failed
at runtime because Connector Gateway expands project connection names into an
internal identifier with a maximum length of 96 characters:

```text
The ConnectorGateway connection name exceeds the maximum allowed length of
96 characters.
```

The shorter connection `mcp-oauth` succeeded. Foundry generated the consent
callback, the callback was registered on the broker application, and Toolbox
`personal-agent-oauth-proof:2` was published with the short connection.
Hosted Agent `craigslist-agent-personal-identity-proof:3` uses that Toolbox.
The personal proof credential expires on October 10, 2026 and must be rotated
before any longer-running validation.

The first invocation returned an `oauth_consent_request` for server label
`mcp-oauth`. The browser callback displayed `Code ... not found`, but a later
fresh invocation did not request consent again and proceeded to MCP
`tools/list`. The runtime then failed with:

```text
The host name could not be resolved from the selected network path.
Verify the server URL and DNS record from the intended Foundry network path.
```

The target is the broker's internal Container Apps environment hostname. Its
private DNS zone is linked to the customer VNets, but the Toolbox-selected
network path did not resolve it.

The network path was isolated with additive Hosted Agent version `5`. That
version bypassed Toolbox and ran `getaddrinfo()` plus an HTTPS `/health` request
from inside the Hosted Agent container:

```text
resolved_addresses: ["10.63.1.194"]
http_status: 200
body: {"status":"ok"}
stage: complete
```

This proves that the Foundry agent network injection, customer private DNS,
VNet peering, routing, TLS, and broker ingress work from the Hosted Agent
container. Version `6` restored normal OAuth Toolbox mode and immediately
reproduced `Name or service not known` for the same hostname. The unresolved
path is therefore specific to Toolbox/Connector Gateway egress rather than a
missing customer VNet DNS record or route.

An independent public-DNS control then used:

```text
connection: mcp-learn
Toolbox: personal-public-dns-proof:1
target: https://learn.microsoft.com/api/mcp
Hosted Agent version: 7
```

Toolbox successfully enumerated the public Microsoft Learn MCP endpoint,
invoked `microsoft_docs_search`, and returned
`Azure Container Apps - internal only environments (preview)`. This proves
Connector Gateway has working public DNS and HTTPS egress. The failure is
specific to selecting or using the project's delegated VNet/private DNS path.
Version `8` restored the normal private OAuth Toolbox configuration.

A hardcoded private-IP control was also attempted without changing the OAuth
broker connection. Toolbox version `personal-public-dns-proof:2` targeted
`https://10.63.1.194/mcp` and Connector Gateway rejected it before TLS:

```text
The remote MCP server URL https://10.63.1.194:443/mcp is blocked by outbound
SSRF protection ... use the VNET/DataProxy path for private endpoints.
```

Hardcoding the broker IP is therefore not a viable bypass. The public control
was restored as `personal-public-dns-proof:3` targeting Microsoft Learn.

On September 11, 2026, ARM inspection showed that the account capability host
was healthy but the project had no capability host. The current Basic VNet
reference template requires a project capability host with
`capabilityHostKind: Agents`, even without BYO data connections.

Terraform resource `azapi_resource.foundry_project_capability_host` was added
and applied as a targeted plan with one addition and no changes or deletions:

```text
name: caphostproj
state: Succeeded
kind: Agents
```

The same `who_am_i` invocation then reached the broker through DataProxy. The
previous DNS error disappeared. DataProxy returned:

```text
HTTP 424 Failed Dependency
error: CustomerManagedDownstreamError
innerStatusCode: 401
innerReasonPhrase: Unauthorized
```

Broker access logs recorded the corresponding private `POST /mcp` and
`GET /mcp` requests. The project capability host was therefore the missing
Toolbox VNet/DataProxy binding.

The broker was then redeployed with bounded authentication diagnostics. The
logging records only a stable rejection category, HTTP method and path, and
whether an authorization header and Bearer scheme were present. It does not log
tokens or identity claims.

The first invocation against the diagnostic revision emitted a fresh
`oauth_consent_request` and did not reach the broker. After the consent attempt,
the next invocation completed, included `who_am_i`, and generated authenticated
broker responses:

```text
POST /mcp 200
GET  /mcp 200
POST /mcp 202
POST /mcp 200
```

No authentication rejection was logged. The earlier HTTP `401` was therefore
associated with authorization state before the renewed consent, not a broker
validation rule changed by the logging deployment. Foundry and ACR were returned
to `publicNetworkAccess=Disabled` with default action `Deny`.

## AgentUserImpersonation proof is blocked by tenant consent policy

The custom OAuth failure was bypassed with a separate connection:

```text
authType: AgentUserImpersonation
metadata.type: generic_mcp
audience: api://cccef5ef-0886-429f-90c5-0a99ad041bc7
```

A direct Toolbox call correctly rejected the project default identity and
required a provisioned agent identity. The isolated Digital Worker proof agent
then supplied an active blueprint/instance identity pair and a platform
`x-agent-foundry-call-id`. Its Toolbox connection resolution advanced past the
default-identity error but failed before broker ingress:

```text
tools/list failed for 1 tool source(s), succeeded for 0 tool source(s)
code: INTERNAL_ERROR
message: Error resolving connection '.../tenant-mcp-broker-agent-user-proof'.
```

The broker logs contain no corresponding request. Adding the audience to
`metadata`, declaring `McpBroker.Invoke` in the blueprint's required resource
access, configuring that scope as an enumerated inheritable permission, and
preauthorizing the blueprint on the broker application did not change the
result.

Direct attempts to create either a tenant-wide or current-user
`oauth2PermissionGrant` through Microsoft Graph returned:

```text
Authorization_RequestDenied
Insufficient privileges to complete the operation.
```

That result established only that the current user cannot create permission
grants programmatically. The documented consent-only user flow was therefore
tested separately:

1. A temporary localhost web redirect URI was registered on the blueprint.
2. The browser opened an authorization request using the child Agent ID,
   `response_type=none`, and
   `api://cccef5ef-0886-429f-90c5-0a99ad041bc7/McpBroker.Invoke`.
3. With broker preauthorization present, the consent page completed but
   recorded only a user-specific Microsoft Graph grant for `openid`, `profile`,
   `email`, and `offline_access`. It did not create a broker grant.
4. Broker preauthorization was temporarily removed and the request was repeated
   with `prompt=consent` to force an explicit decision for
   `McpBroker.Invoke`.
5. Microsoft tenant policy rejected the request with:

```text
AADSTS90094: An administrator of Microsoft has set a policy that prevents you
from granting this Agent Identity Blueprint the permissions it is requesting.
```

| UTC timestamp | Request ID | Correlation ID |
|---|---|---|
| `2026-09-09T18:52:31Z` | `1f96ecb6-7b35-4e80-b464-8070a3ab4200` | `2e2165d7-95c4-48dd-8af9-71590f92e523` |

The broker preauthorization and private network lockdown were restored, and the
temporary redirect URI was removed after the test. The basic-profile consent
grant remains as a preserved proof artifact; it grants no broker access.

A live Hosted Agent invocation after the first consent attempt still returned
the same Toolbox connection-resolution failure before broker ingress:

| UTC timestamp | Client request ID | APIM request ID | Result |
|---|---|---|---|
| `2026-09-09T18:50:23Z` | `d1619aca-e3c4-41f7-86a4-5eddd15d6d97` | `33e139c5-b882-494a-b30d-3a6d95ab898f` | `INTERNAL_ERROR` |

No delegated broker grant currently exists between blueprint principal
`c3888d3a-fbf5-400d-bb5b-326af50f191d` and broker service principal
`19f99b93-8c80-4548-90f4-5a39429c7092`. The no-admin consent route is therefore
not viable in the official Microsoft tenant under its current policy.

If administrator consent is ever approved as an exception, the administrator
can run:

```powershell
.\scripts\configure-agent-blueprint-permissions.ps1 `
  -BlueprintObjectId f0b4236c-7e29-4d03-9a28-cea717a55c76 `
  -BlueprintClientId f0b4236c-7e29-4d03-9a28-cea717a55c76 `
  -BlueprintPrincipalId c3888d3a-fbf5-400d-bb5b-326af50f191d `
  -BrokerApplicationObjectId acb6c7d2-e71f-41d4-b314-b16ab8879088 `
  -BrokerClientId cccef5ef-0886-429f-90c5-0a99ad041bc7 `
  -BrokerServicePrincipalId 19f99b93-8c80-4548-90f4-5a39429c7092 `
  -ScopeId 4bbfe821-1c79-4a4d-a0b9-b0c0f86ee214 `
  -GrantAdminConsent
```

The earlier hosted-agent reproduction before the explicit consent test used:

| UTC timestamp | Agent request ID | APIM request ID | Session |
|---|---|---|---|
| `2026-09-09T17:05:48Z` | `f24a7f3198befc286d1ed2d927dddff4` | `580fa6c5-d014-4cb2-9792-ca825ea86773` | `069e27638e36fed400UWWHKy2KD8DT8Pte1W5HLieicMsIipFW` |

The public Toolbox contract does not allow callers to supply
`ApplicationName`, `AgentBlueprintClientId`, or `AgentInstanceClientId`.
Foundry must resolve those values from the opaque call ID. The current
`INTERNAL_ERROR` cannot be isolated from the missing broker permission because
Microsoft tenant policy prevents the required per-user grant.

## Personal-tenant administrator proof

The administrator-consent hypothesis was tested separately on September 9,
2026 in subscription `90babfb4-0fe2-402a-ac05-b09dbe4f234c`, tenant
`1e520fc6-a277-42e0-99cf-33d7a1cb0f8c`. The signed-in Gmail account is both
subscription Owner and tenant Global Administrator.

The full private VNet deployment completed before the identity test:

- Hosted Agent `craigslist-agent-personal-vnet:1` passed Python, governed
  Craigslist search, and browser navigation checks.
- Terraform deployed private broker Container App
  `ss-personal-vnet-broker-v5y8fi`.
- Private `/health` returned HTTP `200`; an unauthenticated `/mcp` request
  returned HTTP `401`.
- Foundry, ACR, Log Analytics, and Application Insights were returned to private
  mode after the proof.

The personal identity resources are:

| Resource | ID or name |
|---|---|
| Broker client ID | `e42bba39-26e4-4d48-9328-65f04935148c` |
| Broker service principal | `6f390238-1e4f-4cb2-8138-e405eef7d72e` |
| Broker delegated scope ID | `a48dd085-1bda-44a1-bc50-04436c5ea4db` |
| Historical Foundry connection | `personal-mcp-broker-agent-user-proof` |
| Current Foundry connection | `personal-mcp-broker-user-entra-token-proof` |
| Toolbox | `personal-agent-user-proof:2` |
| Proof Hosted Agent | `craigslist-agent-personal-identity-proof:2` |
| Blueprint client/object ID | `8519fba4-2b21-44d1-a4c0-8beaa84b2598` |
| Blueprint principal ID | `ed891f0f-c1cf-416d-ad52-f1d5b22d40bf` |
| Agent identity principal/client ID | `c685f6a8-0627-43c2-8b3f-5c92ff406ee0` |

The administrator operation succeeded. The blueprint declares
`McpBroker.Invoke`, allows only that scope to be inherited, and the broker
preauthorizes that blueprint. Microsoft Graph contains an `AllPrincipals`
delegated grant from blueprint principal
`ed891f0f-c1cf-416d-ad52-f1d5b22d40bf` to broker principal
`6f390238-1e4f-4cb2-8138-e405eef7d72e` for `McpBroker.Invoke`.

The Graph update also exposed a portability defect in the setup script:
updating `requiredResourceAccess` on an Agent Identity Blueprint requires
`@odata.type: #microsoft.graph.agentIdentityBlueprint`. The script now includes
that discriminator.

Administrator consent removed the Microsoft-tenant `AADSTS90094` gate but did
not make the managed Toolbox path deliver a token:

1. A normal `azd ai agent invoke` reached the Hosted Agent, but Toolbox returned
   `INTERNAL_ERROR` while resolving the connection.
   - APIM request ID: `c0faf210-0056-4f2b-8a22-d420818fcc26`
2. The documented interactive-agent client flow initially returned
   `AADSTS500011` because the Foundry-created blueprint did not expose its
   documented `api://<blueprint>/access_agent` resource URI and scope.
   - Timestamp: `2026-09-09T22:27:05Z`
   - Request ID: `b20b6a67-734e-4000-a8a8-e8170cb23300`
   - Correlation ID: `da8318f1-3c83-4b86-b123-eb6fd37fa96a`
3. After adding the single-tenant `access_agent` scope and granting the
   invocation client tenant-wide consent, Entra issued a user token with:
   - `aud=8519fba4-2b21-44d1-a4c0-8beaa84b2598`
   - `azp=197d0f10-8cf4-4b3b-bef9-e1f37fd6c29c`
   - `oid=0dab5a72-fec0-46c4-adbe-279ef850a2ee`
   - `scp=access_agent`
   - `tid=1e520fc6-a277-42e0-99cf-33d7a1cb0f8c`
4. Sending that token directly as the Hosted Agent bearer token was rejected by
   the Foundry front door with HTTP `403`.
   - APIM request ID: `4b34365b-aa1e-4ed7-9597-f1b1641e88b2`
5. Sending the normal Foundry bearer token plus the blueprint token in
   `x-client-authorization` was accepted by the Hosted Agent with HTTP `200`,
   but Toolbox still returned the same connection-resolution `INTERNAL_ERROR`.
   - APIM request ID: `dfc887f6-6b7e-4c46-9ad0-aed550af518e`
   - Request ID: `fb9f0a4e2f5fba1414b8b62d6d3dbf1f`
6. The private broker logs contain no matching request, so the failure remains
   upstream of broker networking and JWT validation.

The personal-tenant proof therefore narrows the blocker: tenant administrator
consent is sufficient to create the intended permission grant, but the current
Hosted Agent Responses and managed Toolbox path does not use the available
blueprint-audience user token when resolving `AgentUserImpersonation`. The
remaining issue is Foundry caller-token propagation or connection resolution,
not tenant consent.

## Current `UserEntraToken` retest

The `Ab3y/AIFoundry-Toolbox` repository cannot explain the hosted failure. At
commit `3cc86aa4bd4a317a809d4e53ffe3fe744dc96387` it contains only
`README.md` and `TRAINING-PLAN.md`; it has no Toolbox runtime, connection
resolver, SDK, tests, releases, or deployment implementation. It is an
unofficial training aid rather than product source.

The useful implementation evidence came from current Microsoft artifacts:

- Current Foundry documentation and `azd` expose `user-entra-token`.
- The current `azd` source serializes that value as ARM
  `authType=UserEntraToken`, not `AgentUserImpersonation`.
- The exact deployed hosting dependency
  `agent-framework-foundry-hosting==1.0.0b260903` reads
  `get_request_context().platform_headers()` for every Toolbox HTTP request and
  forwards `x-agent-foundry-call-id`.

A parallel connection was therefore created without deleting the historical
reproduction:

```text
name: personal-mcp-broker-user-entra-token-proof
authType: UserEntraToken
category: RemoteTool
metadata.type: generic_mcp
audience: api://e42bba39-26e4-4d48-9328-65f04935148c
```

Toolbox `personal-agent-user-proof:2` references only that connection and is
the current default. Hosted Agent
`craigslist-agent-personal-identity-proof:2` uses the unversioned Toolbox
consumer endpoint and Responses/Activity protocol `2.0.0`.

A fresh-session normal invocation no longer returned the opaque
`INTERNAL_ERROR`. It reached Foundry's OBO service and returned:

```text
POST obotoken.vienna-centralus.svc/obotoken/v1.0/getuseraccesstoken
HTTP 400 UserError
Audience for incoming token is incorrect
```

- APIM request ID: `1be2cd69-6ef1-4974-a8e1-456fb171336d`
- Request/operation ID: `850b1c5447a1482244f513c9b1f889f0`
- OBO request ID: `8e6b0f7a93916c57`

This proves the Responses `2.0.0` call ID and the `UserEntraToken` connection
resolve far enough to invoke the token-exchange service. The remaining failure
is the audience of the user assertion that Foundry supplies to OBO.

The valid blueprint token was then reacquired with:

```text
aud=8519fba4-2b21-44d1-a4c0-8beaa84b2598
azp=197d0f10-8cf4-4b3b-bef9-e1f37fd6c29c
oid=0dab5a72-fec0-46c4-adbe-279ef850a2ee
scp=access_agent
tid=1e520fc6-a277-42e0-99cf-33d7a1cb0f8c
```

A new-session invocation sent that token through
`x-client-authorization: Bearer <token>`. Foundry accepted the Hosted Agent
request but OBO returned the same audience error:

- APIM request ID: `a0ec110f-a346-47e3-8225-a1b0e04cc206`
- Request/operation ID: `b0c31ac5d99ec0dd16981cc2b6014403`
- OBO request ID: `9748dfd9ee3cfcf2`

Therefore `x-client-authorization` is not the caller assertion consumed by the
Toolbox OBO service. The Responses endpoint requires a Foundry-audience bearer
token for inbound RBAC, while OBO requires a different incoming-token audience;
the public Responses invocation contract does not document a second header that
binds the blueprint-audience user assertion to the server-side call context.
No request reached the broker.

## Rejected fallback

The implementation does not forward `x-agent-user-id` as customer authorization.
It is an unsigned platform partition identifier, is not forwarded by the official
Toolbox client, and cannot be independently validated by the broker. Using it
would violate the requirement that customer selection come only from a validated
identity rather than a caller- or agent-supplied header.

## Remaining work and historical alternatives

The personal-tenant customer route is working. The remaining production-readiness
work is:

1. Run the deferred cross-user and cross-customer negative authorization tests.
2. Retire the shared Sandbox profile only after those tests and migration
   approval.
3. Close Foundry and ACR only when lockdown is explicitly requested.
4. If the official Microsoft tenant or `UserEntraToken` path is resumed,
   provide a permitted consent policy or a corrected Foundry OBO caller
   assertion.

The correlation IDs above and the contradiction between the secret-optional
documentation and the public connection contract are sufficient to open a
Microsoft support or product issue without provisioning customer resources.

## Preserved proof resources

The following proof resources remain available for investigation and must not be
deleted implicitly:

- Entra application: `ss-tenant-aware-mcp-broker`
- Container App: `ss-vnet-broker-proof`
- Managed identity: `ss-vnet-broker-proof-id`
- Foundry connection: `tenant-mcp-broker-user-proof`
- Foundry Toolbox: `tenant-broker-proof`
- Hosted Agent: `craigslist-agent-tenant:1`
- Foundry connection: `tenant-mcp-broker-agent-user-proof`
- Foundry Toolbox: `tenant-agent-user-proof:1`
- Hosted Agent: `craigslist-agent-tenant-agent-user-proof:1`
- Entra Agent ID blueprint:
  `ss-vnet-ai-k7fncj-ss-vnet-project-craigslist-agent-tenant-agent-user-proof-49988-AgentIdentityBlueprint`
- Personal resource group: `ss-agent-personal-vnets`
- Personal broker app and service principal:
  `ss-personal-tenant-aware-mcp-broker`
- Personal private broker Container App:
  `ss-personal-vnet-broker-v5y8fi`
- Personal Foundry connection:
  `personal-mcp-broker-agent-user-proof`
- Personal Foundry `UserEntraToken` connection:
  `personal-mcp-broker-user-entra-token-proof`
- Personal Toolbox versions: `personal-agent-user-proof:1` and
  `personal-agent-user-proof:2` (default)
- Personal OAuth2 connections:
  `personal-mcp-broker-oauth-proof` and `mcp-oauth`
- Personal OAuth2 Toolbox versions: `personal-agent-oauth-proof:1` and
  `personal-agent-oauth-proof:2` (default)
- Public DNS control connection and Toolbox:
  `mcp-learn` and `personal-public-dns-proof:1`
- Personal proof Hosted Agent:
  `craigslist-agent-personal-identity-proof:1` and
  `craigslist-agent-personal-identity-proof:2` and
  `craigslist-agent-personal-identity-proof:3` through
  `craigslist-agent-personal-identity-proof:11`
- Personal Agent ID blueprint:
  `ss-personal-vnet-ai-v5y8fi-ss-personal-vnet-project-craigslist-agent-personal-identity-proof-9ae84-AgentIdentityBlueprint`
- Personal invocation client:
  `ss-personal-agent-invocation-client`

The original `ss-agent-day3`, `ss-agent-vnets`, and
`craigslist-agent-vnet:7` deployments remain in place.
