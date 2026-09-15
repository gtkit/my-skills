---
name: shell-scripting
description: Shell/Bash 脚本怎么写对：set -e 失效点、引用与数组、trap 与信号、getopts、锁与超时、CPU 负载脚本的自毁保险、macOS/BSD 与 GNU 差异、bash 3.2 兼容。编写、审查或调试 Shell 脚本时使用。
---

# Shell 脚本工程化

本文行为结论在 macOS `/bin/bash` 3.2.57 + BSD 用户态工具上实测，标「实测」处为真实运行结果；给出的写法同时兼容 bash 3.2 与 5.x。

## 核心规则

1. `readonly`/`local`/`declare`/`export` 与 `$(...)` 不写在同一行——声明内建会吞掉命令替换的退出码。
2. `set -e` 不进入 `$(...)`、不管 `&&`/`||` 列表、不管 `if`/`while` 条件里的命令——关键命令显式判断。
3. `set -u` 下 bash 3.2 展开空数组 `"${arr[@]}"` 会报 `unbound variable`，用 `"${arr[@]+"${arr[@]}"}"`。
4. `[ ]` 与普通命令参数一律加引号；`[[ ]]` 内不分词，`==`/`=~` 右侧加了引号就变字面量匹配。
5. 清理只挂在 `EXIT` 一个 trap 上；信号 trap 里要么 `trap - EXIT` 要么重发信号，否则 cleanup 跑两次。
6. `cmd | while read` 的循环体在子 shell 里，循环里改的变量外面看不到；用 `< <(cmd)` 或临时文件。
7. `read` 必带 `-r`；要保留首尾空白再加 `IFS=`。
8. 临时文件用 `mktemp`，且检查它的退出码；`rm -rf` 的变量用 `${var:?}` 兜底。
9. 需要 bash 4+ 特性（关联数组、`mapfile`、`${var^^}`、`inherit_errexit`、`lastpipe`）就检查 `BASH_VERSINFO` 并报错退出，不要默默跑坏。
10. 交付前过 `shellcheck`；没有 shellcheck 至少 `bash -n`。
11. 故意制造 CPU 负载（压测、烤机、演练）必须叠加看门狗与 `ulimit -t` 两道自毁保险，两者都不依赖清理代码被执行。

## 脚本骨架

```bash
#!/usr/bin/env bash
set -euo pipefail

# 先赋值再 readonly：readonly X="$(cmd)" 的退出码来自 readonly，cmd 失败不会中止（实测）
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

# mktemp 失败（目录不存在/不可写）必须显式判断，否则拿着空串继续，后面 rm -rf -- "$WORK_DIR/" 就是 rm -rf /
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/${0##*/}.XXXXXX")" || { echo "mktemp 失败" >&2; exit 1; }
readonly WORK_DIR

cleanup() { rm -rf -- "${WORK_DIR:?}"; }
trap cleanup EXIT     # 正常退出、set -e 退出、Ctrl-C(130)、SIGTERM(143) 都会走这里，且只走一次（实测）

main() {
    echo "使用 $SCRIPT_DIR 与 $WORK_DIR"
}
main "$@"
```

三个开关：`-e` 命令失败即退出，`-u` 引用未定义变量即报错，`-o pipefail` 管道任一环失败即失败。

不在骨架里设 `IFS=$'\n\t'`：实测它会把 `"$*"`、`"${arr[*]}"` 的连接符从空格变成换行，
依赖默认 IFS 的 `read`/`$*` 全部变样；靠引号解决分词，不靠改 IFS。

`#!/usr/bin/env bash` 而不是 `#!/bin/sh`：macOS 的 `/bin/sh` 实测是 bash 3.2 的 sh 兼容模式，恰好支持 `pipefail`；
Linux 的 `/bin/sh` 常是 dash，`set -o pipefail`、数组、`[[ ]]`、`local` 都没有。

## set -e 会在哪些地方失效

