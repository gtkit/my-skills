---
name: shell-scripting
description: Shell 脚本工程化与跨平台陷阱库。当用户编写、审查或调试 Shell/Bash/sh 脚本，涉及 set -euo pipefail、trap 清理、变量引用、word splitting、数组、字符串处理、mktemp 临时文件、信号处理、退出码、管道错误传递，或遇到脚本在 macOS 与 Linux 上行为不一致（sed -i、date、stat、readlink、grep -P、xargs、bash 版本差异）时触发。触发关键词包括但不限于：shell 脚本、bash 脚本、sh 脚本、set -e、set -u、pipefail、trap、shellcheck、word splitting、IFS、mktemp、BSD sed、GNU sed、macOS 脚本、脚本兼容性、部署脚本、CI 脚本、退出码、$?、"$@"、局部变量、数组遍历。
---

# Shell 脚本工程化

本文的行为结论均在 macOS（darwin22，`/bin/bash` 3.2.57、BSD 用户态工具）上实测得出，
标注「实测」的即真实运行结果。

## 脚本骨架

```bash
#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'                       # 去掉空格作为分隔符，杜绝路径带空格时的 word splitting

# 脚本所在目录（不受调用者 cwd 影响）
readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# 清理：EXIT 覆盖正常退出与 set -e 退出；INT/TERM 处理信号
readonly TMPDIR_="$(mktemp -d)"
cleanup() {
    local rc=$?                   # 必须第一行取，后续命令会覆盖 $?
    rm -rf -- "$TMPDIR_"
    exit "$rc"                    # 保留原始退出码
}
trap cleanup EXIT INT TERM
```

三个开关的含义：`-e` 命令失败即退出，`-u` 引用未定义变量即报错，`-o pipefail` 管道中任一环失败即视为失败。

`#!/usr/bin/env bash` 而不是 `#!/bin/sh`：**macOS 的 `/bin/sh` 实测是 `GNU bash 3.2.57` 的 sh 兼容模式**，
它恰好支持 `pipefail`；但 Linux 上 `/bin/sh` 常是 dash，`set -o pipefail` 会直接失败。
写 `#!/bin/sh` 就不能依赖 pipefail、数组、`[[ ]]`、`local`。

## set -e 会在哪些地方失效

**这是 shell 最反直觉的部分。** 以下都是实测：

```bash
# ✅ 正常触发：纯 set -e + 失败命令 → 脚本退出，退出码 1
set -e
false
echo "不会执行"

# ❌ 陷阱一：命令处于 && / || 列表中时，set -e 对它不生效
f() { false; echo "仍然执行了"; }
f || true                         # 实测：函数内 false 之后的 echo 照样执行

# ❌ 陷阱二：local/declare/export 的赋值
g() {
    local x=$(false)              # 实测：不触发退出
    echo "仍然执行了"
}
# 原因：退出码来自 local 本身，不是命令替换。要检查就拆开：
g2() {
    local x
    x=$(false) || return 1        # 这样才捕获得到
}

# ❌ 陷阱三：管道中段失败（未开 pipefail）
false | true                      # 实测：不触发，$? 是最后一环的 0
set -o pipefail
false | true                      # 开了才触发

# 预期行为（不算陷阱）：if / while 条件里的失败不触发
if false; then :; fi              # 正常继续
```

推论：**不要把 `set -e` 当安全网**。关键命令显式判断：

```bash
if ! some_command; then
    echo "some_command 失败" >&2
    exit 1
fi

# 或者
some_command || { echo "失败" >&2; exit 1; }
```

## 引用：不加引号就是 bug

未加引号的变量会经历 word splitting 和 glob 展开两道处理：

```bash
file="my report.txt"
rm $file                          # ❌ 展开成 rm my report.txt —— 删错两个文件
rm "$file"                        # ✅

pattern="*.txt"
echo $pattern                     # ❌ 被 glob 展开成实际文件名
echo "$pattern"                   # ✅ 输出 *.txt

# "$@" 与 $* 的区别：前者保留每个参数的边界
for a in "$@"; do echo "[$a]"; done      # ✅ 逐个参数
for a in $*;  do echo "[$a]"; done       # ❌ 全部重新分词

# 命令替换同样要引号
files="$(find . -name '*.go')"    # 多行结果，遍历时要配合 IFS 或改用 -print0
```

规则：**除了刻意要分词或 glob，所有 `$var` 都写 `"$var"`**。数字比较、`[[ ]]` 内部也照样加。

处理文件名一律用 `-print0` / `-d ''`，别指望 IFS：

```bash
# ✅ 能处理任何文件名，包括含空格、换行、引号
while IFS= read -r -d '' f; do
    process "$f"
done < <(find . -name '*.log' -print0)
```

`--` 终止选项解析，防止以 `-` 开头的文件名被当成参数：`rm -- "$f"`、`grep -- "$pat" file`。

## macOS/BSD 与 Linux/GNU 的差异

本机实测（`/usr/bin/*` 为 BSD 版本）：

| 操作 | BSD / macOS | GNU / Linux | 可移植写法 |
|------|-------------|-------------|-----------|
| 原地编辑 | `sed -i '' 's/a/b/' f`（**`-i` 后必须给参数**，实测无参数直接失败） | `sed -i 's/a/b/' f` | 写临时文件再 `mv`，或 `perl -i -pe` |
| 日期解析 | `date -j -f '%Y-%m-%d' '2026-01-01' +%s`（实测 `date -d` **不可用**） | `date -d '2026-01-01' +%s` | 传 epoch 秒，或用 python3 |
| 文件大小 | `stat -f '%z' f`（实测 `stat -c` **不可用**） | `stat -c '%s' f` | `wc -c < f` |
| PCRE 正则 | `/usr/bin/grep -P` 实测**不可用** | `grep -P` 可用 | `grep -E`（ERE），或 `perl -ne` |
| 绝对路径 | `readlink -f` 实测**可用**（近年 macOS 已支持） | 可用 | `cd -- "$(dirname "$f")" && pwd` |
| 空输入不执行 | `xargs -r` 实测**可用**（BSD 空输入本就不执行） | 需要 `-r` | 加 `-r` 两边都安全 |
| 就地排序 | `sort -o f f` 两边都可用 | 同 | — |

