<#
sync.ps1 —— 把本仓库的 skill 目录同步到 Windows 原生 Claude Code 与 Codex 的 skills 目录。
行为与 sync.sh 逐条对齐，镜像用 Windows 自带的 robocopy /MIR，不依赖 rsync 或 Git Bash。

用法:
  .\sync.ps1                同步全部 skill 到默认目标（见 $targets）
  .\sync.ps1 go-review      只同步指定的
  .\sync.ps1 a b c          同步多个
  $env:TARGETS = "$HOME\.claude\skills"; .\sync.ps1   自定义目标目录（分号分隔）

规则:
  - 单一来源是本仓库；目标目录里同名 skill 整目录镜像覆盖（/MIR 只作用于该 skill 目录内部）。
  - 目标目录里仓库没有的 skill 原样保留，不动。
  - .DS_Store 不同步。
  - 目标目录不存在时跳过并提示，不自动创建。
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

$targets = if ($env:TARGETS) { $env:TARGETS -split ';' } else { @("$HOME\.claude\skills", "$HOME\.codex\skills") }

if (-not $Names) {
    $Names = Get-ChildItem -Directory |
        Where-Object { Test-Path (Join-Path $_.FullName 'SKILL.md') } |
        Sort-Object Name |
        ForEach-Object Name
}

foreach ($target in $targets) {
    if (-not (Test-Path $target -PathType Container)) {
        Write-Warning "跳过 ${target}：目录不存在"
        continue
    }
    $n = 0
    foreach ($name in $Names) {
        if (-not (Test-Path (Join-Path $name 'SKILL.md'))) {
            Write-Warning "跳过 ${name}：不含 SKILL.md"
            continue
        }
        # 退出码 0–7 都是成功（含"有文件被复制/删除"），8 及以上才是失败
        robocopy $name (Join-Path $target $name) /MIR /XF .DS_Store /NFL /NDL /NJH /NJS /NC /NS /NP | Out-Null
        if ($LASTEXITCODE -ge 8) { throw "robocopy 失败（退出码 $LASTEXITCODE）：$name -> $target" }
        $n++
    }
    Write-Output "${target}：已同步 ${n} 个"
}
