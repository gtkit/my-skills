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

## 按任务读取

以下内容按任务读取，只读本次需要的文件；核心规则与审查清单已覆盖其结论。

| 任务 | 读 |
|---|---|
| 起一个新脚本的骨架 | `references/skeleton.md` |
| 排查 set -e 不生效、退出码被吞 | `references/set-e.md` |
| 处理变量引用、word splitting、数组、set -u 崩溃 | `references/quoting.md` |
| 处理管道与子 shell 变量丢失、写 trap 清理与信号处理 | `references/pipes-trap.md` |
| 写 getopts 参数解析、单实例锁与超时 | `references/getopts-lock.md` |
| 写压测 / 烤机 / 后台长驻脚本，必须带自毁保险 | `references/cpu-load.md` |
| 兼容 bash 3.2、处理路径拼接与临时文件删除 | `references/portability.md` |

## macOS/BSD 与 Linux/GNU 的差异

| 操作 | BSD / macOS | GNU / Linux | 可移植写法 |
|------|-------------|-------------|-----------|
| 原地编辑 | `sed -i '' 's/a/b/' f`（`-i` 后必须给参数，实测无参数失败） | `sed -i 's/a/b/' f` | 写临时文件再 `mv`，或 `perl -i -pe` |
| 日期解析 | `date -j -f '%Y-%m-%d' '2026-01-01' +%s`（实测无 `-d`） | `date -d '2026-01-01' +%s` | 传 epoch 秒 |
| 文件大小 | `stat -f '%z' f`（实测无 `-c`） | `stat -c '%s' f` | `wc -c < f` |
| PCRE 正则 | `/usr/bin/grep -P` 实测不可用 | `grep -P` | `grep -E`，或 `perl -ne` |
| 绝对路径 | `readlink -f` macOS 12.3+ 可用 | 可用 | `cd -- "$(dirname -- "$f")" && pwd` |
| 空输入不执行 | `xargs -r` 可用（BSD 空输入本就不执行） | 需 `-r` | 加 `-r` |
| 文件锁 / 超时 | 无 `flock`、无 `timeout` | 有 | 见 `references/getopts-lock.md` |

判断环境用能力探测，不用 `uname`：`if sed --version >/dev/null 2>&1; then GNU_SED=1; fi`。

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