```bash
set -e
# 陷阱一：&& / || 列表和 if/while 条件里的命令，set -e 对它们以及它们调用的函数体都不生效
f() { false; echo "f 内 false 后继续"; }
f || true                         # 实测：echo 照样执行
if f; then :; fi                  # 实测：同样继续

# 陷阱二：声明内建 + 命令替换
g() {
    local x=$(false)              # 实测：不退出，退出码是 local 的 0
    readonly y="$(false)"         # 实测：同上
    local z; z=$(false)           # ✅ 分两行，实测：退出
}

# 陷阱三：$(...) 内部不继承 set -e
x=$(false; echo "子 shell 继续")  # 实测：x="子 shell 继续"，外层也不退出
# 修法：shopt -s inherit_errexit（bash 4.4+；3.2 实测报 invalid shell option name），
# 或在子 shell 里显式写 set -e：x=$(set -e; false; echo no)

# 陷阱四：管道中段失败且未开 pipefail
false | true                      # 实测：不退出；开 pipefail 后退出

# 陷阱五：算术命令
n=0; ((n++))                      # 表达式值为 0 → 退出码 1。bash 3.2 实测不退出，新版 bash 会退出——两边不同
n=$((n+1))                        # ✅ 一律用赋值形式
```

推论：**`set -e` 是兜底不是安全网**，关键命令显式判断：`cmd || { echo "cmd 失败" >&2; exit 1; }`。

`ERR` trap 在 bash 3.2 就有（实测），适合统一打点，`$BASH_COMMAND` 是出错的那条命令：

```bash
trap 'echo "失败: $BASH_COMMAND (行 $LINENO)" >&2' ERR
```

## 引用：不加引号就是 bug

未加引号的变量要经历 word splitting 与 glob 展开两道处理：

```bash
file="my report.txt"; rm $file    # ❌ 变成 rm my report.txt
rm -- "$file"                     # ✅  -- 防止以 - 开头的文件名被当选项

pattern="*.txt"; echo $pattern    # ❌ 被 glob 展开成文件名
for a in "$@"; do echo "[$a]"; done   # ✅ "$@" 保留参数边界；$* 会重新分词

x="a b"
[ $x == "a b" ]                   # ❌ 实测：[: too many arguments
[[ $x == "a b" ]]                 # ✅ 实测匹配：[[ ]] 内部不做 word splitting
```

`[[ ]]` 右侧的引号决定的是**匹配语义**而不是安全（实测）：

```bash
x=foo.txt; p='*.txt'
[[ $x == $p ]]                    # 匹配（glob）
[[ $x == "$p" ]]                  # 不匹配：加引号后 * 是字面量
re='^[a-z]+[0-9]+$'
[[ abc123 =~ $re ]]               # 匹配（正则，正则放变量里再引用，避免转义地狱）
[[ abc123 =~ "$re" ]]             # 不匹配：加引号后整串是字面量
```

规则：`[[ ]]` 左侧加不加都行，右侧想要 glob/正则就不要加引号，想要字面量相等就加。

文件名遍历一律 `-print0` / `read -d ''`：

```bash
while IFS= read -r -d '' f; do
    process "$f"
done < <(find . -name '*.log' -print0)
```

## 数组与 set -u（bash 3.2 高频崩溃点）

```bash
set -u
arr=()
for a in "${arr[@]}"; do :; done          # ❌ bash 3.2 实测：arr[@]: unbound variable 并终止；4.4 起才修复
for a in "${arr[@]+"${arr[@]}"}"; do :; done   # ✅ 实测：空数组零次循环，有元素时保留 "x y" 边界
(( ${#arr[@]} == 0 )) && echo 空           # ✅ ${#arr[@]} 在空数组上不报错（实测）

cmd=(sed)
if sed --version >/dev/null 2>&1; then cmd+=(-i); else cmd+=(-i ''); fi
"${cmd[@]}" 's/a/b/' file                  # 数组是唯一安全的"拼命令行"方式，不要 eval 拼字符串
```

