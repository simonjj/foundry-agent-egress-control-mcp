[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
$root = Split-Path $PSScriptRoot -Parent
$values = azd env get-values --cwd $root
foreach ($line in $values) {
    if ($line -match '^([^=]+)="(.*)"$') {
        [Environment]::SetEnvironmentVariable($matches[1], $matches[2], "Process")
    }
}

python (Join-Path $root "scripts\smoke_test.py")
