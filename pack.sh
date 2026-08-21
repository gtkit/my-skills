#!/bin/sh
# pack.sh —— 把 skill 目录打包成单文件 .skill（zip），用于分发或上传到 claude.ai。
#
# 用法:
#   ./pack.sh                打包全部 skill
#   ./pack.sh go-review      只打包指定的
#   ./pack.sh a b c          打包多个
#
# 产物落在 _dist/<name>.skill。下划线前缀让它不会被"把子目录当 skill"的逻辑扫到。
# zip 用 -D 不写目录条目，与原始归档同构：内部仅 <name>/SKILL.md（含辅助文件的
# skill 会一并带上 references/、scripts/、templates/）。
#
# 单一来源是这里的目录本身；.skill 是产物，改内容请改目录，不要改 _dist 里的包。

set -e
cd "$(dirname "$0")"

DIST=_dist
mkdir -p "$DIST"

# 无参数时取全部：目录名即 skill 名（本目录下 skill 名均不含空格）
if [ $# -eq 0 ]; then
    set -- $(find . -mindepth 2 -maxdepth 2 -name SKILL.md \
             | sed 's|^\./||; s|/SKILL\.md$||' | sort)
fi

n=0
for name in "$@"; do
    if [ ! -f "$name/SKILL.md" ]; then
        echo "跳过 $name：不含 SKILL.md" >&2
        continue
    fi
    rm -f "$DIST/$name.skill"
    zip -q -D -r "$DIST/$name.skill" "$name"
    echo "  $DIST/$name.skill"
    n=$((n + 1))
done
echo "已打包 $n 个"
