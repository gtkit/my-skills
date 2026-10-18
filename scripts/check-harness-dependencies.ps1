[CmdletBinding()]
param(
    [string]$HarnessRoot = (Join-Path (Split-Path $PSScriptRoot -Parent) '../harness-engineering')
)

$ErrorActionPreference = 'Stop'
$skillsRoot = Split-Path $PSScriptRoot -Parent
$manifest = Join-Path $HarnessRoot 'skills/harness-doctor/references/skill-dependencies.md'
if (-not (Test-Path -LiteralPath $manifest -PathType Leaf)) {
    Write-Host "ERROR dependency manifest not found: $manifest"
    exit 1
}
$dependencies = [System.Collections.Generic.HashSet[string]]::new()
foreach ($line in Get-Content -LiteralPath $manifest) {
    if (-not $line.StartsWith('|')) { continue }
    $cells = $line.Split('|')
    # Column 1 is a harness or task, following columns name its external skills.
    $values = $cells[2..($cells.Count - 2)] -join ' '
    foreach ($match in [regex]::Matches($values, '(?<![A-Za-z0-9-])[a-z][a-z0-9]*(?:-[a-z0-9]+)+(?![A-Za-z0-9-])')) {
        $dependencies.Add($match.Value) | Out-Null
    }
}
if ($dependencies.Count -eq 0) {
    Write-Host 'ERROR manifest contains no technical skill dependencies'
    exit 1
}
$missing = @($dependencies | Where-Object {
    -not (Test-Path -LiteralPath (Join-Path $skillsRoot "$_/SKILL.md") -PathType Leaf)
})
foreach ($name in $missing) { Write-Host "ERROR missing source skill: $name" }
Write-Host "Checked $($dependencies.Count) harness dependencies; $($missing.Count) missing sources."
Write-Host 'Source coverage only: this does not prove installation, runtime discovery, or task execution.'
if ($missing.Count -gt 0) { exit 1 }
