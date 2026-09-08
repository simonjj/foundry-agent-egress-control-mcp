[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Registry,
    [Parameter(Mandatory)][string]$ImageTag
)

$ErrorActionPreference = "Stop"
$PSNativeCommandUseErrorActionPreference = $true
$env:PYTHONUTF8 = "1"
$env:PYTHONIOENCODING = "utf-8"

if ($ImageTag -notmatch '^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$') {
    throw "ImageTag must be a valid Docker tag containing at most 128 characters."
}

$root = Split-Path $PSScriptRoot -Parent
$source = Join-Path $root "src\broker"
$buildRoot = [IO.Path]::GetFullPath(
    (Join-Path $root "infrastructure\terraform-tenant\.terraform\build")
)
$buildRootPrefix = $buildRoot.TrimEnd(
    [IO.Path]::DirectorySeparatorChar,
    [IO.Path]::AltDirectorySeparatorChar
) + [IO.Path]::DirectorySeparatorChar
$staging = [IO.Path]::GetFullPath((Join-Path $buildRoot "broker-$ImageTag"))
if (-not $staging.StartsWith(
        $buildRootPrefix,
        [StringComparison]::OrdinalIgnoreCase
    )) {
    throw "Resolved staging path is outside the tenant Terraform build directory."
}

if (Test-Path -LiteralPath $staging) {
    Remove-Item -LiteralPath $staging -Recurse -Force
}
New-Item -ItemType Directory -Path $staging -Force | Out-Null

try {
    foreach ($file in @("Dockerfile", "requirements.txt", "server.py")) {
        Copy-Item `
            -LiteralPath (Join-Path $source $file) `
            -Destination (Join-Path $staging $file)
    }

    az acr build `
        --registry $Registry `
        --image "tenant-mcp-broker:$ImageTag" `
        --file (Join-Path $staging "Dockerfile") `
        $staging `
        --no-logs `
        --output none
    if ($LASTEXITCODE -ne 0) {
        throw "ACR build failed for broker image $ImageTag."
    }
}
finally {
    if (Test-Path -LiteralPath $staging) {
        Remove-Item -LiteralPath $staging -Recurse -Force
    }
}
