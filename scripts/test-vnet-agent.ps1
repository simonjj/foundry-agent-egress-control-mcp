[CmdletBinding()]
param(
    [ValidatePattern('^[A-Za-z0-9._-]+$')]
    [string]$DeploymentProfile = "vnet",

    [ValidatePattern('^[A-Z][A-Z0-9_]+$')]
    [string]$AgentResponsesEnvironmentVariable =
        "AGENT_CRAIGSLIST_AGENT_VNET_RESPONSES_ENDPOINT"
)

$ErrorActionPreference = "Stop"
$PSNativeCommandUseErrorActionPreference = $true

$root = Split-Path $PSScriptRoot -Parent
$deploymentsRoot = Join-Path $root "deployments"
$deploymentDirectory = Join-Path $deploymentsRoot $DeploymentProfile
if (-not $deploymentDirectory.StartsWith(
        $deploymentsRoot,
        [StringComparison]::OrdinalIgnoreCase
    )) {
    throw "Deployment profile must resolve under the deployments directory."
}

$values = @{}
azd env get-values --cwd $deploymentDirectory | ForEach-Object {
    if ($_ -match '^([^=]+)="(.*)"$') {
        $values[$matches[1]] = $matches[2]
    }
}
$endpoint = $values[$AgentResponsesEnvironmentVariable].Trim()
if (-not $endpoint) {
    throw (
        "Hosted-agent Responses endpoint environment variable " +
        "'$AgentResponsesEnvironmentVariable' is not configured."
    )
}

$accessToken = az account get-access-token `
    --scope "https://ai.azure.com/.default" `
    --query accessToken `
    --output tsv
$accessToken = ($accessToken -join "").Trim()

function Invoke-AgentResponse {
    param(
        [Parameter(Mandatory)]$Body
    )

    Invoke-RestMethod `
        -Method Post `
        -Uri $endpoint `
        -Headers @{
            Authorization = ("Bear" + "er " + $accessToken)
            "x-ms-client-request-id" = [guid]::NewGuid().ToString()
        } `
        -ContentType "application/json" `
        -Body ($Body | ConvertTo-Json -Depth 12) `
        -TimeoutSec 600
}

function Get-MessageText {
    param([Parameter(Mandatory)]$Response)

    return @(
        $Response.output |
            Where-Object type -eq "message" |
            ForEach-Object { $_.content.text }
    ) -join [Environment]::NewLine
}

function Get-ApprovalRequest {
    param([Parameter(Mandatory)]$Response)

    return @(
        $Response.output |
            Where-Object type -eq "mcp_approval_request"
    ) | Select-Object -Last 1
}

function Get-RequestedConfirmation {
    param(
        [Parameter(Mandatory)]$Response,
        [Parameter(Mandatory)][string]$Fallback
    )

    $text = Get-MessageText -Response $Response
    foreach ($pattern in @(
            '(?im)Reply (?:exactly )?with\s+"([^"]+)"',
            '(?im)Reply exactly:\s*([^\r\n]+)',
            '(?im)Please approve exactly:\s*([^\r\n]+)'
        )) {
        $match = [regex]::Match($text, $pattern)
        if ($match.Success) {
            return $match.Groups[1].Value.Trim(' ', '"', "'", '.')
        }
    }
    return $Fallback
}

function Advance-ToApproval {
    param(
        [Parameter(Mandatory)]$Response,
        [Parameter(Mandatory)][string]$Confirmation
    )

    $approval = Get-ApprovalRequest -Response $Response
    if ($approval) {
        return @{
            response = $Response
            approval = $approval
        }
    }

    $requestedConfirmation = Get-RequestedConfirmation `
        -Response $Response `
        -Fallback $Confirmation
    $continued = Invoke-AgentResponse -Body @{
        previous_response_id = $Response.id
        input                = $requestedConfirmation
        stream               = $false
    }
    $approval = Get-ApprovalRequest -Response $continued
    if (-not $approval) {
        throw "No runtime approval request followed '$requestedConfirmation'."
    }
    return @{
        response = $continued
        approval = $approval
    }
}

function Submit-Approval {
    param(
        [Parameter(Mandatory)]$Response,
        [Parameter(Mandatory)]$Approval,
        [Parameter(Mandatory)][bool]$Approve
    )

    return Invoke-AgentResponse -Body @{
        previous_response_id = $Response.id
        input = @(
            @{
                type                = "mcp_approval_response"
                approval_request_id = $Approval.id
                approve             = $Approve
                reason              = if ($Approve) {
                    "Approved exact acceptance-test call."
                }
                else {
                    "Rejected by the acceptance-test negative gate."
                }
            }
        )
        stream = $false
    }
}

$broker = Invoke-AgentResponse -Body @{
    input = (
        "Run the retained tenant broker validation now: call customer_context " +
        "and report the customer id; call run_python to calculate 17 * 23; " +
        "call search_craigslist for bicycles in Seattle and report one listing " +
        "URL. End with BROKER_RETAINED_E2E_OK only if all three calls succeed."
    )
    stream = $false
}
$brokerText = Get-MessageText -Response $broker
foreach ($pattern in @(
        "customer-personal",
        "391",
        "craigslist",
        "BROKER_RETAINED_E2E_OK"
    )) {
    if ($brokerText -notmatch $pattern) {
        throw "Retained broker test did not contain '$pattern'."
    }
}
Write-Host "Retained tenant broker tools passed."

$rejectionStart = Invoke-AgentResponse -Body @{
    input = (
        "Use Playwright to open https://www.craigslist.org/about/sites and " +
        "report the title. Require runtime approval before every browser call."
    )
    stream = $false
}
$rejectionGate = Advance-ToApproval `
    -Response $rejectionStart `
    -Confirmation "Approve create_browser_session"
if ($rejectionGate.approval.name -ne "playwright___create_browser_session") {
    throw "Rejection gate did not request create_browser_session approval."
}
$rejected = Submit-Approval `
    -Response $rejectionGate.response `
    -Approval $rejectionGate.approval `
    -Approve $false