## 管道、子 shell 与 read

```bash
n=0
printf 'a\nb\n' | while read -r l; do n=$((n+1)); done
echo "$n"                                  # 实测：0——while 在管道子 shell 里，变量改了外面看不到
while read -r l; do n=$((n+1)); done < <(printf 'a\nb\n')
echo "$n"                                  # 实测：2（进程替换，循环体在当前 shell）
# shopt -s lastpipe 也能解，但 bash 4.2+ 才有（3.2 实测 invalid shell option name）

x=$(printf 'a\n\n\n'); printf '%s' "$x" | od -c    # 实测：只剩 a——$(...) 吞掉全部尾部换行
x=$(printf 'a\n\n\n'; printf x); x=${x%x}          # 需要保留时加哨兵再去掉

printf 'a\\tb\n' | { read l; echo "$l"; }          # 实测：atb——不加 -r 反斜杠被吃掉
printf '  s  \n' | { read -r l; echo "[$l]"; }     # 实测：[s]——默认 IFS 会裁掉首尾空白
printf '  s  \n' | { IFS= read -r l; echo "[$l]"; } # 实测：[  s  ]
```

`if ! cmd | grep -q x` 这种管道里 `grep -q` 提前退出会让 `cmd` 收到 SIGPIPE；开了 pipefail 就是非零，要么接受要么 `cmd > "$tmp"; grep -q x "$tmp"`。

## trap 与信号

```bash
# ❌ 常见写法：cleanup 跑两次（实测）——INT 触发 cleanup，里面的 exit 又触发 EXIT，再跑一遍
cleanup() { rc=$?; rm -rf -- "$tmp"; exit "$rc"; }
trap cleanup EXIT INT TERM

# ✅ 写法一（推荐）：只挂 EXIT。实测 SIGTERM → cleanup 一次、退出码 143；Ctrl-C → 一次、130
trap cleanup EXIT

# ✅ 写法二：信号要做专门动作时，先解除 EXIT 再退出，退出码 128+信号号
trap 'trap - EXIT; cleanup; exit 130' INT
trap 'trap - EXIT; cleanup; exit 143' TERM

# ✅ 写法三：清理后以同一信号自杀，父进程能看到"被信号杀死"而不是 exit 码（实测退出码同为 130/143）
for s in INT TERM; do trap "trap - $s EXIT; cleanup; kill -s $s \$\$" "$s"; done
```

EXIT trap 里 `$?` 是脚本的最终退出码，`set -e` 触发时也是（实测 `return 3` → 3）；cleanup 第一行取，后面的命令会覆盖。

`kill -INT <脚本 pid>` 不一定停得住脚本：实测 bash 正在等前台子进程（如 `sleep`）时，子进程没被中断则 bash 继续往下跑。
要停脚本发 `TERM`，或对进程组发 `kill -INT -- -<pgid>`（Ctrl-C 就是这样）。

## 参数解析：getopts

```bash
usage() { printf 'usage: %s [-n] [-e env] -f file [--] args...\n' "${0##*/}" >&2; exit 64; }
dry_run=0 env=prod file=
while getopts ':ne:f:h' opt; do          # 前导 : 让缺参数走 :) 分支而不是打印内建错误
    case $opt in
        n) dry_run=1 ;;
        e) env=$OPTARG ;;
        f) file=$OPTARG ;;
        h) usage ;;
        :) printf '选项 -%s 缺少参数\n' "$OPTARG" >&2; usage ;;
        \?) printf '未知选项 -%s\n' "$OPTARG" >&2; usage ;;
    esac
done
shift $((OPTIND - 1))
[[ -n $file ]] || usage
```

实测：`-n -e dev -f a.txt x y` 解析正确、`-f` 缺参数与 `-z` 未知选项均走 usage 退出 64。
`getopts` 只支持短选项；要 `--long` 就手写 `while [[ $# -gt 0 ]]; case $1 in --file) file=$2; shift 2 ;;` 循环。

