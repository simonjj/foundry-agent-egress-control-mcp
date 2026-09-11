# Toolbox and MCP Broker Tool-Flow Plan

Date: September 9, 2026
Last updated: September 11, 2026

## 1. Goal

Implement customer-separated tools behind one shared Microsoft Agent Framework
Hosted Agent without placing an application-owned orchestrator in front of every
conversation turn.

Foundry continues to own user sessions, persistence, resume, and agent scaling.
Foundry Toolbox owns reusable tool integration. Entra Agent ID and Toolbox own
the user-plus-agent token exchange for the current secretless candidate. The
tenant-aware MCP broker remains the authorization and routing boundary that
maps a validated user to exactly one customer Sandbox pair.

The target flow is:

```text
User
  -> shared MAF Hosted Agent
  -> Foundry Toolbox
       - tool catalog and versioning
       - provisioned-agent user impersonation
       - per-user call-context isolation
       - private project connectivity
  -> tenant-aware MCP broker
       - validate delegated JWT
       - resolve identity to customer entitlement
       - select customer endpoint and credential
       - validate tool arguments and browser URLs
       - enforce and audit cross-customer denial
  -> customer-specific Python and Playwright ACA Sandboxes
       - unique credentials
       - private ingress
       - exact customer-domain egress
```

## 2. Non-negotiable security invariants

1. The model never supplies or selects `customer_id`, city, tenant, Sandbox ID,
   downstream endpoint, or credential.
2. The broker derives customer scope only from a cryptographically validated
   delegated identity and a trusted entitlement source.
3. `x-agent-user-id`, prompt text, model output, and caller-provided routing
   headers are not downstream authorization.
4. An Austin identity can never reach a Houston Sandbox, even if the model calls
   the wrong tool name, constructs a Houston URL, or is prompt-injected.
5. Every customer has a distinct Python/search Sandbox and Playwright Sandbox,
   unique downstream credentials, and default-deny egress restricted to its
   exact approved hostnames.
6. Existing `ss-agent-day3`, `ss-agent-vnets`, and
   `craigslist-agent-vnet:7` resources remain unchanged.
7. Proof and reproduction resources are retained until explicitly approved for
   deletion.
8. No client secret, access token, user object ID, or customer credential is
   committed to source or stored in Terraform state.

## 3. Current implementation state

### Implemented

- One shared proof Hosted Agent using Responses protocol `2.0.0`.
- A Foundry Toolbox and RemoteTool connection targeting the private broker.
- A private FastMCP broker running in the existing internal Container Apps
  environment.
- Broker validation of JWT signature, issuer, audience, expiry, tenant,
  delegated scope, and user object ID.
- Bounded JWKS caching, unknown-key suppression, refresh coalescing, and
  unavailable-service handling.
- A `who_am_i` proof tool.
- Hash-based user-to-customer entitlement resolution using the validated tenant
  and object IDs.
- Customer route configuration with separate Python and browser MCP endpoints,
  server-side credentials, and approved hostnames.
- Broker tools `customer_context`, `run_python`, `search_craigslist`, and
  `browse_url`.
- Customer-specific Python and Playwright Sandbox instances labeled
  `customer-personal`.
- Default-deny Sandbox egress restricted to the approved Seattle Craigslist
  hosts.
- Broker-side URL and Craigslist-site validation.
- Live Hosted Agent calls through OAuth2 Toolbox, broker routing, and both
  customer Sandboxes.
- Private broker health and unauthenticated rejection checks.
- An additive `AgentUserImpersonation` RemoteTool connection and isolated
  Toolbox.
- A separate multi-protocol M365 Digital Worker proof agent with active
  blueprint and instance identities.
- Least-privilege blueprint declarations for inheriting only
  `McpBroker.Invoke`, plus broker-side blueprint preauthorization.
- The private Terraform desired state remains intact.

### Not implemented

- A no-admin consent path accepted by Microsoft tenant policy.
- Cross-customer negative tests.
- Retirement of the earlier shared Sandbox profile.
- Final Foundry and ACR lockdown; both remain intentionally public outside
  Terraform until explicitly requested.

### Secretless custom OAuth proof result

