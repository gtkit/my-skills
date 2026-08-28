---
name: code-simplifier
description: 在不改变行为的前提下重构代码以降低理解成本。当用户粘贴一段代码并要求简化、重构、精简、清理、降低嵌套、去重、改善命名、提升可读性，或说"帮我简化这段代码"、"这段代码太复杂了"、"嵌套太深"、"帮我重构一下"、"代码太长了精简一下"、"clean up"、"simplify"、"refactor for readability"时触发。支持 Go、PHP/Laravel、TypeScript/JavaScript、Python、Rust、Lua。用户只说"优化一下"时先确认意图：目标是更快、更省内存、降低延迟属于性能优化，交给 go-performance 或对应 senior-* skill；目标是更好读、更好改才用本 skill。与 go-review 等审查 skill 的分工：审查负责找 bug 与风险，本 skill 负责在行为等价的前提下改表达方式。
---

# 代码简化与重构

在**行为等价**的前提下降低代码的理解成本。每一处改动都要能回答"行为哪里等价、怎么验证的"；回答不了就不改。

## 核心规则

1. 行为等价是唯一目标：输出、副作用、错误路径、边界值、异常类型、执行顺序全部一致；有任一项不确定，保留原写法并在说明中标出疑点。
2. 简化前先跑现有测试并记录结果，简化后再跑一次比对；没有测试的关键函数，先补对比测试再改。
3. 属于"不动的边界"（见下文）的代码只做命名与注释级改动，不改结构。
4. 改成集合链、推导式、迭代器链时，必须说明内存与求值顺序的变化；热路径上的改动要给 benchmark 或明确标注"未测性能"。
5. 用新语言特性替换旧写法时，写出该特性的最低语言版本，并核对项目声明的版本（`go.mod` 的 go 指令、`composer.json` 的 php、`pyproject.toml` 的 requires-python、`Cargo.toml` 的 edition/rust-version、`tsconfig` 的 target）。
6. 不引入新依赖，不删除错误处理，不合并语义不同的分支，不把多个职责塞进一个函数。
7. 代码已经清晰时直接说"没有值得改的地方"，不为显示工作量而改。
8. 有争议的风格改动标"可选"，与"必要"改动分开列。

## 工作流程

1. **读懂**：说出这段代码的输入、输出、副作用、错误路径各是什么；说不出来就先问用户。
2. **定位味道**：嵌套 > 3 层、重复块 ≥ 2 处、单函数 > 60 行、命名无信息量（`data`、`tmp`、`handle`）、描述"做了什么"的注释、只有一个实现的接口、参数 > 5 个。
3. **划边界**：按"不动的边界"表逐条比对，标出禁区。
4. **逐项改**：每项改动附一句话理由与等价性依据。
5. **验证**：按"行为等价性验证"执行并附结果。
6. **说明性能变化**：按"性能特征变化"表逐条自检。
7. **输出**：< 10 处改动给 before/after 对照；更多改动给完整代码 + 改动清单。清单只列有实质意义的项：改了什么、为什么、验证方式、需要注意什么。

## 不动的边界

| 禁区 | 识别方法 | 允许的改动 |
|---|---|---|
| 并发代码 | 出现 goroutine/channel/`sync.*`/`atomic`、`async`/`await` 并发组合（`Promise.all`、`asyncio.gather`、`tokio::spawn`）、锁、`volatile`/内存序 | 只改命名与注释；重排语句、合并临界区、把 `forEach` 改 `for...of` 都可能改变交错或并发度 |
| 金融精度 | 金额、汇率、利息、税费字段；`decimal`、`big.Int`、`bcmath`、`Decimal` 类型 | 不把整数分转浮点，不改运算顺序（浮点加法不满足结合律），不改舍入函数 |
| 错误处理路径 | `if err != nil` 分支、`catch`、`except`、`match Err(e)`、`pcall` | 不合并包装信息不同的分支，不把 `return err` 改成 panic 或反过来，不删"看似多余"的检查 |
| 安全校验 | 鉴权、输入校验、转义、白名单、路径规范化、签名比对、常量时间比较 | 不合并"重复"的校验（可能防御不同攻击面），不把 `subtle.ConstantTimeCompare` 换成 `==` |
| 有意的性能写法 | 预分配容量、对象池、手写循环替代反射、缓存的 `len`、注释含 "hot path"/"benchmark" | 先跑 benchmark，无 benchmark 只改命名 |
| 时间与时区 | `time.Now()`、`Local`/`UTC` 转换、DST 处理、日期截断 | 不把显式时区去掉，不用 `Date` 字符串解析替换显式 parse |
| 序列化契约 | struct tag、JSON 字段名、`omitempty`/`omitzero`、枚举数值、协议字段序号 | 不改字段名与 tag；改 `omitempty` 为 `omitzero` 会改变零值 struct/时间的输出 |

