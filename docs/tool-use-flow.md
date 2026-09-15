# Tool-use flow — what each component does and why

This document walks a single tool call end to end for each of the two governed
tool paths in the solution:

1. **Python code interpreter** running in an ACA Sandbox, reached through the
   private MCP broker.
2. **Playwright Workspace** browser automation, reached directly from Foundry
   through an approval-gated Toolbox.

Both walkthroughs use the same four-phase skeleton so they can be compared
side by side. The step numbers ①–⑧ match the labels in
[`images/tenant-aware-mcp-call-flow-3.svg`](images/tenant-aware-mcp-call-flow-3.svg).

## How to read the outline

| Level | Formatting | Meaning |
| --- | --- | --- |
| High-level | **<u>Bold and underlined</u>** | Phase of the flow — the "what is happening now" |
| Mid-level | <u>Underlined</u> | Step within the phase — a single component doing a single job |
| Low-level | Plain bullets | Mechanics — the actual call, check, file, or value |

Every mid-level step states the control it enforces, so the "why" is explicit
rather than implied.

---

## Part 1 — Python code interpreter on an ACA Sandbox

**Entry point:** the model decides to call `run_python` or `search_craigslist`.
**Governing principle:** the agent never holds a Sandbox credential and never
knows which Sandbox belongs to the caller. Both are resolved server-side from a
validated delegated identity.

### **<u>Phase 1 — The caller is identified and the agent selects a tool</u>**

#### <u>Step 1.1 — The user submits a prompt (①)</u>

*Control: every downstream decision derives from a real, interactively signed-in
user — not from a service identity.*

- The caller reaches the Foundry Hosted Agent
  `craigslist-agent-personal-identity-proof` (version `2`) through the Foundry
  playground or a Responses client.
- Authentication is interactive Microsoft Entra sign-in. The resulting token is
  a **delegated** token carrying `tid` (tenant) and `oid` (user object ID).
- This matters because the broker's entire routing decision is a function of
  `tid` and `oid`. A service principal or app-only token cannot be routed and is
  rejected later in Step 2.2.

#### <u>Step 1.2 — The agent process composes its toolset at startup</u>

*Control: the tool surface is fixed by configuration at boot, not negotiated at
runtime by the model.*

- In `src/agent/main.py`, when `TENANT_BROKER_TOOLBOX_ENDPOINT` is set, the
  agent constructs a `LoggedFoundryToolbox` pointed at the broker Toolbox.
- `allowed_tools` is read from `TENANT_BROKER_TOOLBOX_ALLOWED_TOOLS` via
  `configured_toolbox_tools(...)`. Only these exact names are exposed:
  - `mcp-oauth___customer_context`
  - `mcp-oauth___run_python`
  - `mcp-oauth___search_craigslist`
- `approval_mode="never_require"` — these tools are pre-authorized. They are
  safe to auto-run precisely *because* the broker re-derives authority from the
  caller's token on every single call; nothing is trusted from the agent side.
- `LoggedFoundryToolbox.connect()` logs the exact tool names the Toolbox
  actually exposed, which is the audit record proving the allowlist took effect.

#### <u>Step 1.3 — The model chooses a tool</u>

*Control: the model is an untrusted planner, never an authority.*

- The system instructions tell the model to call `customer_context` first and to
  use only the customer-approved hosts it returns.
- The model sees tool names and schemas only. It never sees the Sandbox URL, the
  Sandbox bearer token, or the customer ID mapping.
- If the model were fully compromised and asked for a disallowed host, the
  request would still fail at Step 3.1 — model behaviour is a usability control
  here, not a security control.

### **<u>Phase 2 — The broker authenticates and authorizes the call</u>**

#### <u>Step 2.1 — Foundry attaches the delegated token (②③)</u>

*Control: identity is carried to the tool plane rather than being exchanged for
a shared service credential.*

- The Toolbox uses a Foundry connection of type OAuth2 (`mcp-oauth`).
- Foundry performs the on-behalf-of exchange and sends the user's delegated
  access token as `Authorization: Bearer …` to the broker's `/mcp` endpoint.
- The token must carry the delegated scope `McpBroker.Invoke`.

#### <u>Step 2.2 — `EntraBearerMiddleware` validates the token</u>

*Control: fail closed on identity before any tool code is reachable.*

- In `src/broker/server.py`, the middleware intercepts every HTTP request except
  `/health`, so no MCP tool can execute before validation completes.
- `_extract_token` requires a `Bearer` prefix, a token of at most 8192 bytes,
  a signing algorithm of exactly `RS256`, and a well-formed `kid`. Pinning
  `RS256` blocks algorithm-confusion attacks such as `alg: none` or HMAC
  substitution.
