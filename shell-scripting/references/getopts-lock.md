# 参数解析与单实例锁

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
