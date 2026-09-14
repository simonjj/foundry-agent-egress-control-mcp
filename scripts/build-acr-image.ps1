[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Registry,
    [Parameter(Mandatory)]
    [ValidateSet("interpreter", "gateway")]
    [string]$Component,
    [Parameter(Mandatory)][string]$ImageTag
)

$ErrorActionPreference = "Stop"
$PSNativeCommandUseErrorActionPreference = $true
$env:PYTHONUTF8 = "1"
$env:PYTHONIOENCODING = "utf-8"
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()

$root = Split-Path $PSScriptRoot -Parent
$buildRoot = Join-Path $root "infrastructure\terraform-vnet\.terraform\build"
$staging = Join-Path $buildRoot "$Component-$ImageTag"
if (-not $staging.StartsWith($buildRoot, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Resolved staging path is outside the Terraform build directory."
}

$profiles = @{
    interpreter = @{
        Repository = "python-interpreter"
        Source     = Join-Path $root "src\interpreter"
        Files      = @("Dockerfile", "requirements.txt", "server.py", "executor.py")
    }
    gateway     = @{
        Repository = "foundry-gateway"
        Source     = Join-Path $root "src\gateway"
        Files      = @("Dockerfile", "default.conf.template")
    }
}
$profile = $profiles[$Component]

if (Test-Path -LiteralPath $staging) {
    Remove-Item -LiteralPath $staging -Recurse -Force
}
New-Item -ItemType Directory -Path $staging -Force | Out-Null

try {
    foreach ($file in $profile.Files) {
        Copy-Item `
            -LiteralPath (Join-Path $profile.Source $file) `
            -Destination (Join-Path $staging $file)
    }

    az acr build `
        --registry $Registry `
        --image "$($profile.Repository):$ImageTag" `
        --file (Join-Path $staging "Dockerfile") `
        $staging `
        --no-logs `
        --output none
    if ($LASTEXITCODE -ne 0) {
        throw "ACR build failed for $Component image $ImageTag."
    }
}
finally {
    if (Test-Path -LiteralPath $staging) {
        Remove-Item -LiteralPath $staging -Recurse -Force
    }
}
