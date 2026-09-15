---
name: use-modern-go
description: 现代 Go 写法的单一真源（目标 Go 1.27）：每个旧写法到新写法的条目标注版本，附审查清单。编写、审查或重构任何 Go 代码时使用；按 references 只读项目 go.mod 版本相关的部分。
---

# Modern Go Guidelines

现代 Go 写法的单一真源：每个条目标注引入版本，`go doc` 可核实。日志与可观测性实现见 go-observability，并发模式见 go-concurrency，测试组织见 go-testing。

## 目标 Go 版本

**默认目标版本：Go 1.27。** 用户给出 `go.mod` 或明确指定版本时以用户为准。语言版本由 `go.mod` 的 `go` 指令决定，不是工具链版本：`go 1.25` 的模块即便用 go1.27 编译，写 `new(30)` 也会报 `new(30) requires go1.26 or later`（Go 1.27 实测）；`go vet` 的 `stdversion` 分析器会报告"引用了比模块 go 版本更新的标准库符号"。

## 核心原则

1. 使用目标版本及以下的全部现代特性，不使用已有现代替代的旧写法。
2. 不使用高于目标版本的特性；每条建议标注最低版本。
3. 优先标准库 `slices` / `maps` / `cmp` / `iter`，不手写循环实现查找、拷贝、排序、去重。
4. 日志使用 `github.com/gtkit/logger/v2`，字段构造器用 `go.uber.org/zap`（见 go-observability）。
5. review 或重构时主动指出可替换的旧模式，并说明替换后的行为差异（如 channel 容量、报错文本）。

## 各版本特性速查

逐版本条目按项目 `go.mod` 的 `go` 指令读取，只读覆盖到的版本段；下面的审查清单已汇总全部替换项。

| 任务 | 读 |
|---|---|
| 项目 go.mod ≤ 1.21，或核对基础写法（any、泛型、slices/maps、min/max/clear） | `references/go1.0-1.21.md` |
| 项目 go.mod 1.22–1.24（range int、迭代器、泛型别名、b.Loop、omitzero、os.Root） | `references/go1.22-1.24.md` |
| 项目 go.mod ≥ 1.25（wg.Go、synctest、json/v2、errors.AsType、new(expr)） | `references/go1.25-1.27.md` |

## 何时不该用 / 选型判断

| 场景 | 选择 | 理由 |
|---|---|---|
| 存量对外 API 依赖 v1 宽松语义（大小写不敏感、重复键覆盖） | 留在 `encoding/json`（v1） | v2 默认拒绝这些输入，切换等于契约变更；新服务或需要严格校验时用 v2 |
| 需要提前停止或 `Reset` 的定时器 | `time.NewTimer` / `NewTicker` + `Stop` | GC 只解决泄漏，不替你停止一个仍会触发的定时器；只在函数生命周期内用 `time.After` / `time.Tick` |
| 短命、低重复率的字符串 | 不用 `unique.Make` | 驻留表本身有全局 map 与哈希开销，只对大量重复且长存的值划算 |
| 需要确定性释放的资源（fd、锁） | 显式 `Close` / `defer`，不用 `AddCleanup` | cleanup 只保证"不可达之后某个时刻"运行，不保证时机与顺序 |
| 非 map/slice 的重置、切片需要缩容 | 不用 `clear`；用 `s[:0]` 或重新 `make` | `clear(slice)` 只把元素置零值，`len`/`cap` 不变 |
| 写多读多、key 频繁变化 | `map` + `sync.RWMutex`，不用 `sync.Map` | `sync.Map` 面向"只增不改、读多写少"的场景 |
| 方法级类型参数 vs 接口抽象 | 需要接口时用泛型函数或类型级参数 | Go 1.27 泛型方法不能出现在接口方法集中 |
| 只处理程序内部固定路径 | `filepath.Join` 即可 | `os.Root` 面向用户可控路径；它不阻止跨文件系统、`/proc` 与设备文件 |

## 代码审查清单

