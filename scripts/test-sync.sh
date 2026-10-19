#!/usr/bin/env bash
# 所有写入限定在临时目录；不修改 HOME 或真实的 Codex 安装。
set -euo pipefail
ROOT_DIR="$(cd -- "$(dirname -- "$0")/.." && pwd -P)"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/skills-sync-test.XXXXXX")" || exit 1
trap 'rm -rf -- "${scratch:?}"' EXIT
repo="${scratch}/source repo"
target="${scratch}/installed"
codex="${scratch}/codex"
mkdir -p "${repo}/alpha/references" "${repo}/beta" "${codex}/skills/alpha"
cp "${ROOT_DIR}/sync.sh" "${repo}/sync.sh"
printf '%s\n' '---' 'name: alpha' 'description: Fixture alpha' '---' > "${repo}/alpha/SKILL.md"
printf '%s\n' '---' 'name: beta' 'description: Fixture beta' '---' > "${repo}/beta/SKILL.md"
printf 'first\n' > "${repo}/alpha/references/example.md"
printf 'old legacy\n' > "${codex}/skills/alpha/SKILL.md"
run_sync() { CODEX_HOME="${codex}" TARGETS="${target}" /bin/bash "${repo}/sync.sh" "$@"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
expect_failure() {
    if run_sync "$@" > "${scratch}/failure.log" 2>&1; then
        fail "应拒绝参数：$*"
    fi
}

run_sync > "${scratch}/sync.log"
cmp "${repo}/alpha/references/example.md" "${target}/alpha/references/example.md"
cmp "${repo}/beta/SKILL.md" "${target}/beta/SKILL.md"
[ -f "${codex}/skills/alpha/SKILL.md" ] || fail '自定义目标不得迁移旧全局副本'
printf 'PASS: 自动创建目标、全量安装、参考文件及自定义目标隔离\n'

mkdir -p "${target}/third-party" "${target}/.system"
printf 'keep\n' > "${target}/third-party/SKILL.md"
printf 'keep system\n' > "${target}/.system/sentinel"
printf 'stale\n' > "${target}/alpha/deleted.md"
printf 'other beta\n' > "${target}/beta/SKILL.md"
# 内容同大小且时间戳相同，仍必须发现变化。
printf 'later\n' > "${repo}/alpha/references/example.md"
touch -r "${target}/alpha/references/example.md" "${repo}/alpha/references/example.md"
run_sync alpha > "${scratch}/sync.log"
cmp "${repo}/alpha/references/example.md" "${target}/alpha/references/example.md"
[ ! -e "${target}/alpha/deleted.md" ] || fail '未删除已移除的托管文件'
[ "$(cat "${target}/beta/SKILL.md")" = 'other beta' ] || fail '选择同步修改了未选中的 skill'
[ "$(cat "${target}/third-party/SKILL.md")" = keep ] || fail '第三方 skill 被修改'
[ -f "${target}/.system/sentinel" ] || fail '系统 skill 被修改'
backup_file="$(find "${codex}/skill-sync-backups" -name deleted.md -type f -print)"
[ -n "${backup_file}" ] && [ "$(cat "${backup_file}")" = stale ] || fail '旧文件未备份'
printf 'PASS: 校验内容、镜像删除、旧内容备份、选择同步及第三方保护\n'

printf 'must stay\n' > "${target}/alpha/SKILL.md"
expect_failure alpha missing
[ "$(cat "${target}/alpha/SKILL.md")" = 'must stay' ] || fail '参数检查前已开始部分同步'
expect_failure ../alpha
[ "$(cat "${target}/beta/SKILL.md")" = 'other beta' ] || fail '非法参数发生部分同步'
if CODEX_HOME="${codex}" TARGETS="${repo}" /bin/bash "${repo}/sync.sh" alpha > "${scratch}/failure.log" 2>&1; then
    fail '允许向源仓库同步'
fi
if CODEX_HOME="${codex}" TARGETS="${codex}/skills" /bin/bash "${repo}/sync.sh" alpha > "${scratch}/failure.log" 2>&1; then
    fail '允许向旧 Codex 目录同步'
fi
printf 'PASS: 非法名称、缺失 skill、源目录重叠及旧目录保护\n'

external="${scratch}/external"
mkdir -p "${external}"
printf 'external\n' > "${external}/sentinel"
mv "${target}/alpha" "${scratch}/previous-alpha"
ln -s "${external}" "${target}/alpha"
run_sync alpha > "${scratch}/sync.log"
[ ! -L "${target}/alpha" ] || fail '未替换目标旧链接'
[ "$(cat "${external}/sentinel")" = external ] || fail '修改了链接指向的外部目录'
cmp "${repo}/alpha/SKILL.md" "${target}/alpha/SKILL.md"
[ -n "$(find "${codex}/skill-sync-backups" -name alpha -type l -print)" ] || fail '旧链接未备份'
printf 'PASS: 旧链接归档且不修改链接目标\n'
printf '全部同步回归场景通过。\n'
