# 引用与数组

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
