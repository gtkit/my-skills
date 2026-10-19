#!/usr/bin/env bash
# sync.sh —— 把本仓库的 skills 同步到 Codex 的唯一用户级来源。
#
# 用法:
#   ./sync.sh                同步全部 skill 到 ~/.agents/skills
#   ./sync.sh go-review      只同步指定的
#   ./sync.sh a b c          同步多个
#   TARGETS="/tmp/skills-a /tmp/skills-b" ./sync.sh   自定义目标（空格分隔，路径不能含空格）
#
# 规则:
#   - TARGETS 未设置或留空时只写 ~/.agents/skills；缺失目录自动创建，不再默认写 Claude。
#   - CODEX_HOME 未设置或留空时回落 ~/.codex；用于定位旧 skills 和扫描目录外的备份。
#   - 目标中本仓库同名 skill 镜像更新，覆盖前整目录备份；其他 skill 和 .system 保持不动。
#   - 全部同步并校验成功后，才将旧 $CODEX_HOME/skills 的对应副本移入备份。
#   - 自定义 TARGETS 未包含 ~/.agents/skills 时不迁移旧副本；旧 Codex skills 不能作为同步目标。
#   - 备份位于 $CODEX_HOME/skill-sync-backups/<唯一批次>/；.DS_Store 不同步。

set -euo pipefail
ROOT_DIR="$(cd -- "$(dirname -- "$0")" && pwd -P)"
CODEX_DIR="${CODEX_HOME:-${HOME}/.codex}"
CANONICAL_DIR="${HOME}/.agents/skills"
LEGACY_DIR="${CODEX_DIR}/skills"
BACKUP_DIR=""

die() { printf '错误：%s\n' "$*" >&2; exit 1; }
ensure_backup() {
    if [ -z "${BACKUP_DIR}" ]; then
        mkdir -p -- "${CODEX_DIR}/skill-sync-backups"
        backup_root="$(cd -- "${CODEX_DIR}/skill-sync-backups" && pwd -P)"
        [[ "${backup_root}" != "${ROOT_DIR}" && "${backup_root}" != "${ROOT_DIR}"/* &&
           "${backup_root}" != "${CANONICAL_DIR}" && "${backup_root}" != "${CANONICAL_DIR}"/* ]] || die '备份目录不能位于源码或技能扫描目录内'
        BACKUP_DIR="$(mktemp -d "${backup_root}/$(date -u +%Y%m%dT%H%M%SZ).XXXXXX")" || exit 1
        printf '备份目录：%s\n' "${BACKUP_DIR}"
    fi
}

if [ "${1:-}" = --help ]; then
    printf '%s\n' '用法：./sync.sh [skill-name ...]' '默认同步到 ~/.agents/skills，并备份迁移旧 Codex 同名副本。'
    exit 0
fi
command -v rsync >/dev/null 2>&1 || die '需要 rsync'
[[ "${CODEX_DIR}" = /* ]] || die 'CODEX_HOME 必须是绝对路径'
names=("$@")
if [ "${#names[@]}" -eq 0 ]; then
    for manifest in "${ROOT_DIR}"/*/SKILL.md; do
        [ -f "${manifest}" ] || continue
        name="${manifest%/SKILL.md}"
        names+=("${name##*/}")
    done
fi
[ "${#names[@]}" -gt 0 ] || die '仓库中没有 skill'
# 先验证全部参数，避免路径穿越或参数拼错时发生部分同步。
for name in "${names[@]}"; do
    [[ "${name}" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]] || die "非法 skill 名称：${name}"
    [ -f "${ROOT_DIR}/${name}/SKILL.md" ] || die "${name}：不含 SKILL.md"
done

targets=("${CANONICAL_DIR}")
if [ -n "${TARGETS:-}" ]; then
    IFS=' ' read -r -a targets <<< "${TARGETS}"
fi
[ "${#targets[@]}" -gt 0 ] || die 'TARGETS 不能只有空格'
canonical_synced=0
index=0
for target in "${targets[@]}"; do
    [[ "${target}" = /* ]] || die "同步目标必须是绝对路径：${target}"
    mkdir -p -- "${target}"
    target="$(cd -- "${target}" && pwd -P)"
    [[ "${target}" != / && "${target}" != "${ROOT_DIR}" &&
       "${ROOT_DIR}" != "${target}"/* && "${target}" != "${ROOT_DIR}"/* ]] || die "目标不能与源码目录重叠：${target}"
    if [ -d "${LEGACY_DIR}" ]; then
        legacy_root="$(cd -- "${LEGACY_DIR}" && pwd -P)"
        if [[ "${target}" = "${legacy_root}" || "${target}" = "${legacy_root}"/* ]]; then
            die '请使用 ~/.agents/skills，不能重新写入旧 Codex skills 目录'
        fi
    fi
    index=$((index + 1))
    n=0
    for name in "${names[@]}"; do
        dest="${target}/${name}"
        if [ -e "${dest}" ] || [ -L "${dest}" ]; then
            ensure_backup
            mkdir -p -- "${BACKUP_DIR}/target-${index}"
            if [ -L "${dest}" ]; then
                # 只移动链接本身，不能让 rsync --delete 写入链接指向的外部目录。
                mv -- "${dest}" "${BACKUP_DIR}/target-${index}/${name}"
            else
                [ -d "${dest}" ] || die "目标 skill 不是目录：${dest}"
                cp -RP -- "${dest}" "${BACKUP_DIR}/target-${index}/${name}"
            fi
        fi
        rsync -ac --delete --exclude '.DS_Store' "${ROOT_DIR}/${name}/" "${dest}/"
        changes="$(rsync -acni --delete --exclude '.DS_Store' "${ROOT_DIR}/${name}/" "${dest}/")" || die "校验失败：${name}"
        [ -z "${changes}" ] || die "同步后仍有差异：${name}"
        n=$((n + 1))
    done
    printf '%s：已同步并校验 %s 个\n' "${target}" "${n}"
    if [ -d "${CANONICAL_DIR}" ] && [[ "${target}" -ef "${CANONICAL_DIR}" ]]; then
        canonical_synced=1
    fi
done

# 所有目标成功后才迁移；仅处理本次选中的仓库 skill，不碰系统或第三方技能。
migrated=0
if [ "${canonical_synced}" -eq 1 ]; then
    [ ! -L "${LEGACY_DIR}" ] || die "旧 skills 根目录是链接，未迁移：${LEGACY_DIR}"
    if [ -d "${LEGACY_DIR}" ]; then
        legacy_root="$(cd -- "${LEGACY_DIR}" && pwd -P)"
        [[ "${legacy_root}" != "${ROOT_DIR}" && "${ROOT_DIR}" != "${legacy_root}"/* &&
           "${legacy_root}" != "${ROOT_DIR}"/* ]] || die '旧 skills 根目录与源码重叠，未迁移'
    fi
    for name in "${names[@]}"; do
        legacy="${LEGACY_DIR}/${name}"
        if [ -e "${legacy}" ] || [ -L "${legacy}" ]; then
            ensure_backup
            mkdir -p -- "${BACKUP_DIR}/legacy"
            mv -- "${legacy}" "${BACKUP_DIR}/legacy/${name}"
            migrated=$((migrated + 1))
        fi
    done
fi
printf '已备份迁移旧 Codex 副本：%s 个。\n' "${migrated}"
printf '%s\n' '若当前 Codex 技能列表仍显示旧路径，请重启 Codex 后开启新会话。'
