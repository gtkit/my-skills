# bash 3.2 与路径、临时文件

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
