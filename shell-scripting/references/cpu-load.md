# 制造 CPU 负载：两道独立的自毁保险

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
