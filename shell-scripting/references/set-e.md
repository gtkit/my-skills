# set -e 会在哪些地方失效

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
