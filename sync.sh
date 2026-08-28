#!/bin/sh
# sync.sh —— 把本仓库的 skill 目录同步到本机各 AI 工具的 skills 目录。
#
# 用法:
#   ./sync.sh                同步全部 skill 到默认目标（见 TARGETS）
#   ./sync.sh go-review      只同步指定的
#   ./sync.sh a b c          同步多个
#   TARGETS="$HOME/.claude/skills" ./sync.sh   自定义目标目录（空格分隔）
#
# 规则:
#   - 单一来源是本仓库；目标目录里同名 skill 会被整目录覆盖（rsync --delete 只作用于该 skill 目录内部）。
#   - 目标目录里仓库没有的 skill（如 go-harness、go-pkg-harness、go-grpc-harness）原样保留，不动。
#   - .DS_Store 不同步。
#   - 目标目录不存在时跳过并提示，不自动创建。

set -e
cd "$(dirname "$0")"

TARGETS="${TARGETS:-$HOME/.claude/skills $HOME/.codex/skills}"

if [ $# -eq 0 ]; then
    set -- $(find . -mindepth 2 -maxdepth 2 -name SKILL.md \
             | sed 's|^\./||; s|/SKILL\.md$||' | sort)
fi

for target in $TARGETS; do
    if [ ! -d "$target" ]; then
        echo "跳过 $target：目录不存在" >&2
        continue
    fi
    n=0
    for name in "$@"; do
        if [ ! -f "$name/SKILL.md" ]; then
            echo "跳过 $name：不含 SKILL.md" >&2
            continue
        fi
        rsync -a --delete \
            --exclude '.DS_Store' \
            "$name/" "$target/$name/"
        n=$((n + 1))
    done
    echo "$target：已同步 $n 个"
done
