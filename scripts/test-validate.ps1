[CmdletBinding()]
param(
    [ValidateSet('Valid', 'MissingName', 'MissingDescription', 'MissingReference', 'CatalogDrift')]
    [string]$Probe
)

$ErrorActionPreference = 'Stop'
$validator = Join-Path $PSScriptRoot 'validate.ps1'

if ($Probe) {
    # Inject invalid input at the read boundary; never alter a skill, catalog, or checkout on disk.
    $global:validationProbeCase = $Probe
    $global:validationProbeSkill = [IO.Path]::GetFullPath((Join-Path (Split-Path $PSScriptRoot -Parent) 'code-simplifier/SKILL.md'))
    function Get-Content {
        param([string]$LiteralPath)
        $lines = @(Microsoft.PowerShell.Management\Get-Content -LiteralPath $LiteralPath)
        if ([IO.Path]::GetFullPath($LiteralPath) -eq $global:validationProbeSkill) {
            switch ($global:validationProbeCase) {
                'MissingName' { return @($lines | Where-Object { $_ -notmatch '^name:' }) }
                'MissingDescription' { return @($lines | Where-Object { $_ -notmatch '^description:' }) }
                'MissingReference' { return $lines + 'references/__validation_missing__.md' }
            }
        }
        if ($global:validationProbeCase -eq 'CatalogDrift' -and (Split-Path $LiteralPath -Leaf) -eq 'catalog.yaml') {
            $changed = $false
            return @($lines | ForEach-Object {
                if (-not $changed -and $_ -match '^    description:') {
                    $changed = $true
                    '    description: "synthetic catalog mismatch"'
                } else { $_ }
            })
        }
        return $lines
    }
    # Reproduce shells which protect automatic variables (including the current Codex shell).
    if (-not ((Get-Variable Error).Options -band [System.Management.Automation.ScopedItemOptions]::ReadOnly) -and
        -not ((Get-Variable Error).Options -band [System.Management.Automation.ScopedItemOptions]::Constant)) {
        Set-Variable -Name Error -Option ReadOnly
    }
    . $validator
    exit $LASTEXITCODE
}

$pwsh = (Get-Command pwsh -ErrorAction Stop).Source
$cases = @(
    @{ Name = 'Valid'; Exit = 0; Pattern = '0 errors' },
    @{ Name = 'MissingName'; Exit = 1; Pattern = 'code-simplifier: missing name' },
    @{ Name = 'MissingDescription'; Exit = 1; Pattern = 'code-simplifier: missing description' },
    @{ Name = 'MissingReference'; Exit = 1; Pattern = "referenced path 'references/__validation_missing__.md' does not exist" },
    @{ Name = 'CatalogDrift'; Exit = 1; Pattern = 'does not match SKILL.md' }
)
$failures = 0
foreach ($case in $cases) {
    $output = (& $pwsh -NoProfile -File $PSCommandPath -Probe $case.Name 2>&1 | Out-String)
    $resultCode = $LASTEXITCODE
    if ($resultCode -ne $case.Exit -or -not $output.Contains($case.Pattern) -or
        $output.Contains('Cannot overwrite variable Error')) {
        $failures++
        Write-Host "FAIL $($case.Name) (exit $resultCode): $output"
    } else { Write-Host "PASS $($case.Name)" }
}
Write-Host "$($cases.Count) validator cases; $failures failures."
if ($failures -gt 0) { exit 1 }
