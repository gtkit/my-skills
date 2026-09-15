# 脚本骨架

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
