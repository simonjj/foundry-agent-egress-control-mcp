$ErrorActionPreference = "Stop"
$PSNativeCommandUseErrorActionPreference = $true

$query = [Console]::In.ReadToEnd() | ConvertFrom-Json
az account set --subscription $query.subscription_id

$sandboxOutput = @(aca sandbox list `
        --group $query.sandbox_group_name `
        --resource-group $query.resource_group `
        --subscription $query.subscription_id `
        --region $query.location `
        --output json 2>&1)
if ($LASTEXITCODE -ne 0) {
    throw "Unable to list Sandboxes: $($sandboxOutput -join [Environment]::NewLine)"
}
$sandboxText = $sandboxOutput -join [Environment]::NewLine
$jsonStart = $sandboxText.IndexOf("[")
if ($jsonStart -lt 0) {
    throw "Sandbox list output did not contain JSON."
}
$sandboxes = $sandboxText.Substring($jsonStart) | ConvertFrom-Json

$sandbox = $sandboxes | Where-Object {
    $_.labels.application -eq "state-street-day3" -and
    $_.labels.component -eq $query.component -and
    $_.labels.version -eq $query.image_tag -and
    $_.labels.token_fingerprint -eq $query.token_fingerprint -and
    $_.labels.config_fingerprint -eq $query.config_fingerprint
} | Select-Object -First 1

if (-not $sandbox -and $query.config_fingerprint -eq $query.legacy_config_fingerprint) {
    $sandbox = $sandboxes | Where-Object {
        $_.labels.application -eq "state-street-day3" -and
        $_.labels.component -eq $query.component -and
        $_.labels.version -eq $query.image_tag -and
        $_.labels.token_fingerprint -eq $query.token_fingerprint -and
        -not $_.labels.config_fingerprint
    } | Select-Object -First 1
}

if (-not $sandbox) {
    throw "No State Street $($query.component) Sandbox exists for image $($query.image_tag) and configuration $($query.config_fingerprint)."
}

if (-not $sandbox.ports) {
    $sandbox = aca sandbox get `
        --id $sandbox.id `
        --group $query.sandbox_group_name `
        --resource-group $query.resource_group `
        --subscription $query.subscription_id `
        --region $query.location `
        --output json | ConvertFrom-Json
}

$port = @($sandbox.ports) |
    Where-Object { [int]$_.port -eq 8080 } |
    Select-Object -First 1
$portUrl = $port.url
if (-not $portUrl) {
    throw "Sandbox $($sandbox.id) does not expose the required port 8080 endpoint."
}
if (-not $portUrl.StartsWith("http")) {
    $portUrl = "https://$portUrl"
}

[ordered]@{
    sandbox_id = [string]$sandbox.id
    mcp_url    = "$($portUrl.TrimEnd('/'))/mcp"
    health_url = "$($portUrl.TrimEnd('/'))/health"
} | ConvertTo-Json -Compress