The original `UserEntraToken` connection failed in Foundry OBO with
`Audience for incoming token is incorrect`. The supported secret-backed OAuth2
path now creates successfully and reaches user consent, but Toolbox cannot
resolve the private Container Apps broker hostname from its selected network
path.

Current Microsoft documentation says a custom OAuth connection for a
customer-owned MCP audience can omit `clientSecret` when supported by the OAuth
application. The installed `azure.ai.connections` extension `1.0.0-beta.6`
still rejects a missing `--client-secret`, so the proof used the ARM connections
API directly.

The ARM request passed connection-schema validation and reached the hidden
Connector Gateway used by Foundry. Connector Gateway rejected both the
secretless request and a request matching the current portal payload:

```text
ConnectorNamespaceCustomConnectorDirectInvokeRequiresApiDefinitionV3
The custom connector ... uses the 'DirectInvoke' invocation mode, which
requires a version 3.0 API definition. Update the API definition or use the
'ProxyInvoke' invocation mode, then try again.
```

The same failure occurred with:

- project- and account-scoped connection URLs;
- API versions `2025-04-01-preview`, `2025-09-01`, `2026-05-01`, and
  `2026-05-15-preview`;
- the required custom MCP metadata
  `oAuthProvider=custom` and `type=custom_MCP`;
- an omitted client-secret property and the portal's empty client-secret value;
- a fresh connection name; and
- an attempted `ProxyInvoke` hint in both connection properties and metadata.
- the same secretless payload with the public Microsoft Learn MCP endpoint,
  ruling out private target reachability as the cause of connection creation
  failure.

No OAuth connection resource persisted and no redirect URI was generated. The
public Foundry connection schema does not expose an API definition or supported
invocation-mode setting, so the proof is blocked at the Foundry-to-Connector
Gateway integration boundary rather than at the broker or Entra application.

The supported confidential-client path was subsequently deployed in the
personal tenant:

- connection `mcp-oauth`;
- Toolbox `personal-agent-oauth-proof:2` as the default;
- Hosted Agent `craigslist-agent-personal-identity-proof:3`;
- an `oauth_consent_request` followed by a post-consent MCP `tools/list`
  attempt.

The current blocker is private DNS/network reachability from Toolbox to the
broker's internal Container Apps hostname. No MCP request reached the broker.

An additive Hosted Agent diagnostic isolated the network ownership:

- version `5` bypassed Toolbox;
- the Hosted Agent container resolved the broker hostname to `10.63.1.194`;
- HTTPS `/health` returned `200` with `{"status":"ok"}`;
- version `6` restored OAuth Toolbox mode and reproduced Connector Gateway's
  `Name or service not known` error for the same hostname.

Customer private DNS, routing, peering, TLS, and broker ingress therefore work
from the Foundry-injected agent path. The remaining network failure is specific
to Toolbox/Connector Gateway egress or its selection of the delegated subnet.

A public control removed general Toolbox DNS and MCP functionality as possible
causes. Connection `mcp-learn` and Toolbox `personal-public-dns-proof:1`
successfully reached `https://learn.microsoft.com/api/mcp`, enumerated its
tools, invoked `microsoft_docs_search`, and returned a real documentation
result. Hosted Agent version `8` then restored the private OAuth Toolbox.

Replacing the public control target with the literal broker address
`https://10.63.1.194/mcp` did not bypass DNS. Connector Gateway blocked the
request under outbound SSRF protection and explicitly required the
VNet/DataProxy path for private endpoints. The control was restored to
Microsoft Learn in `personal-public-dns-proof:3`.

On September 11, 2026, ARM inspection showed that the account capability host
was healthy but the project had no capability host. The current Microsoft
Foundry Basic VNet template creates a project capability host even without BYO
Storage, Cosmos DB, or AI Search bindings. Terraform now deploys:

```text
Microsoft.CognitiveServices/accounts/projects/capabilityHosts
name: caphostproj
capabilityHostKind: Agents
```

After `caphostproj` reached `Succeeded`, the same OAuth2 invocation no longer
failed DNS resolution. DataProxy reached the private broker, and the broker
returned HTTP `401`; DataProxy surfaced it as HTTP `424
CustomerManagedDownstreamError`. The private network gate is resolved. The
broker was then redeployed with bounded, non-sensitive authentication rejection
logging.

