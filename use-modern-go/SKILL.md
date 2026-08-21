---
name: use-modern-go
description: 编写现代 Go 代码的强制性规范指南（基于 JetBrains go-modern-guidelines 适配网页端）。当用户编写任何 Go 代码、要求 Go 代码审查、Go 重构、Go 项目开发、或讨论 Go 语法和最佳实践时，必须触发此 skill。即使用户没有明确提到"modern"或"现代"，只要涉及 Go 代码生成、Go 代码片段、Go 函数编写、Go 项目架构，都应触发。关键词包括但不限于：Go、Golang、Go 代码、Go 开发、Go 重构、Go review、Go 最佳实践、Go 新特性、Go 1.21+、Go 1.22+、Go 1.23+、Go 1.24+、Go 1.25+、Go 1.26、Go 1.27。
---

# Modern Go Guidelines（网页端适配版）

> 基于 [JetBrains/go-modern-guidelines](https://github.com/JetBrains/go-modern-guidelines)（Apache-2.0），适配 Claude.ai 网页端使用。

## 目标 Go 版本

**默认目标版本：Go 1.27**

如果用户在对话中提供了 `go.mod` 文件内容或明确指定了 Go 版本，则以用户指定的版本为准。否则始终使用 Go 1.27 作为目标版本。

## 核心原则

编写 Go 代码时，**必须**遵守以下规则：

1. **使用目标版本及以下所有可用的现代特性**，绝不使用已有现代替代方案的旧模式
2. **绝不使用高于目标版本的特性**
3. **优先使用标准库新增的包和函数**（`slices`、`maps`、`cmp` 等），而非手动循环或旧写法
4. 当用户粘贴了 Go 代码请求 review 或重构时，主动指出可以用现代写法替换的旧模式

---

## 各版本特性速查

### Go 1.0+

| 旧写法 | 现代写法 |
|--------|---------|
| `time.Now().Sub(start)` | `time.Since(start)` |

### Go 1.8+

| 旧写法 | 现代写法 |
|--------|---------|
| `deadline.Sub(time.Now())` | `time.Until(deadline)` |

### Go 1.13+

| 旧写法 | 现代写法 |
|--------|---------|
| `err == target` | `errors.Is(err, target)`（支持 wrapped errors） |

### Go 1.18+

| 旧写法 | 现代写法 |
|--------|---------|
| `interface{}` | `any` |
| `Index` + 手动切片 | `strings.Cut(s, sep)` / `bytes.Cut(b, sep)` |

### Go 1.19+

| 旧写法 | 现代写法 |
|--------|---------|
| `[]byte(fmt.Sprintf(...))` | `fmt.Appendf(buf, "x=%d", x)` |
| `atomic.StoreInt32` / `atomic.LoadInt32` | `atomic.Bool` / `atomic.Int64` / `atomic.Pointer[T]` |

```go
// ✅ 类型安全的原子操作
var flag atomic.Bool
flag.Store(true)
if flag.Load() { /* ... */ }

var ptr atomic.Pointer[Config]
ptr.Store(cfg)
```

### Go 1.20+

| 旧写法 | 现代写法 |
|--------|---------|
| 手动拷贝 string | `strings.Clone(s)` |
| 手动拷贝 []byte | `bytes.Clone(b)` |
| `strings.HasPrefix` + 手动截取 | `strings.CutPrefix(s, "pre:")` / `strings.CutSuffix` |
| 自定义多 error 合并 | `errors.Join(err1, err2)` |
| `context.WithCancel` + 手动传 cause | `context.WithCancelCause(parent)` + `context.Cause(ctx)` |

### Go 1.21+（重要版本）

**内建函数：**

| 旧写法 | 现代写法 |
|--------|---------|
| `if a > b { return a } else { return b }` | `max(a, b)` / `min(a, b)` |
| 手动循环删除 map 条目 | `clear(m)` |

**slices 包（替代手动循环）：**

```go
slices.Contains(items, x)        // 替代手动 for + if 判断
slices.Index(items, x)           // 返回 index，-1 表示未找到
slices.IndexFunc(items, predFn)  // 函数式查找
slices.SortFunc(items, cmpFn)    // 自定义排序
slices.Sort(items)               // 有序类型直接排序
slices.Max(items) / slices.Min(items)
slices.Reverse(items)
slices.Compact(items)            // 去连续重复
slices.Clip(s)                   // 去多余 cap
slices.Clone(s)                  // 复制
```

**maps 包：**

```go
maps.Clone(m)                    // 替代手动迭代复制 map
maps.Copy(dst, src)              // 合并 map
maps.DeleteFunc(m, predFn)       // 条件删除
```

**sync 包：**

```go
f := sync.OnceFunc(func() { /* ... */ })       // 替代 sync.Once + wrapper
getter := sync.OnceValue(func() T { return v }) // 惰性初始化
```

**context 包：**

```go
stop := context.AfterFunc(ctx, cleanup)              // cancel 时自动执行
ctx, cancel := context.WithTimeoutCause(parent, d, err)
```

### Go 1.22+

**循环改进：**

```go
// ✅ 新语法
for i := range n { /* ... */ }
// ❌ 旧语法
for i := 0; i < n; i++ { /* ... */ }
```

- 循环变量现在每次迭代独立拷贝，goroutine 中可安全捕获

**cmp.Or — 链式零值兜底：**

```go
// ✅ 现代写法
name := cmp.Or(os.Getenv("NAME"), config.Name, "default")
// ❌ 旧写法：多层 if name == "" 判断
```

**其他：**
- `reflect.TypeFor[T]()` 替代 `reflect.TypeOf((*T)(nil)).Elem()`
- `http.ServeMux` 增强：`mux.HandleFunc("GET /api/{id}", handler)` + `r.PathValue("id")`

### Go 1.23+

**迭代器生态：**

```go
keys := slices.Collect(maps.Keys(m))       // 替代手动 for k := range m { append }
sortedKeys := slices.Sorted(maps.Keys(m))  // 收集 + 排序一步到位
for k := range maps.Keys(m) { process(k) } // 直接迭代
```

**time.Tick 可安全使用：** Go 1.23 起 GC 可回收未引用的 ticker，不再需要 `NewTicker` + `defer Stop()`。

### Go 1.24+

**测试中用 `t.Context()`：**

```go
// ✅ 现代写法
func TestFoo(t *testing.T) {
    ctx := t.Context()
    result := doSomething(ctx)
}
// ❌ 旧写法：context.WithCancel(context.Background()) + defer cancel()
```

**JSON 标签用 `omitzero`：**

```go
// ✅ 对 time.Duration、time.Time、struct、slice、map 使用 omitzero
type Config struct {
    Timeout time.Duration `json:"timeout,omitzero"`
}
// ❌ omitempty 对 Duration 等类型不生效
```

**Benchmark 用 `b.Loop()`：**

```go
// ✅ 现代写法
func BenchmarkFoo(b *testing.B) {
    for b.Loop() {
        doWork()
    }
}
// ❌ 旧写法：for i := 0; i < b.N; i++
```

**字符串分割迭代用 Seq 变体：**

```go
// ✅ 迭代时使用 SplitSeq / FieldsSeq（无需分配中间 slice）
for part := range strings.SplitSeq(s, ",") {
    process(part)
}
// ❌ 旧写法：for _, part := range strings.Split(s, ",")
```

同理：`strings.FieldsSeq`、`bytes.SplitSeq`、`bytes.FieldsSeq`

### Go 1.25+

**`wg.Go()` 简化 goroutine 启动：**

```go
// ✅ 现代写法
var wg sync.WaitGroup
for _, item := range items {
    wg.Go(func() {
        process(item)
    })
}
wg.Wait()

// ❌ 旧写法：wg.Add(1) + go func() { defer wg.Done(); ... }()
```

### Go 1.26+

**`new(val)` — 直接获取值的指针：**

```go
// ✅ 现代写法：new() 可接受表达式，类型自动推断
cfg := Config{
    Timeout: new(30),    // *int
    Debug:   new(true),  // *bool
    Name:    new("app"), // *string
}

// ❌ 旧写法：声明临时变量再取地址
timeout := 30
cfg := Config{Timeout: &timeout}
```

注意：不要写冗余转换如 `new(int(0))`，直接 `new(0)` 即可。

**`errors.AsType[T]` — 类型安全的错误匹配：**

```go
// ✅ 现代写法
if pathErr, ok := errors.AsType[*os.PathError](err); ok {
    handle(pathErr)
}

// ❌ 旧写法
var pathErr *os.PathError
if errors.As(err, &pathErr) {
    handle(pathErr)
}
```

### Go 1.27+（最新）

**`strings.CutLast` / `bytes.CutLast` — 从最后一个分隔符切分：**

```go
// ✅ 现代写法
if base, ext, found := strings.CutLast(filename, "."); found {
    fmt.Println(base, ext) // "archive.tar" "gz"
}

// ❌ 旧写法：LastIndex + 手工切片，边界易错
if i := strings.LastIndex(filename, "."); i >= 0 {
    base, ext := filename[:i], filename[i+1:]
    _, _ = base, ext
}
```

**标准库 `uuid` — 不再需要第三方依赖：**

```go
// ✅ 现代写法：标准库直接提供
import "uuid"

id := uuid.New()        // 等价于 NewV4()，随机
ordered := uuid.NewV7() // 时间有序，适合做数据库主键
parsed, err := uuid.Parse(s)

// ❌ 旧写法：引入 github.com/google/uuid
```

调用签名与 `github.com/google/uuid` 一致（`New`/`Parse`/`MustParse`/`String`），
迁移通常只需改 import；另有 `Nil()`、`Max()`、`UUID.Compare` 与文本 marshal 方法。

**`encoding/json/v2` — 新 JSON 实现，默认可用（无需 GOEXPERIMENT）：**

```go
// ✅ 需要 v2 语义时
import json "encoding/json/v2"

b, err := json.Marshal(v)
err = json.Unmarshal(b, &v)

// 低层 token/文本处理用 encoding/json/jsontext
```

`encoding/json`（v1）保持向后兼容，其 `RawMessage` 现在是 `jsontext.Value` 的别名。
存量代码不必动；只在需要 v2 行为时显式导入 v2。

---

## 代码审查清单

当用户提交 Go 代码请求 review 时，主动检查以下项目：

1. `interface{}` → `any`
2. 手动 for 循环查找/包含 → `slices.Contains` / `slices.Index`
3. 手动 map 拷贝 → `maps.Clone`
4. `if a > b` 取大小值 → `min` / `max`
5. C 风格 for 循环 → `for i := range n`
6. `sync.Once` + 包装函数 → `sync.OnceFunc` / `sync.OnceValue`
7. `cmp.Or` 可替代的多层 if 零值判断
8. `strings.LastIndex` + 手工切片 → `strings.CutLast` / `bytes.CutLast`（Go 1.27）
9. `github.com/google/uuid` 依赖 → 标准库 `uuid`（Go 1.27）
10. 需要 v2 JSON 语义时 → `encoding/json/v2`（Go 1.27）
11. `errors.As` + 指针变量 → `errors.AsType[T]`（Go 1.26）
12. `new(val)` 可替代的临时变量取地址模式（Go 1.26）
13. `wg.Add(1)` + `go func() { defer wg.Done() }` → `wg.Go()`（Go 1.25）
14. `strings.Split` + for range → `strings.SplitSeq`（Go 1.24）
15. 测试中 `context.Background()` → `t.Context()`（Go 1.24）
16. benchmark 中 `for i := 0; i < b.N; i++` → `b.Loop()`（Go 1.24）
17. JSON tag `omitempty` 用于 Duration/Time/struct → `omitzero`（Go 1.24）
