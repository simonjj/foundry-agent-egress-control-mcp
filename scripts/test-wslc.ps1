[CmdletBinding()]
param(
    [string]$PipIndexUrl = ""
)

$ErrorActionPreference = "Stop"
$PSNativeCommandUseErrorActionPreference = $true

if (-not (Get-Command wslc -ErrorAction SilentlyContinue)) {
    throw "wslc was not found on PATH."
}

if (-not $PipIndexUrl) {
    $configuredIndex = python -m pip config list 2>$null |
        Where-Object { $_ -match "^global\.index-url=" } |
        Select-Object -First 1
    if ($configuredIndex -match "^global\.index-url='([^']+)'$") {
        $PipIndexUrl = $matches[1]
    }
}
if (-not $PipIndexUrl) {
    $PipIndexUrl = "https://pypi.org/simple"
}

$root = Split-Path $PSScriptRoot -Parent
$containers = @(
    "ss-vnet-interpreter-check",
    "ss-vnet-gateway-check"
)

try {
    wslc build `
        --build-arg "PIP_INDEX_URL=$PipIndexUrl" `
        --tag "ss-vnet-interpreter:test" `
        (Join-Path $root "src\interpreter")
    wslc build `
        --tag "ss-vnet-gateway:test" `
        (Join-Path $root "src\gateway")

    wslc run --detach `
        --name $containers[0] `
        --env "MCP_AUTH_TOKEN=local-test-token" `
        --publish "18080:8080" `
        "ss-vnet-interpreter:test" | Out-Null
    wslc run --detach `
        --name $containers[1] `
        --env "FOUNDRY_BACKEND_HOST=example.com" `
        --env "FOUNDRY_PROJECT_NAME=test" `
        --publish "18082:8080" `
        "ss-vnet-gateway:test" | Out-Null

    foreach ($target in @(
        "http://127.0.0.1:18080/health",
        "http://127.0.0.1:18082/health"
    )) {
        $healthy = $false
        for ($attempt = 0; $attempt -lt 30; $attempt++) {
            try {
                $response = Invoke-RestMethod -Uri $target -TimeoutSec 5
                if ($response.status -eq "ok") {
                    $healthy = $true
                    break
                }
            }
            catch {
                Start-Sleep -Seconds 2
            }
        }
        if (-not $healthy) {
            throw "Container health check failed: $target"
        }
        Write-Host "Passed: $target"
    }

    $unauthorized = Invoke-WebRequest `
        -Uri "http://127.0.0.1:18080/mcp" `
        -Method Get `
        -SkipHttpErrorCheck `
        -TimeoutSec 10
    if ($unauthorized.StatusCode -ne 401) {
        throw "Interpreter MCP endpoint did not reject an unauthenticated request."
    }
    Write-Host "Passed: unauthenticated interpreter MCP request rejected."
}
finally {
    foreach ($container in $containers) {
        wslc remove --force $container 2>$null | Out-Null
    }
}