The next invocation emitted a fresh OAuth consent request. As in the earlier
test, the callback displayed `Code ... not found`, but the authorization state
was retained. A subsequent invocation completed without another consent
request, executed `who_am_i`, and produced authenticated broker responses
`200`, `200`, `202`, and `200`. No authentication rejection was logged. The
personal-tenant delegated identity and private-network proof therefore passes
end to end.

### Customer-routing proof result

The broker now hashes the validated `(tenant ID, object ID)` pair and maps it to
`customer-personal`. It selects dedicated customer Python and browser Sandbox
routes and keeps both downstream credentials server-side.

Hosted Agent version `9` initialized Toolbox and completed `tools/list`, but an
agent-side allowlist filtered out every discovered function. Toolbox prefixes
connection-backed tools with `mcp-oauth___`, while the allowlist contained the
unprefixed broker names.

Hosted Agent version `10` disabled that redundant filter to diagnose and
validate the complete broker catalog. Startup diagnostics confirmed these
model-facing tools:

```text
mcp-oauth___browse_url
mcp-oauth___customer_context
mcp-oauth___run_python
mcp-oauth___search_craigslist
mcp-oauth___who_am_i
```

Hosted Agent version `11` restores the least-privilege allowlist with the exact
prefixed names for `customer_context`, `run_python`, `search_craigslist`, and
`browse_url`; `who_am_i` is no longer model-facing in the active version.

The following live Hosted Agent checks passed on September 11, 2026:

| Step | Result |
|---|---|
| Customer resolution | `customer-personal` |
| Python route | stdout `391` |
| Seattle Craigslist search | `https://www.craigslist.org/view/d/bothell-vintage-motobecane-nomad-mens/w4aJz14EfkrjWq9mViW5Cq` |
| Browser route | `Vintage Motobecane Nomad Men's Bicycle - sporting goods - by owner - sale - craigslist` |

The final invocation recorded five `CallToolRequest` entries: one
`customer_context`, two `run_python`, one `search_craigslist`, and one
`browse_url`. The first Python request supplied an invalid timeout and failed
broker validation before routing; the model corrected the argument and retried
successfully. The successful routed calls recorded matching
`sandbox_route_started` and `sandbox_route_completed` events for both `python`
and `browser`.

### AgentUserImpersonation proof result

Foundry accepted `AgentUserImpersonation` without a client secret. A standalone
Toolbox call correctly reported that the project default identity is
insufficient. The proof therefore uses a separate Hosted Agent classified as an
M365 Digital Worker while preserving the Responses endpoint used by the sample.
Foundry provisioned both:

- a blueprint identity; and
- a version-specific instance identity.

Calling the Toolbox through that agent supplied a user context and an opaque
Foundry call ID, but connection resolution returned `INTERNAL_ERROR` before the
broker received a request.

The blueprint now declares and permits inheritance of only
`McpBroker.Invoke`, and the broker application preauthorizes that blueprint.
The current user cannot create a grant directly through Microsoft Graph and
received `Authorization_RequestDenied`.

The documented `response_type=none` per-user consent path was also tested. With
preauthorization present, it recorded only basic Microsoft Graph sign-in scopes
and no broker grant. With preauthorization temporarily removed and
`prompt=consent`, Microsoft tenant policy returned `AADSTS90094` and required
administrator approval for `McpBroker.Invoke`. A subsequent Hosted Agent
invocation still returned `INTERNAL_ERROR` before broker ingress.

The no-admin `AgentUserImpersonation` path is therefore blocked in the official
Microsoft tenant. There is no supported connection property, MCP parameter,
query string, or customer-settable header for injecting the blueprint and
instance IDs or bypassing the consent decision.

This is a proof gate, not an assumption. Customer routing work does not proceed
until Toolbox delivers two distinct valid delegated identities to the broker.

## 4. Responsibility overlay