## 单实例锁与超时

```bash
# flock 只有 Linux 有（macOS 实测无 flock）。可移植的锁用 mkdir 的原子性（实测第二次 mkdir 失败 rc=1）
lock=/tmp/${0##*/}.lock
if ! mkdir -- "$lock" 2>/dev/null; then echo "已有实例在跑" >&2; exit 1; fi
trap 'rmdir -- "$lock"' EXIT                    # 进程被 kill -9 会留下死锁目录，需运维手动删；flock 没这问题

# timeout 命令 macOS 实测无（coreutils 的叫 gtimeout，需 brew）。可移植写法：
perl -e 'alarm shift; exec @ARGV' 5 some_cmd    # 实测超时后进程被 SIGALRM 杀，退出码 142
```

Linux 上优先 `flock -n "$lockfile" cmd` 或 `exec 9>"$lockfile"; flock -n 9 || exit 1`（进程退出即释放）和 `timeout -k 5 30 cmd`。

## 制造 CPU 负载：两道独立的自毁保险

压测、烤机、故障演练里写 `while :; do :; done`、`yes > /dev/null`、`stress-ng` 这类**故意占满 CPU** 的代码时，只靠 `trap` 清理是不够的：`kill` 那行写错、变量名笔误、脚本提前 `exit`、终端被关、SSH 断开，进程就留在机器上跑到有人发现——"存活 3 天"就是这么来的。

**规则：看门狗 + `ulimit -t` 必须叠加，两道保险互相独立，都不依赖清理代码被正确执行。**

```bash
#!/bin/bash
set -euo pipefail

readonly MAX_CPU=30          # 保险二：内核按 CPU 秒强制终止
readonly MAX_WALL=60         # 保险一：看门狗按墙钟强制终止

ulimit -t "$MAX_CPU"         # 必须在 fork 出负载进程之前设；子进程自动继承，且本 shell 内不可再调高

# 看门狗：独立进程，自带定时器，不读任何共享变量，脚本怎么崩它都照常执行
( sleep "$MAX_WALL"; kill -9 -$$ 2>/dev/null ) &
readonly WATCHDOG=$!

set -m                       # 让本脚本成为进程组组长，kill -9 -$$ 能带走整棵子进程树
while :; do :; done &        # 负载进程
readonly LOAD=$!

trap 'kill "$LOAD" "$WATCHDOG" 2>/dev/null || :' EXIT   # 第三道，正常路径用；坏了也不影响上面两道
wait "$LOAD" || :
```

两道保险各自的边界（均为 macOS bash 3.2.57 实测）：

| 机制 | 计什么时间 | 触发后 | 失效场景 |
|---|---|---|---|
| `ulimit -t N` | **CPU 时间，不是墙钟** | 发 `SIGXCPU`，退出码 `152`（128+24） | 阻塞型进程杀不掉——`ulimit -t 2` 下 `sleep 4` 实测正常跑完退出码 0 |
| 看门狗 `sleep N; kill` | 墙钟 | 由你决定信号，用 `-9 -$$` 带走整个进程组 | 看门狗自己被误杀、或 `$$` 不是组长（漏了 `set -m`）时只杀到自己 |

- 这两条恰好互补：CPU 密集型负载被 `ulimit -t` 兜住，阻塞/挂起型被看门狗兜住，所以必须都写。
- `ulimit -t` 要在启动负载**之前**设。降低后本 shell 内不可逆（实测再调高报 `cannot modify limit: Operation not permitted`），子进程继承，所以负载进程无法自己解除。
- 看门狗写成 `( sleep N; kill ... ) &` 的独立子 shell，不要写成 `trap` 里的定时逻辑——它的价值就在于不依赖主流程还活着。
- 远程执行时再加一层：`ssh` 断开不一定杀掉远端进程，负载命令套 `setsid` 或依赖上面两道保险，别指望 SIGHUP。

