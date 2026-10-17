[CmdletBinding()]
param(
    [switch]$Strict
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$errors = [System.Collections.Generic.List[string]]::new()
$warnings = [System.Collections.Generic.List[string]]::new()
$skillDescriptions = @{}

function Add-Error([string]$message) {
    $script:errors.Add($message)
}

function Add-Warning([string]$message) {
    $script:warnings.Add($message)
}

function Read-Frontmatter([string[]]$lines, [string]$path) {
    if ($lines.Count -lt 3 -or $lines[0].Trim() -ne '---') {
        Add-Error "${path}: missing opening frontmatter delimiter"
        return $null
    }

    $close = -1
    for ($i = 1; $i -lt $lines.Count; $i++) {
        if ($lines[$i].Trim() -eq '---') {
            $close = $i
            break
        }
    }
    if ($close -lt 0) {
        Add-Error "${path}: missing closing frontmatter delimiter"
        return $null
    }

    return @{
        Text = ($lines[1..($close - 1)] -join "`n")
        End = $close
    }
}

function Read-Field([string]$frontmatter, [string]$field) {
    $match = [regex]::Match($frontmatter, "(?m)^${field}:\s*(.+)$")
    if (-not $match.Success) {
        return ''
    }
    return $match.Groups[1].Value.Trim().Trim('"').Trim("'")
}

$skillDirs = @(Get-ChildItem -LiteralPath $root -Directory | Where-Object {
    Test-Path -LiteralPath (Join-Path $_.FullName 'SKILL.md')
})
$skillNames = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)

foreach ($dir in $skillDirs) {
    $relative = $dir.FullName.Substring($root.Length + 1)
    $skillNames.Add($dir.Name) | Out-Null
    $skillPath = Join-Path $dir.FullName 'SKILL.md'
    $lines = @(Get-Content -LiteralPath $skillPath)
    $front = Read-Frontmatter $lines $relative
    if ($null -eq $front) {
        continue
    }

    $name = Read-Field $front.Text 'name'
    $description = Read-Field $front.Text 'description'
    if ([string]::IsNullOrWhiteSpace($name)) {
        Add-Error "${relative}: missing name"
    } elseif ($name -cne $dir.Name) {
        Add-Error "${relative}: name '$name' does not match directory '$($dir.Name)'"
    }
    if ([string]::IsNullOrWhiteSpace($description)) {
        Add-Error "${relative}: missing description"
    } elseif ($description.Length -gt 150) {
        Add-Error "${relative}: description is $($description.Length) characters; limit is 150"
    }
    $skillDescriptions[$dir.Name] = $description
    if ($lines.Count -gt 400) {
        Add-Error "${relative}: $($lines.Count) lines exceeds the 400-line repository limit"
    } elseif ($lines.Count -gt 250 -and -not (Test-Path -LiteralPath (Join-Path $dir.FullName 'references'))) {
        Add-Warning "${relative}: $($lines.Count) lines and no references/; split only if it reduces actual loading"
    }

    $body = $lines -join "`n"
    $refs = [regex]::Matches($body, '(?<![A-Za-z0-9/])((?:references|scripts|templates|agents)/[A-Za-z0-9_.-]+(?:/[A-Za-z0-9_.-]+)*)')
    foreach ($ref in ($refs | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)) {
        $refPath = Join-Path $dir.FullName $ref
        if (-not (Test-Path -LiteralPath $refPath)) {
            Add-Error "${relative}: referenced path '$ref' does not exist"
        }
    }
}

$catalogPath = Join-Path $root 'catalog.yaml'
if (-not (Test-Path -LiteralPath $catalogPath)) {
    Add-Error 'catalog.yaml is missing'
} else {
    $catalogNames = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $catalogEntries = @{}
    $currentCatalogName = $null
    foreach ($line in @(Get-Content -LiteralPath $catalogPath)) {
        $match = [regex]::Match($line, '^\s{2}- name:\s*([^\s#]+)\s*$')
        if ($match.Success) {
            $catalogName = $match.Groups[1].Value
            if (-not $catalogNames.Add($catalogName)) {
                Add-Error "catalog.yaml: duplicate skill '$catalogName'"
            }
            $catalogEntries[$catalogName] = @{}
            $currentCatalogName = $catalogName
        } elseif ($null -ne $currentCatalogName) {
            $descriptionMatch = [regex]::Match($line, '^\s{4}description:\s*(.+)$')
            if ($descriptionMatch.Success) {
                $catalogEntries[$currentCatalogName].Description = $descriptionMatch.Groups[1].Value.Trim().Trim('"').Trim("'")
            }
        }
    }
    foreach ($name in $skillNames) {
        if (-not $catalogNames.Contains($name)) {
            Add-Error "catalog.yaml: missing skill '$name'"
        } elseif (-not $catalogEntries[$name].ContainsKey('Description')) {
            Add-Error "catalog.yaml: skill '$name' is missing description"
        } elseif ($catalogEntries[$name].Description -cne $skillDescriptions[$name]) {
            Add-Error "catalog.yaml: description for '$name' does not match SKILL.md"
        }
    }
    foreach ($name in $catalogNames) {
        if (-not $skillNames.Contains($name)) {
            Add-Error "catalog.yaml: unknown skill '$name'"
        }
    }
}

foreach ($warning in $warnings) {
    Write-Host "WARN $warning" -ForegroundColor Yellow
}
foreach ($error in $errors) {
    Write-Host "ERROR $error" -ForegroundColor Red
}

Write-Host "Checked $($skillDirs.Count) skills: $($errors.Count) errors, $($warnings.Count) warnings."
if ($errors.Count -gt 0 -or ($Strict -and $warnings.Count -gt 0)) {
    exit 1
}
exit 0
