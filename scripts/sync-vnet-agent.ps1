[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

$root = Split-Path $PSScriptRoot -Parent
$source = Join-Path $root "src\agent"
$generatedRoot = Join-Path $root "deployments\vnet\.azd-src"
$destination = Join-Path $generatedRoot "agent"

if (-not $destination.StartsWith(
        $generatedRoot,
        [StringComparison]::OrdinalIgnoreCase
    )) {
    throw "Generated agent path is outside the VNet deployment directory."
}
if (Test-Path -LiteralPath $destination) {
    Remove-Item -LiteralPath $destination -Recurse -Force
}
New-Item -ItemType Directory -Path $destination -Force | Out-Null

foreach ($file in @(
        ".dockerignore",
        "Dockerfile",
        "main.py",
        "requirements.txt"
    )) {
    Copy-Item `
        -LiteralPath (Join-Path $source $file) `
        -Destination (Join-Path $destination $file)
}

Write-Host "Prepared the VNet hosted-agent deployment context."