| Function | Hosted Agent | Foundry Toolbox | MCP broker | Other boundary |
|---|---|---|---|---|
| User sessions, persistence, resume, scaling | Owns | - | - | - |
| Single agent-facing MCP endpoint | - | Owns | Exposes tools behind it | - |
| Tool catalog, discovery, and versioning | - | Owns | Defines stable tool schemas | - |
| OAuth consent, token acquisition, refresh | - | Owns | Does not cache user tokens | Entra authorizes |
| Per-user OAuth token isolation | - | Owns | Validates received token | - |
| Agent-to-broker connection metadata | - | Owns | - | - |
| Delegated JWT validation | - | Delivers token | Owns | Entra publishes signing keys |
| Identity-to-customer mapping | - | - | Owns | Entitlement store supplies mapping |
| Customer endpoint selection | - | Static connection only | Owns | - |
| Customer credential selection | - | Static connection only | Owns | Key Vault stores credentials |
| Model-neutral tool schemas | Uses | Advertises | Owns | - |
| Browser URL and hostname validation | - | - | Owns | Sandbox egress is final backstop |
| Downstream MCP/browser context | Session source | - | Owns mapping | Sandbox isolates execution |
| Authorization audit | Emits call context | Emits tool telemetry | Records decision and route | Monitoring stores telemetry |
| Private tool path | VNet-injected | Uses project VNet | Private client | Private Link/VNet |
| Sandbox provisioning and exact egress | - | - | - | Terraform and ACA own |

## 5. Component contracts

### 5.1 Hosted Agent contract

- The agent contains one `FoundryToolbox`.
- The agent does not contain direct customer Sandbox endpoints or credentials.
- The agent never receives a customer selector as a system or tool argument.
- The agent forwards the Foundry call context through the supported
  `FoundryToolbox` implementation.

### 5.2 Toolbox contract

- The Toolbox contains one MCP entry for the broker.
- The broker connection uses custom OAuth with the broker-owned Entra audience.
- Foundry owns user consent, token storage, token refresh, and caller isolation.
- The Toolbox consumer endpoint remains stable while versions are promoted.
- Tool Search can be enabled only after authorization tests confirm that it
  cannot expand the broker's stable tool surface unexpectedly.

### 5.3 Broker identity contract

Required delegated claims:

| Claim | Requirement |
|---|---|
| `iss` | Microsoft tenant v2 issuer |
| `tid` | Configured tenant ID |
| `aud` | Broker application client ID |
| `exp`, `iat` | Present and valid |
| `scp` | Contains `McpBroker.Invoke` |
| `oid` | Present and mapped by the entitlement source |
| `sub` | Present for token identity consistency |

The broker rejects application-only tokens for customer routing. Application
roles may be added later for operator-only administration endpoints, but they
must not select a customer data plane.

### 5.4 Entitlement contract

The proof implementation uses an external mapping:

```json
{
  "<entra-object-id>": "customer-austin",
  "<entra-object-id>": "customer-houston"
}
```

The mapping must not be committed. It is loaded from Key Vault or a protected
configuration provider through the broker managed identity.

Production should replace direct user mapping with a trusted entitlement
service or signed customer claim that supports multiple users per customer.

### 5.5 Customer route contract

```json
{
  "customer_id": "customer-austin",
  "allowed_hosts": [
    "austin.craigslist.org"
  ],
  "python_mcp_url": "https://<private-austin-python>/mcp",
  "python_credential_secret": "<key-vault-secret-name>",
  "browser_mcp_url": "https://<private-austin-browser>/mcp",
  "browser_credential_secret": "<key-vault-secret-name>"
}
```

Routes are trusted configuration. They are never generated or modified by the
model.

### 5.6 Broker tool contract

The public broker surface is customer-neutral:

- `run_python(code, timeout_seconds)`
- `search_craigslist(query, limit)`
- `browser_navigate(url)`
- `browser_snapshot()`
- `browser_tabs()`

The broker:

- resolves the customer before processing tool input;
- selects the downstream route and credential;
- removes customer and city from model-visible parameters;
- validates absolute URLs, schemes, ports, redirects, and hostnames;
- forwards only to the selected customer pair;
- returns explicit authorization or validation errors;
- never falls back to a default customer.

## 6. Implementation phases and proof gates

### Phase 1 - Secretless delegated identity proof

