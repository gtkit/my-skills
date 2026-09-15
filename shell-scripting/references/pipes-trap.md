# 管道、子 shell 与 trap

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
