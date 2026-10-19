<#
sync.ps1 —— 把本仓库的 skills 同步到 Codex 的唯一用户级来源。
行为与 sync.sh 逐条对齐，镜像用 Windows 自带的 robocopy /MIR，不依赖 rsync 或 Git Bash。

用法:
  .\sync.ps1                同步全部 skill 到 ~/.agents/skills
  .\sync.ps1 go-review      只同步指定的
  .\sync.ps1 a b c          同步多个
  $env:TARGETS = 'C:\skills-a;D:\skills-b'; .\sync.ps1   自定义目标（分号分隔）

规则:
  - TARGETS 未设置或留空时只写 ~/.agents/skills；缺失目录自动创建，不再默认写 Claude。
  - CODEX_HOME 未设置或留空时回落 ~/.codex；用于定位旧 skills 和扫描目录外的备份。
  - 本仓库同名 skill 覆盖前整目录备份；其他 skill 和 .system 保持不动。
  - 全部同步并校验成功后，才将旧 $CODEX_HOME/skills 的对应副本移入备份。
  - 自定义 TARGETS 未包含 ~/.agents/skills 时不迁移旧副本；旧 Codex skills 不能作为目标。
  - 备份位于 $CODEX_HOME/skill-sync-backups/<唯一批次>/。
  - .DS_Store 不同步。
  - 首次运行若被执行策略拦住：powershell -ExecutionPolicy Bypass -File .\sync.ps1

一键入口：在 PowerShell profile（$PROFILE）里加
  function skills-sync { & "$HOME\Ai\skills\sync.ps1" @args }
#>
param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Names
)

$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot

$canonical = [IO.Path]::GetFullPath((Join-Path $HOME '.agents/skills'))
$codexDir = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $HOME '.codex' }
if (-not [IO.Path]::IsPathRooted($codexDir)) { throw 'CODEX_HOME 必须是绝对路径' }
$legacy = [IO.Path]::GetFullPath((Join-Path $codexDir 'skills'))
$targets = if ($env:TARGETS) { @($env:TARGETS -split ';' | Where-Object { $_.Trim() }) } else { @($canonical) }
if ($targets.Count -eq 0) { throw 'TARGETS 不能只有分隔符或空格' }
$script:backupDir = $null
function Initialize-Backup {
    if (-not $script:backupDir) {
        $batch = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ') + '.' + [guid]::NewGuid().ToString('N')
        $script:backupDir = Join-Path $codexDir "skill-sync-backups/$batch"
        New-Item -ItemType Directory -Path $script:backupDir -Force | Out-Null
        Write-Output "备份目录：$script:backupDir"
    }
}

if (-not $Names) {
    $Names = Get-ChildItem -Directory |
        Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'SKILL.md') -PathType Leaf } |
        Sort-Object Name |
        ForEach-Object Name
}
if (-not $Names) { throw '仓库中没有 skill' }
foreach ($name in $Names) {
    if ($name -notmatch '^[a-z0-9]+(-[a-z0-9]+)*$') { throw "非法 skill 名称：$name" }
    if (-not (Test-Path -LiteralPath (Join-Path $PSScriptRoot "$name/SKILL.md") -PathType Leaf)) {
        throw "${name}：不含 SKILL.md"
    }
}
Get-Command robocopy -ErrorAction Stop | Out-Null

$canonicalSynced = $false
$index = 0
foreach ($target in $targets) {
    if (-not [IO.Path]::IsPathRooted($target)) { throw "同步目标必须是绝对路径：$target" }
    $target = [IO.Path]::GetFullPath($target).TrimEnd('\', '/')
    $sourceRoot = $PSScriptRoot.TrimEnd('\', '/')
    $separator = [IO.Path]::DirectorySeparatorChar
    if (-not $target -or $target -eq $sourceRoot -or $target -eq [IO.Path]::GetPathRoot($target).TrimEnd('\', '/') -or
        $sourceRoot.StartsWith($target + $separator, [StringComparison]::OrdinalIgnoreCase) -or
        $target.StartsWith($sourceRoot + $separator, [StringComparison]::OrdinalIgnoreCase)) {
        throw "目标不能与源码目录重叠：$target"
    }
    if ($target -eq $legacy -or $target.StartsWith($legacy + $separator, [StringComparison]::OrdinalIgnoreCase)) {
        throw '请使用 ~/.agents/skills，不能重新写入旧 Codex skills 目录'
    }
    New-Item -ItemType Directory -Path $target -Force | Out-Null
    if ((Get-Item -LiteralPath $target).Attributes -band [IO.FileAttributes]::ReparsePoint) {
        throw "同步目标不能是目录链接：$target"
    }
    $index++
    $n = 0
    foreach ($name in $Names) {
        $source = Join-Path $PSScriptRoot $name
        $dest = Join-Path $target $name
        $existing = Get-Item -LiteralPath $dest -Force -ErrorAction SilentlyContinue
        if ($existing) {
            Initialize-Backup
            $snapshot = Join-Path $script:backupDir "target-$index"
            New-Item -ItemType Directory -Path $snapshot -Force | Out-Null
            if ($existing.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                Move-Item -LiteralPath $dest -Destination (Join-Path $snapshot $name)
            } else {
                if (-not $existing.PSIsContainer) { throw "目标 skill 不是目录：$dest" }
                Copy-Item -LiteralPath $dest -Destination (Join-Path $snapshot $name) -Recurse -Force
            }
        }
        # /IS /IT 强制复制同大小、同时间文件，避免仅靠时间戳漏掉更新；8 及以上才是失败。
        robocopy $source $dest /MIR /IS /IT /R:1 /W:1 /XF .DS_Store /NFL /NDL /NJH /NJS /NC /NS /NP | Out-Null
        if ($LASTEXITCODE -ge 8) { throw "robocopy 失败（退出码 $LASTEXITCODE）：$name -> $target" }
        robocopy $source $dest /MIR /L /R:0 /W:0 /XF .DS_Store /NFL /NDL /NJH /NJS /NC /NS /NP | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "同步后校验失败（退出码 $LASTEXITCODE）：$name" }
        $n++
    }
    Write-Output "${target}：已同步并校验 ${n} 个"
    if ($target -eq $canonical) { $canonicalSynced = $true }
}

$migrated = 0
if ($canonicalSynced) {
    $legacyRoot = Get-Item -LiteralPath $legacy -Force -ErrorAction SilentlyContinue
    if ($legacyRoot -and ($legacyRoot.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw "旧 skills 根目录是链接，未迁移：$legacy"
    }
    if ($legacy -eq $sourceRoot -or $sourceRoot.StartsWith($legacy + $separator, [StringComparison]::OrdinalIgnoreCase) -or
        $legacy.StartsWith($sourceRoot + $separator, [StringComparison]::OrdinalIgnoreCase)) {
        throw '旧 skills 根目录与源码重叠，未迁移'
    }
    foreach ($name in $Names) {
        $old = Join-Path $legacy $name
        if (Get-Item -LiteralPath $old -Force -ErrorAction SilentlyContinue) {
            Initialize-Backup
            $archive = Join-Path $script:backupDir 'legacy'
            New-Item -ItemType Directory -Path $archive -Force | Out-Null
            Move-Item -LiteralPath $old -Destination (Join-Path $archive $name)
            $migrated++
        }
    }
}
Write-Output "已备份迁移旧 Codex 副本：${migrated} 个。"
Write-Output '若当前 Codex 技能列表仍显示旧路径，请重启 Codex 后开启新会话。'