Status: blocked after both policy and administrator proofs. The custom OAuth
branch fails at the Connector Gateway API-definition boundary. Microsoft tenant
policy blocks explicit per-user consent with `AADSTS90094`; a separate personal
tenant administrator proof successfully created the intended grant but still
failed in Toolbox connection resolution before broker ingress.

1. Preserve the custom OAuth reproduction and support correlation IDs.
2. Preserve the existing `tenant-mcp-broker-user-proof` connection.
3. Create an additive `AgentUserImpersonation` RemoteTool connection with the
   private broker target and audience.
4. Create an isolated Toolbox version referencing that connection.
5. Deploy a separate proof agent with Responses and Activity protocols and
   `activity.digitalWorkerType=m365`.
6. Configure the blueprint's required resource access and inheritable scope,
   and preauthorize it on the broker application.
7. Test documented per-user consent with `response_type=none`.
8. Confirm Microsoft tenant policy requires administrator approval and that no
   broker grant is created.
9. In an isolated administrator-controlled tenant, create the equivalent
   broker, connection, Toolbox, blueprint permission inheritance, and
   tenant-wide delegated grant.
10. Exercise both the ordinary Foundry caller token and the documented
    blueprint-audience `access_agent` token flow.
11. Stop before customer infrastructure and retain both reproductions for
    product escalation or an architecture decision.
12. If a supported identity path becomes available, invoke with Simon and Anil
    and require the broker to observe:
   - two distinct `oid` values;
   - the expected `tid`, `aud`, `iss`, and `scp`;
   - no token crossover between callers.

Gate:

- Pass: begin Phase 2.
- Fail: update `BLOCKER-tenant-aware-mcp.md` with the exact platform response
  and do not provision customer Sandboxes.

Observed result:

- The official Microsoft tenant blocks per-user consent with `AADSTS90094`.
- The personal tenant Global Administrator successfully granted
  `McpBroker.Invoke` to the Agent ID blueprint.
- The personal full VNet agent and private broker deployed and passed their
  independent application/network checks.
- Entra issued a user token with the proof blueprint as `aud` and
  `access_agent` as `scp`.
- The current documented `UserEntraToken` connection reaches Foundry's OBO
  service, which returns HTTP `400` with
  `Audience for incoming token is incorrect`.
- Sending the valid blueprint token through `x-client-authorization` produces
  the same OBO error, proving that header is not used as the caller assertion.
- No request reached the broker.

Phase 2 and customer Sandbox provisioning remain blocked. The active blocker is
now the missing Responses contract for binding a blueprint-audience user token
to the server-side caller context used by `UserEntraToken` OBO. Administrator
consent and connection resolution have both been proven independently.

### Phase 2 - Broker authorization and routing core

1. Add typed entitlement and route models.
2. Add configuration providers backed by Key Vault.
3. Resolve `oid -> customer_id -> CustomerRoute` once per tool call.
4. Add stable customer-neutral tools.
5. Add strict browser URL validation.
6. Add downstream authentication without exposing credentials to the model.
7. Add structured authorization audit events.
8. Add unit tests for unknown users, missing routes, wrong scopes, wrong hosts,
   redirects, and credential lookup failures.

Gate:

- A fake Austin identity cannot obtain or address the Houston route under any
  broker API or tool argument.

### Phase 3 - Customer Sandbox pairs

1. Add a parallel `infrastructure/terraform-tenant` root.
2. Provision Austin Python and Playwright Sandboxes.
3. Provision Houston Python and Playwright Sandboxes.
4. Give every pair unique credentials.
5. Configure exact default-deny egress:
   - Austin only to approved Austin hosts;
   - Houston only to approved Houston hosts.
6. Store credentials in Key Vault.
7. Grant only the broker managed identity read access to required secrets.
8. Keep every ingress path private.

Gate:

- Direct wrong-city network requests fail inside each Sandbox independently of
  the broker.

### Phase 4 - Downstream session and browser isolation

1. Correlate each Foundry tool call with a broker request context.
2. Maintain separate downstream MCP/browser contexts for concurrent sessions.
3. Reuse a customer Sandbox pair across sessions without sharing browser state.
4. Expire idle contexts deterministically.
5. Survive broker scale-out and restart, or document and enforce any
   single-replica proof limitation.