## macOS/BSD 与 Linux/GNU 的差异

| 操作 | BSD / macOS | GNU / Linux | 可移植写法 |
|------|-------------|-------------|-----------|
| 原地编辑 | `sed -i '' 's/a/b/' f`（`-i` 后必须给参数，实测无参数失败） | `sed -i 's/a/b/' f` | 写临时文件再 `mv`，或 `perl -i -pe` |
| 日期解析 | `date -j -f '%Y-%m-%d' '2026-01-01' +%s`（实测无 `-d`） | `date -d '2026-01-01' +%s` | 传 epoch 秒 |
| 文件大小 | `stat -f '%z' f`（实测无 `-c`） | `stat -c '%s' f` | `wc -c < f` |
| PCRE 正则 | `/usr/bin/grep -P` 实测不可用 | `grep -P` | `grep -E`，或 `perl -ne` |
| 绝对路径 | `readlink -f` macOS 12.3+ 可用 | 可用 | `cd -- "$(dirname -- "$f")" && pwd` |
| 空输入不执行 | `xargs -r` 可用（BSD 空输入本就不执行） | 需 `-r` | 加 `-r` |
| 文件锁 / 超时 | 无 `flock`、无 `timeout` | 有 | 见上节 |

判断环境用能力探测，不用 `uname`：`if sed --version >/dev/null 2>&1; then GNU_SED=1; fi`。

## macOS 自带 bash 是 3.2

以下 bash 4+ 特性在 3.2 上全部不可用（实测报错）：`declare -A`、`${var^^}`/`${var,,}`、`mapfile`/`readarray`、
`shopt -s inherit_errexit`（4.4）、`shopt -s lastpipe`（4.2）、`${var@Q}`（4.4）、`printf '%(%F)T'`（4.2）。

```bash
lookup() { case "$1" in dev) echo 127.0.0.1 ;; prod) echo 10.0.0.1 ;; *) return 1 ;; esac; }   # 替代关联数组
upper="$(printf '%s' "$var" | tr '[:lower:]' '[:upper:]')"                                      # 替代 ${var^^}
arr=(); while IFS= read -r line; do arr+=("$line"); done < file                                 # 替代 mapfile

if (( BASH_VERSINFO[0] < 4 )); then
    echo "需要 bash 4+，当前 ${BASH_VERSION}；macOS 请 brew install bash" >&2; exit 1
fi
```

3.2 专有坑：`$VAR` 后面直接跟中文标点时，多字节字符会被并进变量名——`echo "当前 $BASH_VERSION；"` 在 `set -u` 下
报 `unbound variable` 并终止（实测；bash 5 正常）。变量后紧跟非 ASCII 字符一律写 `${VAR}`。

## 路径拼接与 cp 的尾斜杠

BSD `cp -R` 对尾斜杠敏感（实测）：`cp -R src/ dst/` 得到 `dst/f.txt`（内容），`cp -R src dst/` 得到 `dst/src/f.txt`（目录本身）。
`cp -R src/*/ dst/` 展开出的每一项自带尾斜杠，全部内容倒进同一层互相覆盖。

```bash
for d in src/*/; do name="$(basename -- "$d")"; cp -R -- "src/$name" "dst/$name"; done
rsync -a src/ dst/     # rsync 语义两边一致：尾斜杠 = 内容，无尾斜杠 = 目录本身
```

## 临时文件与危险删除

```bash
tmpf="$(mktemp "${TMPDIR:-/tmp}/myscript.XXXXXX")" || exit 1   # 模板末尾至少 3 个 X 即可（macOS 实测 XXX 可用，GNU 同）；写 6 个是习惯不是要求
tmp=/tmp/myscript.tmp                                          # ❌ 固定名：可预测路径 = 符号链接攻击 + 并发互相覆盖

rm -rf -- "${dir:?dir 未设置或为空}/"    # 实测空值时报错退出（rc 非 0），而不是 rm -rf /
```

