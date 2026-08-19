[CmdletBinding()]
param(
    [switch]$Regenerate
)

$ErrorActionPreference = "Stop"
$PSNativeCommandUseErrorActionPreference = $true

$root = Split-Path $PSScriptRoot -Parent
$configPath = Join-Path $root "evaluation\eval.yaml"
$datasetPath = Join-Path $root "evaluation\test-cases.jsonl"

if ($Regenerate -or -not (Test-Path $configPath)) {
    azd ai agent eval generate `
        --cwd $root `
        --agent craigslist-agent `
        --dataset $datasetPath `
        --eval-model gpt-5.4-mini `
        --evaluator builtin.task_adherence `
        --evaluator builtin.coherence `
        --evaluator builtin.violence `
        --name craigslist-agent-quality `
        --out-file $configPath `
        --reset-defaults `
        --no-prompt
}

azd ai agent eval run `
    --cwd $root `
    --config $configPath `
    --name "craigslist-agent-quality-$(Get-Date -Format 'yyyyMMddHHmmss')" `
    --no-prompt