Gate:

- Two concurrent users mapped to the same customer do not share Playwright
  cookies, tabs, or navigation state.

### Phase 5 - Adversarial and lifecycle validation

- Two-user delegated identity.
- Correct customer routing.
- Cross-customer prompt injection.
- Direct wrong-city tool calls.
- Browser redirects to a disallowed city.
- Python-originated wrong-city HTTP requests.
- Sandbox firewall enforcement.
- Broker restart and scale.
- Native Foundry response/session resume.
- Token expiry and refresh.
- Telemetry correlation without token or credential disclosure.
- Original and VNet deployment regressions.
- Zero Terraform drift in every root.

### Phase 6 - Rollout and documentation

1. Promote the validated Toolbox version.
2. Deploy the tenant Hosted Agent version using that default Toolbox.
3. Document onboarding for a new customer and customer users.
4. Document rollback:
   - Toolbox default-version rollback;
   - Hosted Agent version rollback;
   - broker image rollback;
   - route disable without resource deletion.
5. Document explicit cleanup separately; do not delete proof or customer
   resources implicitly.

## 7. Repository change map

| Area | Planned changes |
|---|---|
| `scripts/` | Secretless OAuth and UserEntraToken setup; blueprint permission declaration |
| `src/broker/` | Entitlements, routes, downstream client, validators, audit |
| `src/agent/` | Stable Toolbox integration only |
| Hosted Agent deployment | Add a production profile only after a real Activity host is implemented |
| `infrastructure/terraform-tenant/` | Customer Sandboxes, Key Vault, RBAC, networking |
| `tests/` | Identity, routing, URL, concurrency, and negative tests |
| Documentation | Architecture, deployment, rollback, onboarding, cleanup |

## 8. Failure and rollback rules

- Never replace the working VNet agent while the tenant proof is incomplete.
- Create new connections and Toolbox versions additively.
- Do not mutate the current default Toolbox version until the candidate passes.
- Do not fall back to `x-agent-user-id`, prompt-provided customer values, or
  static shared Sandbox credentials.
- If OAuth consent or token delivery fails, preserve logs and resources and stop
  before customer infrastructure.
- If routing validation fails, disable the candidate broker route and retain the
  last known-good proof image.

## 9. Immediate implementation slice

The implementation slice now contains:

- `configure-broker-oauth-connection.ps1` for supported secret-backed custom
  OAuth2 creation using an in-memory `SecureString`;
- `configure-broker-agent-user-connection.ps1` for the documented
  `UserEntraToken` candidate;
- `configure-agent-blueprint-permissions.ps1` for least-privilege blueprint
  declarations, broker preauthorization, grant inspection, and an explicit
  administrator-consent switch;
- an optional Terraform-managed private broker in the VNet root;
- `deployments/personal-vnet` for full personal-subscription validation; and
- `deployments/personal-identity-proof` for the isolated Responses + Activity
  Agent ID reproduction.

The custom OAuth script now uses the supported `azd ai connection create`
command, accepts the client secret as a `SecureString`, and does not serialize
it to a repository or temporary file. Secretless ARM creation remains blocked
by `ConnectorNamespaceCustomConnectorDirectInvokeRequiresApiDefinitionV3`, but
the secret-backed personal-tenant connection succeeds.

The historical `AgentUserImpersonation` resources remain preserved. The
personal tenant retains the `UserEntraToken` proof and now also has OAuth2
connection `mcp-oauth`, default Toolbox `personal-agent-oauth-proof:2`, and
normal OAuth Hosted Agent version `11`. OAuth consent is reached, project
capability host `caphostproj` activates the VNet/DataProxy path, and the
post-consent `who_am_i` request reaches the broker and passes delegated-token
validation. Customer routing and dedicated Python/browser Sandbox forwarding
now pass end to end. Cross-user and cross-customer negative authorization tests
remain deferred, and the earlier shared Sandboxes remain preserved.

The identity proof profiles declare Activity alongside Responses only to make
Foundry provision a Digital Worker blueprint. The current application hosts the
Responses protocol only, so these profiles are non-production reproductions. A
production Digital Worker profile must first add and validate an Activity host
rather than advertise an unimplemented endpoint.