- `_resolve_signing_key` resolves `kid` against the tenant JWKS endpoint, with a
  300-second cache, a 30-second forced-refresh cooldown, and a negative cache of
  unknown `kid` values. This allows real key rollover while preventing an
  attacker from forcing unbounded JWKS fetches with fabricated `kid` values.
- `_decode_claims` verifies signature, `audience`, `issuer`, and requires the
  claims `aud`, `exp`, `iat`, `iss`, `sub`, `tid`. It then additionally requires:
  - `McpBroker.Invoke` present in `scp`
  - `tid` equal to the configured `ENTRA_TENANT_ID`
  - a non-empty `oid`
- Failure modes are deliberately distinct:
  - invalid, expired, wrong-audience, or under-scoped token → **401**
  - JWKS genuinely unreachable → **503**, so an infrastructure outage is never
    silently reported as an authorization failure.
- Validated claims are stored in a `contextvars.ContextVar` and reset in a
  `finally` block, so claims cannot leak between concurrent requests.

#### <u>Step 2.3 — `CustomerRouter` resolves the caller to a customer</u>

*Control: the mapping from person to infrastructure is data, not code, and is
validated at boot.*

- `CustomerRouter.from_environment()` runs at **import time**. If the routing
  configuration is malformed, the broker refuses to start rather than starting
  in a permissive state.
- Boot-time validation includes:
  - every entitlement key must match `^[0-9a-f]{64}$` (a SHA-256 digest)
  - every customer ID must be a valid DNS-style label
  - `python_mcp_url` must be absolute HTTPS, path exactly `/mcp`, with no query,
    fragment, or embedded credentials
  - `allowed_hosts` must be a non-empty array of valid host patterns
  - the Sandbox token must be present in the environment variable named by
    `python_token_env`, otherwise startup fails
  - every entitled customer must have a configured route
- At request time, `identity_key(tid, oid)` computes `SHA256("<tid>:<oid>")` and
  looks it up in `CUSTOMER_ENTITLEMENTS_JSON`. Hashing means raw tenant and user
  identifiers are never stored in configuration or printed in diffs.
- No match raises `PermissionError` — an unknown but perfectly valid Entra user
  gets no tools at all. This is the deny-by-default property of the design.

### **<u>Phase 3 — The Sandbox executes the work</u>**

#### <u>Step 3.1 — The broker validates arguments before dialling out (④)</u>

*Control: authorization is enforced on the broker, not delegated to the Sandbox.*

- For `run_python`: `code` must be non-empty and at most 100,000 characters;
  `timeout_seconds` must be between 1 and 60.
- For `search_craigslist`: `query` must be non-empty and at most 200 characters;
  `limit` must be between 1 and 20. Then `require_allowed_craigslist_site`
  normalizes the site, checks it against `^[a-z0-9-]{1,40}$`, expands it to
  `<site>.craigslist.org`, and tests it against *this customer's*
  `allowed_hosts` — including correct wildcard handling in `host_is_allowed`.
- This check runs **before** the outbound call is made. A request for a site
  outside the customer's entitlement never reaches any Sandbox, so the ACA
  egress policy is a second layer rather than the only layer.

#### <u>Step 3.2 — The broker injects the server-side Sandbox credential</u>

*Control: the credential exists only on the broker, and only for the duration of
one call.*

- `_call_sandbox_tools` reads `route.python_mcp_url` and `route.python_token`
  from the resolved route. `CustomerRoute` declares `python_token` with
  `field(repr=False)`, so the secret is not printed if the object is logged.
- The broker opens a streamable-HTTP MCP client to the Sandbox with an
  `Authorization` header it constructs itself, `follow_redirects=False` (so a
  redirect cannot bounce the bearer token to another host), and explicit
  connect/read/write timeouts.
- `SANDBOX_CALL_LIMIT` (16) bounds concurrent Sandbox calls; `JWT_VALIDATION_LIMIT`
  (16) bounds concurrent CPU-bound token validation. Both protect the broker from
  being used as an amplifier.
- Logging records `customer_id`, sandbox type, and tool names — enough for audit,
  with no secret and no raw identity.

#### <u>Step 3.3 — The Sandbox authenticates the broker</u>

*Control: the Sandbox trusts exactly one caller and verifies it in constant time.*

- `src/interpreter/server.py` refuses to start unless `MCP_AUTH_TOKEN` is set.
- `BearerTokenMiddleware` compares the `Authorization` header using
  `hmac.compare_digest`, which is constant-time and therefore not vulnerable to
  timing-based token recovery.