## 行为等价性验证

- **跑现有测试**：Go `go test ./... -count=1 -race`；PHP `vendor/bin/phpunit` 或 `php artisan test`；TS/JS `npx vitest run` 或 `npm test`；Python `pytest -q`；Rust `cargo test`；Lua `busted` 或 `resty` 脚本。简化前后各跑一次，两次结果都要贴出来。
- **对比测试**：对被改函数写一个把原实现复制为 `xxxLegacy` 的测试，用同一组输入比较两者输出与错误；输入覆盖空值、零值、负值、极大值、重复值、元字符（正则/glob/SQL/路径）。
- **属性对比**：输入域大、分支多的纯函数用随机输入跑 ≥ 1000 组对比（Go `testing/quick` 或 `rapid`，Python `hypothesis`，Rust `proptest`）；对比失败即回退该处改动。
- **快照对比**：输出为结构化数据（JSON、HTML、SQL）时，保存原实现输出做 golden file，新实现按字节比对。
- **副作用检查**：日志条数与级别、数据库写次数、外部调用次数——用 mock 计数或日志 diff 确认不变。

## 性能特征变化

| 改法 | 变化 | 处理 |
|---|---|---|
| 循环 → 集合链 / 推导式（Laravel Collection、JS `map().filter()`、Python 列表推导） | 每一步生成中间集合，内存从 O(1) 变 O(n)；Collection 链每步分配新对象 | 数据量 > 1 万条时用生成器/`LazyCollection`/迭代器，或保留循环 |
| 手写循环 → Go `slices.Collect(maps.Keys(m))`、Rust `.collect()` | 多一次完整分配 | 只需要迭代时直接 `for k := range maps.Keys(m)`，不要 collect |
| `forEach(async)` → `for...of` + `await` | 从并发变串行，总耗时从 max 变 sum | 需要并发保留 `Promise.all`；这是行为变化，属"不动的边界" |
| 字符串 `+=` 循环 → `strings.Builder` / `table.concat` / `''.join` | 从 O(n²) 变 O(n)，是收益 | 标注为性能改善并附 benchmark |
| 提前 return 拆分函数 | 通常无变化；Go 中新增闭包可能让变量逃逸到堆 | 热路径用 `go build -gcflags=-m` 核对 |
| 递归 → 迭代或反过来 | 栈深度与内存变化；Python 默认递归深度 1000 | 深度不确定时不改成递归 |

## 语言特化指引

### Go（细节见 use-modern-go）

- `min`/`max`、`slices`、`maps`（Go 1.21）；`for i := range n`（1.22）；range-over-func 与 `iter.Seq`、`maps.Keys` 返回迭代器而非 slice（1.23，1.22 仅 GOEXPERIMENT）；`strings.SplitSeq`/`Lines`、`b.Loop()`、`t.Context()`、`omitzero`（1.24）；`wg.Go()`（1.25）；`errors.AsType[T]`（1.26）。
- `for i := 0; i < len(s); i++` 改 `for i, v := range s`：`v` 是元素拷贝，循环体修改 `s[i]` 或 `append(s, ...)` 时两种写法结果不同。
- `sort.Slice` 与 `slices.Sort` 都不稳定；原代码依赖相等元素顺序时用 `slices.SortStableFunc`。
- 提前 return 时核对 `defer` 的注册时机：把 `defer resp.Body.Close()` 移到检查 `err` 之前，`resp == nil` 时会 nil 指针 panic。
- 不把多个 `if err != nil { return fmt.Errorf("A: %w", err) }` 合并成一个"统一包装"，包装信息不同就是不同的错误路径。
- 单实现的接口不是"抽象"，删掉它是简化；被测试替身使用的接口保留。

### PHP / Laravel（细节见 use-modern-php）

