# Tenant-aware MCP identity proof blocker

Date: September 8, 2026

The tenant-aware implementation is stopped at the mandatory identity proof gate.
The full customer Sandbox deployment and routing broker were not started because
Foundry could not pass the delegated user identity to the custom MCP broker.

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
- Foundry, ACR, and the existing VNet deployment were returned to their locked
  state after every proof operation.

## Failed proof

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

## Documented alternative is blocked

Foundry documentation directs customer-owned MCP audiences to a custom OAuth
connection. The current Foundry connection schema and `azd ai connection`
implementation support only `clientId` and `clientSecret` for custom OAuth.
They do not expose certificate, federated identity credential, client assertion,
managed identity, or PKCE authentication for the OAuth client.

The Microsoft tenant rejects client secrets under policy
`538f1913-366a-440a-95a0-e195cb55b282`, so the documented custom OAuth route
cannot be configured for this proof application.

## Rejected fallback

The implementation does not forward `x-agent-user-id` as customer authorization.
It is an unsigned platform partition identifier, is not forwarded by the official
Toolbox client, and cannot be independently validated by the broker. Using it
would violate the requirement that customer selection come only from a validated
identity rather than a caller- or agent-supplied header.

## Resolution required

At least one of the following is required before the full implementation can
continue:

1. Foundry supports `UserEntraToken` OBO to customer-owned `api://` audiences.
2. Foundry custom OAuth supports certificate or federated client authentication.
3. An approved Microsoft tenant exception permits a tightly controlled OAuth
   client secret.
4. The architecture changes to use per-customer Hosted Agent identities, or
   another trusted identity gateway, instead of delegated user identity at the
   MCP broker.

## Preserved proof resources

The following proof resources remain available for investigation and must not be
deleted implicitly:

- Entra application: `ss-tenant-aware-mcp-broker`
- Container App: `ss-vnet-broker-proof`
- Managed identity: `ss-vnet-broker-proof-id`
- Foundry connection: `tenant-mcp-broker-user-proof`
- Foundry Toolbox: `tenant-broker-proof`
- Hosted Agent: `craigslist-agent-tenant:1`

The original `ss-agent-day3`, `ss-agent-vnets`, and
`craigslist-agent-vnet:7` deployments remain in place.
