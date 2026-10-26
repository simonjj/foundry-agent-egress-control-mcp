# End-to-End Deployment Confirmation

Use this procedure to confirm the deployed Financial Services Customer Scenario reference agent,
including the Hosted Agent, APIM path, ACA Sandbox code interpreter, Bing-backed
web search, Azure Playwright Workspace, observability, and Terraform state.

Do not destroy or recreate either ACA Sandbox during confirmation.

## 1. Select the deployment

Open PowerShell:

```powershell
$root = (Resolve-Path ".").Path
az account set --subscription "30501c6c-81f6-41ac-a388-d29cf43a020d"
azd env select state-street-day3 --cwd $root --no-prompt

az account show `
  --query "{subscription:name,id:id,tenant:tenantId}" `
  --output table
```

Expected subscription:

```text
Private Test Sub ACAPMS
30501c6c-81f6-41ac-a388-d29cf43a020d
```

## 2. Run the deployed acceptance tests

```powershell
pwsh .\scripts\smoke-test.ps1
pwsh .\scripts\test-agent-streaming.ps1
pwsh .\scripts\test-agent-tools.ps1
```

Expected output:

```text
Streaming agent smoke test passed.
ACA Sandbox code interpreter tool check passed.
Bing-backed web search tool check passed.
Playwright browser automation tool check passed.
```

If Azure returns a `gpt-5.4-mini` rate-limit error, wait approximately
90 seconds and rerun the failed script.

## 3. Test the Hosted Agent in Microsoft Foundry

1. Open `https://ai.azure.com`.
2. Select the `ss-day3-project` project.
3. Switch to **New Foundry**.
4. Open **Build > Agents > craigslist-agent**.
5. Confirm version **4** is selected and the agent is running.
6. Confirm **Agent info > Kind** is `hosted`.
7. Select **Playground > New chat**.
8. Submit:

```text
Complete all three steps:

1. Use web search to find the official Microsoft Foundry documentation homepage and report its URL.
2. Use browser automation to open https://example.com and report its page title.
3. Use run_python to calculate 17 * 23.

After completing all three steps, include the exact marker ALL_TOOLS_OK.
```

The response must include:

| Check | Expected result |
|---|---|
| Hosted Agent | `ALL_TOOLS_OK` |
| ACA Sandbox Python | `391` |
| Azure Playwright Workspace | `Example Domain` |
| Bing-backed web search | An official Microsoft Foundry URL |

## 4. Inspect the execution trace

Open **Traces** for the playground response. Confirm that the execution includes:

```text
run_python
web_search
browser_automation_preview
```

The execution must not contain:

```text
Object of type BrowserAutomationToolParameters is not JSON serializable
response.failed
401 Unauthorized
403 Forbidden
```

## 5. Confirm the Playwright connection

In Microsoft Foundry:

1. Open **Management center**.
2. Under the project, select **Connected resources**.
3. Open `playwright-automation`.

Expected properties:

| Property | Expected value |
|---|---|
| Type | `PlaywrightWorkspace` |
| Authentication | `Project managed identity` |
| Access | `ss-day3-project only` |

In Azure Portal, open the `ss-day3-pw-bhcvln` Playwright Workspace and select
**Access control (IAM) > Role assignments**. Confirm that the
`ss-day3-ai-bhcvln/ss-day3-project` managed identity has the
`Playwright Workspace Contributor` role.

Do not use direct Azure CLI Playwright-audience token acquisition as an
acceptance test. The deployed path uses the Foundry project managed identity.

## 6. Confirm APIM routing

In Azure Portal:

1. Open `ss-day3-apim-bhcvln`.
2. Select **APIs > Foundry Responses API**.
3. Confirm the `POST /openai/v1/responses` operation exists.
4. Confirm the API requires a subscription.
5. Inspect the policy and confirm request limits, LLM token limits, and
   managed-identity authentication to Foundry are configured.
6. Open **Metrics** with a recent 30-minute window.
7. Submit another Foundry playground request.
8. Confirm APIM records a successful request.

Do not reveal the APIM subscription key during inspection or screen sharing.

## 7. Confirm observability

Generate fresh traffic:

```powershell
pwsh .\scripts\invoke.ps1 `
  "Use run_python to calculate 31 * 7 and include OBSERVABILITY_CHECK."
```

Allow several minutes for ingestion, then run:

```powershell
pwsh .\scripts\query-observability.ps1 -LookbackMinutes 30
```

Expected non-empty sections:

```text
Token usage
Model and tool operations
Captured prompt/response/tool event types
```

An optional A365 OpenAI Agents instrumentation warning may appear in the Hosted
Agent log stream. It is non-blocking only when the Application Insights queries
above contain the expected Agent Framework telemetry.

## 8. Confirm Terraform has zero drift

```powershell
$tf = (Get-Command terraform).Source

& $tf -chdir=".\infrastructure\terraform" plan `
  -detailed-exitcode `
  -var="subscription_id=30501c6c-81f6-41ac-a388-d29cf43a020d" `
  -var="resource_group_name=ss-agent-day3" `
  -var="location=centralus" `
  -var="playwright_location=westus3"

"Terraform exit code: $LASTEXITCODE"
```

Expected result:

```text
No changes. Your infrastructure matches the configuration.
Terraform exit code: 0
```

Exit code `2` means Terraform detected a proposed change. Review the plan before
applying anything.

## 9. Confirm the fallback is preserved but inactive

```powershell
& $tf -chdir=".\infrastructure\terraform" output -raw BROWSER_SANDBOX_ID
& $tf -chdir=".\infrastructure\terraform" output -raw PLAYWRIGHT_MCP_SERVER_URL
```

Both commands should return values, proving that the ACA Playwright MCP fallback
still exists. The active Hosted Agent must use `PLAYWRIGHT_CONNECTION_ID` and
must not receive `PLAYWRIGHT_MCP_SERVER_URL` or
`PLAYWRIGHT_MCP_AUTH_TOKEN`.

## Sign-off criteria

The deployment passes end-to-end confirmation when:

- all deployed scripts pass;
- Hosted Agent version 4 is running;
- the combined request returns `ALL_TOOLS_OK`, `391`, and `Example Domain`;
- the trace contains Python, web-search, and browser-automation tool calls;
- APIM records the request;
- Application Insights contains model and tool telemetry;
- the Playwright connection uses project managed identity;
- Terraform reports no changes; and
- the ACA Playwright fallback remains deployed but inactive.