`printf '%q' "$v"` 用于把值安全地拼进要 `ssh`/`eval` 的命令串（实测 `a b;rm -rf /` → `a\ b\;rm\ -rf\ /`）。

## 退出码与错误输出

- 错误信息进 stderr：`echo "配置缺失" >&2`；stdout 留给被调用方解析。
- 保留退出码：`cmd; rc=$?` 立刻存，任何后续命令都会覆盖 `$?`。
- 约定：0 成功、1 一般错误、2 用法错误（bash 内建也用 2）、64 用法错误（sysexits）、126 不可执行、127 命令不存在、128+n 信号（130=INT，143=TERM）。
- 函数用 `return`，脚本用 `exit`；函数里 `exit` 会终止整个脚本。

## 静态检查

- 有 `shellcheck`：`shellcheck -s bash -S warning script.sh`，CI 里对所有 `*.sh` 跑；忽略必须逐行 `# shellcheck disable=SC2034` 并写原因。
- 无 shellcheck：`bash -n script.sh` 只查语法，查不出引号与 set -e 问题，仍要人工过审查清单。
- 兼容性验证跑真实的 `/bin/bash`（3.2）和目标 Linux 的 bash 各一遍，不要只在 brew 的 bash 5 上测。

## 何时不该用 Shell

| 场景 | 选择 | 理由 |
|------|------|------|
| 超过 ~200 行、需要数据结构、要单测 | Python / Go | bash 没有真正的数据结构与错误类型，测试成本高 |
| 解析 JSON/YAML | `jq` / `yq`，或换语言 | 正则拼 JSON 必出错 |
| 并发任务编排 | Go / Python asyncio，或 `xargs -P` 做简单并行 | bash 的 `&`+`wait` 没有错误汇聚 |
| 需要在 sh 与 bash 间可移植 | 严格 POSIX sh（无数组、无 `[[`、无 `local`、无 pipefail） | 或干脆要求 bash |

## 审查清单

- [ ] `set -euo pipefail` 齐全，shebang 是 `bash`；要 sh 就不用 pipefail/数组/`[[ ]]`/`local`
- [ ] 没有 `readonly/local/declare/export X="$(...)"`，全部拆成两行
- [ ] `mktemp` 的返回值有判断；`rm -rf` 的变量用 `${var:?}` 兜底
- [ ] 制造 CPU 负载的脚本同时有看门狗与 `ulimit -t`，且 `ulimit -t` 设在启动负载之前
- [ ] 所有 `$var`、`"$@"` 加引号；`[[ ]]` 右侧的引号符合意图（glob/正则不加、字面量加）
- [ ] 空数组在 `set -u` 下用 `"${arr[@]+"${arr[@]}"}"`，或先判 `${#arr[@]}`
- [ ] 关键命令显式判断失败，不依赖 `set -e`（尤其 `||`/`&&` 列表、`$(...)`、`if` 条件里的函数）
- [ ] 只有一个 `trap ... EXIT` 负责清理；信号 trap 里 `trap - EXIT` 或重发信号；cleanup 第一行取 `$?`
- [ ] 没有 `cmd | while read` 改外层变量；`read` 带 `-r`，需要保留空白时加 `IFS=`
- [ ] 文件名遍历用 `-print0` + `read -r -d ''`；`--` 终止选项解析
- [ ] `sed -i` / `date` / `stat` / `grep -P` / `flock` / `timeout` 做了能力探测或改用可移植写法
- [ ] 未用 bash 4+ 特性，或已做 `BASH_VERSINFO` 检查并给出安装指引；变量后紧跟中文标点的写成 `${VAR}`
- [ ] `cp -R` 源路径尾斜杠语义确认过
- [ ] 错误信息进 stderr，退出码有意义（用法错误 2/64，信号 128+n）
- [ ] 过了 `shellcheck`（无则 `bash -n`），disable 注释都写了原因