- Only `/health` bypasses the check, which is what allows platform probes to work
  without weakening the tool surface.

#### <u>Step 3.4 — `execute_python` runs the code under hard limits</u>

*Control: defence in depth inside the Sandbox, on the assumption the executed
code is hostile.*

- The code is written to a fresh `TemporaryDirectory` and run as
  `python -I -u main.py`. The `-I` flag is isolated mode: it ignores
  `PYTHONPATH`, ignores user site-packages, and does not add the script's
  directory to `sys.path`.
- The child process receives an **allowlisted** environment built by
  `_execution_environment`. Only `LANG`, `LC_ALL`, `PATH`, the proxy variables,
  and the CA-bundle variables are inherited. This is the reason the executed code
  **cannot read `MCP_AUTH_TOKEN`** — the Sandbox's own bearer token is simply not
  present in the child's environment. `HOME` and `TMPDIR` are re-pointed at the
  temporary working directory.
- On POSIX, `preexec_fn` applies `setrlimit` ceilings: 2 GiB address space, no
  core dumps, CPU seconds capped at `timeout + 1`, 50 MiB maximum file size, 128
  file descriptors, and 64 processes. The process count limit is what stops a
  fork bomb.
- `start_new_session=True` puts the child in its own process group, so a timeout
  is enforced with `os.killpg(...,SIGKILL)` and kills grandchildren too rather
  than leaving orphans behind.
- `stdout` and `stderr` are each truncated at 64,000 bytes with an explicit
  `output_truncated` flag, bounding the response size and preventing log flooding.
- Execution is dispatched with `asyncio.to_thread`, so a blocking subprocess does
  not stall the Sandbox's event loop.

#### <u>Step 3.5 — Outbound network traffic hits the ACA egress policy</u>

*Control: network-layer enforcement independent of anything the Python code does.*

- The Sandbox is attached to the Sandbox Group VNet connection `tools-egress`,
  bound to the `snet-sandbox-egress` subnet.
- `scripts/deploy-sandbox-vnet.py` provisions the Sandbox with an `EgressPolicy`
  of `default_action="Deny"` plus one `EgressHostRule(action="Allow")` per entry
  in the profile's allowed hosts. For this deployment those hosts come from
  `local.customer_craigslist_hosts`: `craigslist.org`,
  `<site>.craigslist.org`, `images.craigslist.org`, and `www.craigslist.org`.
- The live Sandbox reports `defaultAction: Deny`, `trafficInspection: Full`, and
  `enforcementMode: Enforced`, with those 4 allow rules present.
