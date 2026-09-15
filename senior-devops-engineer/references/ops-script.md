# 运维脚本骨架

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"; readonly SCRIPT_DIR   # 先赋值再 readonly，否则吞退出码
LOG_FILE="${LOG_FILE:-/var/log/${0##*/}.log}"
log() { printf '%s [%s] %s\n' "$(date '+%F %T')" "$1" "${*:2}" | tee -a "$LOG_FILE" >&2 || :; }   # 日志目录不可写时照常打到 stderr，不让脚本死
die() { log ERROR "$*"; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "缺少命令: $1"; }

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/${0##*/}.XXXXXX")" || die "mktemp 失败"
readonly WORK_DIR
cleanup() { rm -rf -- "${WORK_DIR:?}"; }
trap cleanup EXIT                        # 正常退出、set -e、Ctrl-C、SIGTERM 都走这里且只走一次

main() {
    need kubectl
    log INFO "开始，工作目录 ${WORK_DIR}，脚本目录 ${SCRIPT_DIR}"   # 变量后紧跟中文标点要加花括号：bash 3.2 会把多字节字符并进变量名，set -u 下报 unbound variable
    # 每一步先查当前状态再操作（幂等，可重复执行）；写操作前留下可回滚的痕迹（备份、旧版本号）
}
main "$@"
```