if (@($rejected.output | Where-Object type -eq "mcp_call").Count -ne 0) {
    throw "Rejected Playwright call produced an mcp_call."
}
if ($rejected.status -ne "completed") {
    throw "Rejected Playwright transaction did not complete cleanly."
}
Write-Host "Playwright rejection gate passed."

$success = Invoke-AgentResponse -Body @{
    input = (
        "Use Playwright to create a new browser session, navigate to " +
        "https://www.craigslist.org/about/sites, report the page title, close " +
        "the browser session, and end with PWW_MCP_E2E_OK. Require a separate " +
        "runtime approval for every browser call."
    )
    stream = $false
}
$allowedApprovals = @(
    "playwright___create_browser_session",
    "playwright___browser_navigate",
    "playwright___browser_snapshot",
    "playwright___close_browser_session"
)
$observedApprovals = [Collections.Generic.HashSet[string]]::new(
    [StringComparer]::Ordinal
)
$initialSuccessGate = Advance-ToApproval `
    -Response $success `
    -Confirmation "Approve create_browser_session"
$success = $initialSuccessGate.response

for ($step = 0; $step -lt 12; $step++) {
    $approval = Get-ApprovalRequest -Response $success
    if (-not $approval) {
        $confirmation = Get-RequestedConfirmation `
            -Response $success `
            -Fallback ""
        if (-not $confirmation) {
            break
        }
        $success = Invoke-AgentResponse -Body @{
            previous_response_id = $success.id
            input                = $confirmation
            stream               = $false
        }
        $approval = Get-ApprovalRequest -Response $success
        if (-not $approval) {
            throw "No runtime approval followed the requested confirmation."
        }
    }

    if ($allowedApprovals -notcontains $approval.name) {
        throw "Unexpected Playwright approval '$($approval.name)'."
    }
    [void]$observedApprovals.Add($approval.name)
    $closing = $approval.name -eq "playwright___close_browser_session"
    $success = Submit-Approval `
        -Response $success `
        -Approval $approval `
        -Approve $true
    if ($closing) {
        break
    }
}

foreach ($requiredApproval in @(
        "playwright___create_browser_session",
        "playwright___browser_navigate",
        "playwright___close_browser_session"
    )) {
    if (-not $observedApprovals.Contains($requiredApproval)) {
        throw "Playwright success gate did not observe '$requiredApproval'."
    }
}

$successText = Get-MessageText -Response $success
foreach ($pattern in @("craigslist > sites", "PWW_MCP_E2E_OK")) {
    if ($successText -notmatch [regex]::Escape($pattern)) {
        throw "Playwright success gate did not contain '$pattern'."
    }
}
if (Get-ApprovalRequest -Response $success) {
    throw "Playwright success gate ended with an unresolved approval."
}
Write-Host "PWW_MCP_E2E_OK"