对照代码逐条核对，命中即指出并给出替换写法与所需最低版本：

1. `interface{}` → `any`（1.18）
2. `err == Sentinel` → `errors.Is`（1.13）；`var e *T; errors.As(err, &e)` → `errors.AsType[*T](err)`（1.26）
3. 手写 for 查找 / 包含 / 排序 / 去重 / 二分 / 插入删除 → `slices.*`（1.21）；手写 map 拷贝 / 合并 → `maps.*`（1.21）
4. `if a > b` 取大小值 → `min` / `max`；逐 key `delete` → `clear`（1.21）
5. `sync.Once` + 包装 → `sync.OnceFunc` / `OnceValue` / `OnceValues`（1.21）
6. 多层零值兜底 if → `cmp.Or`（1.22）
7. `for i := 0; i < n; i++`（步长 1）→ `for i := range n`；循环内 `i := i` 拷贝 → 删除（1.22）
8. `math/rand` + `rand.Seed` → `math/rand/v2`（1.22）；安全令牌 → `crypto/rand.Text`（1.24）
9. `sql.NullString` 一族 → `sql.Null[T]`（1.22）；`append(append(a, b...), c...)` → `slices.Concat`（1.22）
10. `for k := range m { keys = append(keys, k) }` + `sort` → `slices.Sorted(maps.Keys(m))`（1.23）；手写分批切片 → `slices.Chunk`（1.23）
11. `time.After` / `time.Tick` 因"泄漏"被禁、`defer t.Stop()` 只为防泄漏、`if !t.Stop() { <-t.C }` 排空 → 1.23 起均不必要
12. `context.Background()` 起后台任务丢 value → `context.WithoutCancel`（1.21）；`WithTimeout` 只能拿 `DeadlineExceeded` → `WithTimeoutCause` + `context.Cause`（1.21）
13. 测试内 `context.Background()` → `t.Context()`；`os.Chdir` + 手动还原 → `t.Chdir`（1.24）
14. `for i := 0; i < b.N; i++` → `for b.Loop()`；防优化 sink 变量 → 删除（1.24）
15. `strings.Split` + `for range` → `strings.SplitSeq` / `FieldsSeq` / `Lines`（1.24）
16. `omitempty` 用于 `time.Time` / `Duration` / struct → `omitzero`（1.24）
17. `filepath.Clean` + `HasPrefix` 防穿越 → `os.Root`（1.24）；`runtime.SetFinalizer` → `runtime.AddCleanup`（1.24）
18. `tools.go` 空导入 → `go.mod` `tool` 指令（1.24）
19. `wg.Add(1)` + `defer wg.Done()` → `wg.Go`（1.25）
20. 并发 / 定时逻辑测试里的 `time.Sleep` 真等 → `testing/synctest`（1.25）
21. `uber-go/automaxprocs` → 删除，依赖运行时容器感知（1.25，`go.mod` `go >= 1.25`）
22. 第三方 CSRF 中间件 → `http.CrossOriginProtection`（1.25）
23. 临时变量取地址 `x := 30; p := &x` → `new(30)`（1.26）；`ReverseProxy.Director` → `Rewrite`（1.26）
24. `strings.LastIndex` + 手工切片 → `strings.CutLast` / `bytes.CutLast`（1.27）
25. `github.com/google/uuid` → 标准库 `uuid`（1.27）
26. 需要严格 JSON 语义（拒绝重复键 / 大小写敏感 / 非法 UTF-8）→ `encoding/json/v2`（1.27），并核对 nil slice 编码差异
27. `httptest.NewServer` + `defer Close()` → `httptest.NewTestServer(t, h)`（1.27）；手写 `*url.URL` 复制 → `URL.Clone`（1.27）
28. `signal.Notify` + 手写退出 select → `signal.NotifyContext`（1.16）
29. 日志出现标准库 `log` 或非 gtkit 方案 → `github.com/gtkit/logger/v2` + `zap` 字段（见 go-observability）