判断当前环境，而不是猜：

```bash
if sed --version >/dev/null 2>&1; then
    SED_INPLACE=(-i)              # GNU
else
    SED_INPLACE=(-i '')           # BSD
fi
sed "${SED_INPLACE[@]}" 's/a/b/' file
```

**注意本机的 `grep` 不是 BSD grep**：实测 `command -v grep` 指向 `ugrep 7.8.4`，它支持 `-P`。
写脚本时不能依赖这一点——别人的机器上 `grep` 大概率是 BSD 或 GNU 版本。

## macOS 自带 bash 是 3.2

实测 `/bin/bash --version` → `3.2.57`。以下 bash 4+ 特性在它上面**全部不可用**（实测）：

```bash
declare -A map                    # ❌ 关联数组
echo "${var^^}"                   # ❌ 大小写转换
mapfile -t arr < file             # ❌ mapfile / readarray
```

替代：

```bash
# 关联数组 → 用两个平行数组，或 case，或外部工具
lookup() {
    case "$1" in
        dev)  echo "127.0.0.1" ;;
        prod) echo "10.0.0.1"  ;;
        *)    return 1 ;;
    esac
}

# ${var^^} → tr
upper="$(printf '%s' "$var" | tr '[:lower:]' '[:upper:]')"

# mapfile → while read 循环
arr=()
while IFS= read -r line; do arr+=("$line"); done < file
```

要用 bash 4+ 特性，就在脚本开头显式检查并给出可操作的错误：

```bash
if (( BASH_VERSINFO[0] < 4 )); then
    echo "需要 bash 4+，当前 $BASH_VERSION；macOS 请 brew install bash" >&2
    exit 1
fi
```

## 路径拼接与 cp/rsync 的尾斜杠

**BSD `cp -R` 对尾斜杠敏感**，这条实测过，而且是高频线上事故来源：

```bash
mkdir -p src dst; echo hi > src/f.txt

cp -R src/ dst/     # 实测：dst/f.txt      ← 复制的是「内容」
cp -R src  dst/     # 实测：dst/src/f.txt  ← 复制的是「目录本身」
```

想要 `dst/src/`，源路径**不能带尾斜杠**。用 glob（`cp -R src/*/ dst/`）时尤其危险：
`*/` 展开出的每一项都自带尾斜杠，于是全部内容被倒进同一层、互相覆盖。

```bash
# ✅ 稳妥写法：逐个显式建同名子目录
for d in src/*/; do
    name="$(basename -- "$d")"
    cp -R -- "src/$name" "dst/$name"
done

# ✅ 或者用 rsync，语义明确（尾斜杠 = 内容，无尾斜杠 = 目录本身，且跨平台一致）
rsync -a src/ dst/                # 内容
rsync -a src  dst/                # 目录本身
```

## 临时文件

```bash
# ✅ mktemp 两边都支持 -d，且模板必须以至少 6 个 X 结尾（若自带模板）
tmp="$(mktemp -d)"
tmpf="$(mktemp "${TMPDIR:-/tmp}/myscript.XXXXXX")"
trap 'rm -rf -- "$tmp" "$tmpf"' EXIT

# ❌ 固定名字：可预测路径 = 符号链接攻击 + 并发互相覆盖
tmp=/tmp/myscript.tmp
```

`rm -rf` 的变量必须确保非空——`set -u` 能挡住未定义，但挡不住空串：

```bash
rm -rf -- "${dir:?dir 未设置或为空}"/   # 空值时直接报错退出，而不是删掉 /
```

## 退出码与错误输出

```bash
# 错误信息一律进 stderr，否则会污染被调用方解析的 stdout
echo "配置缺失" >&2

# 保留原始退出码：任何命令都会覆盖 $?
some_command
rc=$?                             # 立刻存
log "退出码 $rc"                   # log 会覆盖 $?
exit "$rc"

# 信号退出码约定：128 + 信号号（SIGINT=130, SIGTERM=143）
```

函数用 `return`，脚本用 `exit`。函数里写 `exit` 会终止整个脚本，调用方无法处理。

## 审查清单

- [ ] `set -euo pipefail` 齐全，且 shebang 是 `bash` 而非 `sh`（要 sh 就不用 pipefail/数组/`[[ ]]`）
- [ ] 所有 `$var` 加引号，包括 `"$@"`、`"${arr[@]}"`
- [ ] 关键命令显式判断失败，不依赖 `set -e`（尤其在 `||`/`&&` 列表和 `local x=$(...)` 中）
- [ ] `trap ... EXIT` 清理临时文件，且 cleanup 第一行就存 `$?`
- [ ] 临时文件用 `mktemp`，不用固定路径
- [ ] `rm -rf` 的变量用 `${var:?}` 兜底
- [ ] 文件名遍历用 `-print0` + `read -r -d ''`
- [ ] `--` 终止选项解析
- [ ] `sed -i` / `date` / `stat` / `grep -P` 做了平台判断，或改用可移植写法
- [ ] 未使用 bash 4+ 特性，或已做 `BASH_VERSINFO` 版本检查
- [ ] `cp -R` 的源路径尾斜杠语义确认过（要目录本身就不能带 `/`）
- [ ] 错误信息进 stderr，退出码有意义