- Verify with `aca sandbox egress show` (note the subcommand takes `--group`, not
  the parent command's `--sandbox-group`).
- Scope note: the *configuration* is confirmed enforced, and `egress decisions`
  has so far returned an empty `denied` list. A denial has therefore not yet been
  directly observed at the network layer — the broker's host check in Step 3.1
  rejects out-of-policy requests before they ever generate Sandbox traffic.

### **<u>Phase 4 — The result returns to the caller</u>**

#### <u>Step 4.1 — The Sandbox returns a structured result</u>

- `run_python` returns `exit_code`, `timed_out`, `stdout`, `stderr`, and
  `output_truncated`. Reporting a non-zero exit code as data rather than throwing
  lets the model reason about and explain a failure.

#### <u>Step 4.2 — The broker normalizes and forwards it</u>

*Control: a tool-level failure is not silently rendered as a success.*

- `_result_payload` inspects `result.isError` and raises if the Sandbox reported
  an error; otherwise it serializes the MCP result.
- The response contains no endpoint, no token, and no routing metadata.

#### <u>Step 4.3 — The model composes the answer (⑧)</u>

- The tool result is returned to the model, which must cite listing URLs and
  clearly separate retrieved data from its own calculations.
- The agent is configured with `default_options={"store": False}`, so transcripts
  are not retained server-side by the Responses API.

---

## Part 2 — Playwright Workspace browser automation

**Entry point:** the model decides to call a `playwright___*` tool.
**Governing principle:** the Playwright Workspace is a **shared,
Microsoft-managed service outside the customer-controlled private tool plane**.
There is no VNet path and no private endpoint. Separation therefore rests on a
curated tool allowlist, a human approval on every action, ephemeral sessions, and
a server-side key the model never sees.

### **<u>Phase 1 — The caller is identified and the agent selects a tool</u>**

#### <u>Step 1.1 — The user submits a prompt (①)</u>

*Control: the same authenticated human who is routed for Python is also the
approver for browser actions.*

- Identical to Part 1, Step 1.1. The difference is what the identity is used
  for: here it is not used for routing, it is used for **approval**.

#### <u>Step 1.2 — The agent constructs the Playwright Toolbox</u>

*Control: an empty or wildcard allowlist is treated as a deployment bug, not a
default.*

- When `PLAYWRIGHT_TOOLBOX_ENDPOINT` is set, `src/agent/main.py` adds a second,
  fully independent `LoggedFoundryToolbox` named `playwright_browser`.
- `PLAYWRIGHT_TOOLBOX_ALLOWED_TOOLS` is read and **explicitly checked**: if it
  resolves to empty, the agent raises
  `"PLAYWRIGHT_TOOLBOX_ALLOWED_TOOLS must contain the exact curated Playwright
  Toolbox tool names."` and refuses to start. A misconfiguration therefore causes
  a crash rather than a silently wide-open browser surface.
- `approval_mode="always_require"` — the opposite of the broker Toolbox. This is
  the single most important difference between the two paths.
- The two Toolboxes share no connection, no credential, and no allowlist. A
  weakness in one does not widen the other.

#### <u>Step 1.3 — The curated allowlist was fixed at bootstrap time</u>

*Control: the allowlist is derived from a real inventory and proven to have been
applied.*

- `scripts/configure-playwright-workspace-mcp.py` connects to the Workspace's
  remote MCP endpoint and calls `list_tools()` to obtain the **actual** live
  inventory rather than a hardcoded assumption.
- `select_allowed_tools` intersects that inventory with the `SAFE_TOOLS` set, so
  a tool that has never been reviewed cannot be enabled simply because the
  upstream service added it.
- `REQUIRED_TOOL_GROUPS` asserts that `browser_navigate` and `browser_snapshot`
  survived the intersection; if not, the script fails rather than publishing a
  useless Toolbox.
- The resulting 15 tools cover navigation, clicking, typing, form fill, key
  presses, tabs, snapshots, screenshots, waits, and session create/close.
- Deliberately excluded, because each is an arbitrary-code or exfiltration
  primitive that would defeat the allowlist:
  - `browser_evaluate` and `browser_run_code` — arbitrary JavaScript in page
    context
  - `browser_file_upload` — moves local files outward
  - `browser_handle_dialog` — silently dismisses security prompts
  - `browser_network_requests` and `browser_console_messages` — bulk read of
    traffic and logs, including tokens in URLs
  - `browser_drag` — synthesises interactions that are hard to review in an
    approval prompt
- An evidence file records `inventory`, `allowed_tools`, and `denied_tools` with
  a timestamp, so the decision is auditable after the fact.

### **<u>Phase 2 — Approval is requested and granted</u>**

#### <u>Step 2.1 — The model proposes a browser action (⑤)</u>

*Control: the model may propose, but may not act.*

- Instructions require the model to create a session before browser operations,
  close it when finished, and never reuse a session across requests or
  conversations.
- Because `approval_mode="always_require"`, the call does not execute. Foundry
  instead emits a typed `mcp_approval_request` naming the specific tool, for
  example `playwright___create_browser_session`.

#### <u>Step 2.2 — The user approves or rejects (⑥)</u>

*Control: a real runtime gate, verified to block execution — not a UI nicety.*

- Every individual tool call raises its own approval. Approving a session
  creation does **not** approve the subsequent navigation.
- Rejection was tested explicitly: the acceptance suite in
  `scripts/test-vnet-agent.ps1` includes a rejection gate proving the action does
  not execute when denied.
- Operational nuance found during live testing: the **typed** approval name is
  stable (`playwright___create_browser_session`, `playwright___browser_navigate`,
  …), but the model's **conversational** confirmation phrasing varies between
  runs, for example `Approve: create session`. Automation must echo back the
  model's own quoted phrase — which is why the suite implements
  `Get-RequestedConfirmation` rather than hardcoding wording. Tool ordering also
  varies, so the suite allows a set of valid next tools while still requiring
  create, navigate, and close.

#### <u>Step 2.3 — Foundry attaches the Workspace key (⑦)</u>

*Control: the credential is held by the platform, not by the agent or the model.*

- The Foundry connection is `authType: CustomKeys`, `category: RemoteTool`,
  `metadata.type: generic_mcp`, targeting the Workspace MCP URL.
- The Workspace access token is stored as the `x-api-key` credential. Foundry
  injects it as a header at call time.
- `isSharedToAll: false` restricts the connection to this project.
- The bootstrap script asserts the access token does **not** appear in the
  connection API response, failing loudly if the platform were ever to echo it
  back.
- The token is created with a bounded lifetime (1–90 days, default 30) and the
  script is transactional: if any later step fails, it deletes both the Foundry
  connection and the Playwright access token before re-raising, so a partial
  failure does not leave an orphaned live credential.

### **<u>Phase 3 — The Workspace executes the browser action</u>**

#### <u>Step 3.1 — The request leaves the customer-controlled plane</u>

*Control: acknowledged and compensated, rather than assumed away.*

- The call goes to `…mcp.playwright.microsoft.com/playwrightworkspaces/<id>/mcp`.
  In this deployment the Workspace is `ss-personal-vnet-pww-e0w` in West US 3,
  while the Python Sandbox is in Central US.
- This is a shared multi-tenant service. Unlike Part 1, there is **no** customer
  VNet, **no** private endpoint, and **no** customer-authored egress policy on
  this path.
- The compensating controls are exactly those established above: the curated
  allowlist (Step 1.3), per-action approval (Step 2.2), the project-scoped
  server-side key (Step 2.3), and ephemeral sessions (Step 3.2).

#### <u>Step 3.2 — The Workspace runs the action in an ephemeral session</u>

*Control: no state survives to be harvested by the next request.*

- A browser session is created for the task and closed at the end of it.
- Sessions are never reused across requests or conversations, so cookies, local
  storage, and authenticated state cannot leak from one interaction to another.
- Agent instructions make browser use strictly read-only: never sign in, enter
  credentials, contact a seller, submit a form, book, bid, or purchase.
- Session cleanup failures must be reported rather than swallowed.

#### <u>Step 3.3 — Browser egress is service-managed</u>

*Control: be precise about what is and is not enforced.*

- Outbound browsing from the Workspace is managed by the service. It is **not**
  constrained by the customer's ACA egress policy.
- Target-host limitation on this path comes from agent policy and the approval
  gate, not from network enforcement. This is the material difference from
  Step 3.5 in Part 1 and should be stated plainly in any risk review.

### **<u>Phase 4 — The result returns to the caller</u>**

#### <u>Step 4.1 — The tool result returns through Foundry</u>

- Snapshots, screenshots, or interaction results return through the Toolbox to
  the model. The model never receives the `x-api-key`.

#### <u>Step 4.2 — The model composes the answer (⑧)</u>

- The model must cite listing URLs and distinguish observed page content from its
  own calculations.
- If a site blocks access or too few results are found, it must state that
  limitation rather than fabricating data.

---

## Side-by-side summary

| Dimension | Python interpreter (Part 1) | Playwright Workspace (Part 2) |
| --- | --- | --- |
| Toolbox | `personal-agent-oauth-proof:1` | `playwright-browser-automation:1` |
| Connection auth | OAuth2 delegated (`mcp-oauth`) | Custom Keys (`x-api-key`) |
| Approval mode | `never_require` | `always_require` |
| Identity flows to tool? | Yes — user token validated by the broker | No — server-side key; identity is used for approval |
| Per-caller routing | Yes — `SHA256(tid:oid)` → customer route | No — one shared Workspace |
| Tenancy | Dedicated Sandbox per customer | Shared managed service |
| Network isolation | VNet `tools-egress` + private endpoints | None on this path |
| Egress control | ACA policy, default Deny + 4 allow rules | Service-managed, not customer-enforced |
| Primary control | Identity validation and server-side routing | Tool allowlist and per-action human approval |
| Failure mode | Fails closed at broker boot and per request | Fails closed at agent boot if allowlist is empty |

## Where to verify each claim

| Claim | Source |
| --- | --- |
| Token validation and claim requirements | `src/broker/server.py` — `_extract_token`, `_decode_claims` |
| Identity → customer routing | `src/broker/routing.py` — `identity_key`, `CustomerRouter.resolve` |
| Host allowlist enforcement | `src/broker/routing.py` — `host_is_allowed`, `require_allowed_craigslist_site` |
| Sandbox process isolation | `src/interpreter/executor.py` — `_execution_environment`, `_set_resource_limits` |
| Sandbox bearer check | `src/interpreter/server.py` — `BearerTokenMiddleware` |
| Egress policy construction | `scripts/deploy-sandbox-vnet.py` — `EgressPolicy` |
| Allowed hosts | `infrastructure/terraform-vnet/locals.tf` — `customer_craigslist_hosts` |
| Dual-Toolbox composition and approval modes | `src/agent/main.py` |
| Playwright allowlist derivation | `scripts/configure-playwright-workspace-mcp.py` — `SAFE_TOOLS`, `select_allowed_tools` |
| Live approval and rejection gates | `scripts/test-vnet-agent.ps1` |
| Runtime call-flow diagram | `docs/images/tenant-aware-mcp-call-flow-3.svg` |