- `match`（8.0）用严格比较 `===`，无匹配抛 `UnhandledMatchError`；`switch` 用宽松比较且无匹配静默跳过——`switch` 改 `match` 在类型不一致的输入上是行为变化，需先确认输入类型。
- 命名参数（8.0）、`enum`、`readonly`、`new` 表达式初始化、first-class callable `strlen(...)`（8.1）、`readonly class`（8.2）、类型化常量（8.3）、property hooks 与非对称可见性（8.4）。
- `Collection::filter()` 保留原 key，`json_encode` 后变对象而非数组；改循环为 `filter()` 后要加 `->values()` 才与原数组语义一致。
- `Collection` 链每步分配新对象；`Model::all()->filter()` 把过滤放到 PHP 端，等价的 `where()` 在 SQL 端完成，两者内存与查询计划都不同。
- `??` 只判断 `null`/未定义，`?:` 判断假值；`isset($a) ? $a : $b` 改 `$a ?? $b` 等价，`$a ? $a : $b` 改 `??` 不等价。

### TypeScript / JavaScript

- `a || b` 改 `a ?? b`（ES2020）在 `a` 为 `0`、`''`、`false` 时结果不同。
- `arr.forEach(async fn)` 不等待回调，改成 `for...of` + `await` 变串行——属并发禁区。
- `Array.prototype.at`（ES2022）、`structuredClone`（Node 17+ 与现代浏览器提供，不属于 ECMAScript 标准）、`Object.groupBy`（ES2024）、`satisfies`（TS 4.9）、`using`（TS 5.2）——核对 `tsconfig` 的 `target` 与 `lib`。
- 顶层函数用 `function` 声明（有提升，可放在调用之后）；把它改箭头函数后调用点在声明之前会抛 `ReferenceError`。
- 用 `unknown` + 类型守卫替代 `any`；显式标注导出函数的返回类型，让重构后的类型变化在编译期暴露。

### Python

- 内置泛型 `list[int]`、`dict[str, int]`（3.9）；`X | None`（3.10，PEP 604）；`match` 语句（3.10）；`dataclass(slots=True)`（3.10）；`type` 别名与 `def f[T](x: T)`（3.12，PEP 695）。核对 `requires-python`。
- `if x:` 与 `if x is not None:` 在 `0`、`''`、`[]` 上结果不同，不互换。
- `d.get(k, compute())` 无论命中与否都求值 `compute()`；改成 `d.setdefault` 还会写入字典——三者副作用都不同。
- 列表推导改生成器表达式后只能迭代一次，`len()` 与二次遍历会失败。
- 可变默认参数 `def f(items=[])` 是 bug 而非风格，修复它是行为变化，要单独说明。

### Rust

- `unwrap()` 改 `?` 是把 panic 变成错误返回，调用方需要处理新的 `Err`，属于行为变化，单独列出。
- `let-else`（1.65）、`if let ... && ...` let chains（1.88，仅 edition 2024）、`matches!` 宏；核对 `rust-version` 与 `edition`。
- `.clone()` 删除前确认所有权：能编译就等价，编译失败说明原 clone 是必要的。
- 迭代器链是惰性求值，`collect()` 才分配；把带 `break` 的 `for` 改成 `.find()`/`.any()` 等价，改成 `.filter().count()` 会遍历全部。

### Lua / OpenResty（OpenResty 细节见 openresty-patterns）

- 循环内 `s = s .. x` 是 O(n²)，改 `table.concat` 是等价且更快；结果顺序与分隔符要逐字核对。
- `#t` 对有 `nil` 洞的表结果未定义，`ipairs` 在第一个 `nil` 停止，`pairs` 无序遍历全部——三者不互换。
- 全局变量改 `local` 缓存（`local insert = table.insert`）在 PUC Lua 收益明显，LuaJIT 下差异小；但把可被外部替换的全局函数缓存成 local 会改变热更新语义。
- `pcall` 包裹范围不扩大也不缩小；把多个 `pcall` 合成一个会丢失中间错误的定位。

## 审查清单

- [ ] 简化前后测试各跑一次，结果已贴出，且用例数与通过数相同
- [ ] 被改的关键函数有对比测试或快照对比，输入覆盖空值/零值/负值/极大值/重复值/元字符
- [ ] 每处改动写明理由与等价性依据；有争议的标"可选"
- [ ] 并发、金融精度、错误路径、安全校验、性能写法、时区、序列化契约七类禁区已逐条比对，禁区内只改命名与注释
- [ ] 集合链/推导式/迭代器替换已说明内存与求值顺序变化，热路径附 benchmark 或标"未测性能"
- [ ] 使用的新特性标注了最低版本并核对了项目声明版本
- [ ] 没有新增依赖、没有删除错误检查、没有合并语义不同的分支
- [ ] 语义变化的"修复"（可变默认参数、`unwrap` → `?`、`||` → `??`）与纯简化分开列出
