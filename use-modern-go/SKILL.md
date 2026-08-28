---
name: use-modern-go
description: 编写现代 Go 代码的强制性规范指南（目标 Go 1.27）。当用户编写任何 Go 代码、要求 Go 代码审查、Go 重构、Go 项目开发、或讨论 Go 语法和最佳实践时，必须触发此 skill。即使用户没有明确提到"modern"或"现代"，只要涉及 Go 代码生成、Go 代码片段、Go 函数编写、Go 项目架构，都应触发。关键词包括但不限于：Go、Golang、Go 代码、Go 开发、Go 重构、Go review、Go 最佳实践、Go 新特性、Go 1.21+、Go 1.22+、Go 1.23+、Go 1.24+、Go 1.25+、Go 1.26、Go 1.27、generics、iterator、range over func、slices、maps、synctest、json/v2。与 go-review 的分工：本 skill 是"旧写法 → 现代写法"的单一真源，go-review / go-enterprise-quality / senior-go-engineer 只引用本文件的审查清单。
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

### Go 1.0–1.20（基础）

| 版本 | 旧写法 | 现代写法 |
|---|---|---|
| 1.0 / 1.8 | `time.Now().Sub(start)` / `deadline.Sub(time.Now())` | `time.Since(start)` / `time.Until(deadline)` |
| 1.13 | `err == ErrNotFound` | `errors.Is(err, ErrNotFound)`（穿透 `%w` 包装） |
| 1.16 | `signal.Notify(ch, ...)` + 手写 `select` 退出 | `ctx, stop := signal.NotifyContext(ctx, os.Interrupt, syscall.SIGTERM)`；`defer stop()` |
| 1.18 | `interface{}` | `any` |
| 1.18 | `strings.Index` + 手工切片 | `strings.Cut(s, sep)` / `bytes.Cut` |
| 1.19 | `[]byte(fmt.Sprintf(...))` | `fmt.Appendf(buf, "x=%d", x)` |
| 1.19 | `atomic.StoreInt32` / `atomic.LoadPointer` | `atomic.Bool` / `atomic.Int64` / `atomic.Pointer[T]` |
| 1.18 / 1.20 | `string([]byte(s))` 手动拷贝 | `strings.Clone(s)`（1.18）/ `bytes.Clone(b)`（1.20） |
| 1.20 | `HasPrefix` + `TrimPrefix` 两步 | `strings.CutPrefix(s, "pre:")` / `CutSuffix` |
| 1.20 | 自定义多错误聚合 | `errors.Join(err1, err2)` |
| 1.20 | `WithCancel` + 自行记录取消原因 | `context.WithCancelCause(parent)` + `context.Cause(ctx)` |

```go
type Config struct{ Name string }

var (
	ready atomic.Bool
	cfg   atomic.Pointer[Config]
)

// 替代 atomic.StoreInt32 / atomic.StorePointer + unsafe.Pointer 转换：类型安全，零值即可用
func reload(c *Config) {
	cfg.Store(c)
	ready.Store(true)
}

func current() (*Config, bool) {
	return cfg.Load(), ready.Load()
}
```

### Go 1.21

| 旧写法 | 现代写法 |
|---|---|
| `if a > b { return a }; return b` | `max(a, b)` / `min(a, b)`（内建，可变参数） |
| `for k := range m { delete(m, k) }` | `clear(m)`；对 slice 是把 `len` 内元素置零值 |
| 手写 for + if 查找 / 排序 / 去重 | `slices.Contains` / `Index` / `IndexFunc` / `Sort` / `SortFunc` / `Max` / `Min` / `Reverse` / `Compact` / `Clip` / `Clone` |
| 手写二分、`append(s[:i], s[i+1:]...)` | `slices.BinarySearch(sorted, x)`、`slices.Insert(s, i, v...)`、`slices.Delete(s, i, j)`（`j > len(s)` 时 panic） |
| 手动迭代复制 / 合并 map | `maps.Clone(m)` / `maps.Copy(dst, src)` / `maps.DeleteFunc(m, pred)` |
| `sync.Once` + 包装函数 / 缓存变量 | `sync.OnceFunc(f)` / `sync.OnceValue(f)` / `sync.OnceValues(f)`（f panic 时每次调用重放同一 panic） |
| 起 goroutine 监听 `ctx.Done()` 做清理 | `stop := context.AfterFunc(ctx, cleanup)` |
| `WithTimeout` 后只能拿到 `DeadlineExceeded` | `context.WithTimeoutCause(parent, d, err)` / `WithDeadlineCause` → `context.Cause(ctx)` 返回自定义原因 |
| `context.Background()` 丢掉 value 起后台任务 | `context.WithoutCancel(parent)`：保留 value（trace_id 等），Done 为 nil、Err 恒为 nil |

```go
var errAuditTimeout = errors.New("audit: timeout")

// handler 返回后仍需继续的后台工作：WithoutCancel 切断取消链但保留 value（trace_id 等）。
// 生产环境优先投递队列；就地起 goroutine 时必须自带超时，否则是无界 goroutine。
func handle(w http.ResponseWriter, r *http.Request, audit func(context.Context) error) {
	bg := context.WithoutCancel(r.Context())
	go func() {
		ctx, cancel := context.WithTimeoutCause(bg, 5*time.Second, errAuditTimeout)
		defer cancel()
		if err := audit(ctx); err != nil {
			// context.Cause 拿到的是 errAuditTimeout，而不是笼统的 DeadlineExceeded
			logger.ErrorCtx(ctx, "audit failed", zap.Error(err), zap.NamedError("cause", context.Cause(ctx)))
		}
	}()
	w.WriteHeader(http.StatusAccepted)
}
```

### Go 1.22

- **`for i := range n`** 替代 `for i := 0; i < n; i++`；步长不为 1 时仍用三段式。
- **循环变量每次迭代独立**：`i := i` / `v := v` 这类拷贝不再需要，删掉。
- **`cmp.Or(a, b, "default")`** 替代多层 `if x == "" { x = ... }`：返回第一个非零值。
- **`math/rand/v2`** 替代 `math/rand`：无 `Seed`（进程启动自动播种）、`IntN` / `Int64N` / `N[T]`（泛型，`n <= 0` 时 panic）、`Shuffle`、`Perm`；顶层函数并发安全，`*rand.Rand` 不是。安全场景仍用 `crypto/rand`。
- **`slices.Concat(a, b, c)`** 替代 `append(append(a, b...), c...)`。
- **`sql.Null[T]{V, Valid}`** 替代 `sql.NullString` / `NullInt64` 一族与自定义 nullable 类型。
- **`reflect.TypeFor[T]()`** 替代 `reflect.TypeOf((*T)(nil)).Elem()`。
- **`http.ServeMux` 模式路由**：`mux.HandleFunc("GET /api/{id}", h)` + `r.PathValue("id")`。
- range-over-func 在 1.22 仅是 `GOEXPERIMENT=rangefunc`，1.23 才正式。

```go
// 无需 Seed：进程启动即随机播种，顶层函数并发安全。
// N 是泛型：直接对 Duration 取随机，替代 time.Duration(rand.Int63n(int64(d)))
func jitter(base time.Duration) time.Duration {
	if base < 2 { // base/2 == 0 时 rand.N 会 panic（n <= 0，Go 1.27 实测）
		return base
	}
	return base + rand.N(base/2) // [base, 1.5*base)
}

func pick[T any](items []T) T {
	return items[rand.IntN(len(items))] // n <= 0 时 panic，调用方保证非空
}
```

### Go 1.23

- **`iter.Seq[V]` / `iter.Seq2[K, V]` + range-over-func 正式可用**；`iter.Pull` 把 push 迭代器转成 `next()` 拉取。
- **slices 迭代器族**：`All` / `Values` / `Backward` / `Collect` / `Sorted` / `SortedFunc` / `Chunk(s, n)` / `Repeat`。
- **maps 迭代器族**：`Keys` / `Values` / `All` / `Collect` / `Insert`。`slices.Sorted(maps.Keys(m))` 一步拿到有序 key。
- **`unique.Make(v)`** 驻留（interning）comparable 值，`Handle` 比较是指针比较；大量重复长存字符串（host、标签）适用。
- **Timer / Ticker 未引用即可被 GC**：`time.After` / `time.Tick` 不再泄漏，`Stop()` 不再是防泄漏必需，只用于提前终止。Timer 的 channel 从容量 1 变为无缓冲（Go 1.27 实测 `cap(t.C) == 0`），`Stop` / `Reset` 之后不会再收到陈旧值，旧写法里 `if !t.Stop() { <-t.C }` 的排空可以删除。该行为要求 `go.mod` 的 `go >= 1.23`；回退开关 `asynctimerchan` 已在 Go 1.27 移除。

```go
// 自定义迭代器：惰性、支持 break、不分配中间 slice。
// yield 返回 false 后必须立即 return——再次调用 yield 会 panic。
// 步长不为 1 时仍用三段式 for（range n 只能步长 1）。
func Pages(total, size int) iter.Seq2[int, int] {
	return func(yield func(offset, limit int) bool) {
		if size <= 0 {
			return
		}
		for off := 0; off < total; off += size {
			if !yield(off, min(size, total-off)) {
				return
			}
		}
	}
}

// 分批写库：替代手写 ids[i:min(i+n, len(ids))] 的边界运算
func insertBatches(ids []int64, insert func([]int64) error) error {
	for chunk := range slices.Chunk(ids, 500) {
		if err := insert(chunk); err != nil {
			return err
		}
	}
	return nil
}
```

### Go 1.24

- **测试**：`t.Context()`（Cleanup 前自动取消）替代 `context.Background()`；`t.Chdir(dir)` 自动还原 cwd；`for b.Loop()` 替代 `for i := 0; i < b.N; i++`——自动排除 setup/cleanup 计时，循环体内的调用参数与结果被 KeepAlive，不再需要 sink 变量；`go vet` 新增 `tests` 分析器检查测试函数签名。
- **JSON `omitzero`**：对 `time.Time` / struct / 数组这类"零值编码后非空"的类型生效（`omitempty` 对它们无效；`time.Duration` 是 int64，`omitempty` 本就能省略 0，Go 1.27 实测），有 `IsZero()` 方法时按其判断。
- **Seq 变体**：`strings.SplitSeq` / `FieldsSeq` / `Lines`、`bytes.SplitSeq` / `FieldsSeq`，迭代时不分配中间 slice。
- **`os.Root`** 目录受限文件访问，替代手工 `filepath.Clean` + 前缀校验防路径穿越。
- **`runtime.AddCleanup(ptr, fn, arg)`** 替代 `SetFinalizer`：不复活对象、可多个、可 `Stop()`。
- **`weak.Pointer[T]`**（`weak.Make(p)` / `.Value()`）做不阻止回收的缓存引用。
- **`crypto/rand.Text()`** 直接生成 ≥128 位随机 base32 令牌，替代手写 `rand.Read` + 编码。
- **泛型类型别名** `type Set[T comparable] = map[T]struct{}`。
- **`go.mod` `tool` 指令**：`go get -tool <pkg>@v` 登记，`go tool <name>` 运行，替代 `tools.go` + 空导入。

```go
// 目录受限访问：name 含 ".." 或符号链接指向根外时返回错误
// "openat ../x: path escapes from parent"（Go 1.27 实测），替代 filepath.Clean + HasPrefix 手工校验
func readUpload(dir, name string) ([]byte, error) {
	root, err := os.OpenRoot(dir)
	if err != nil {
		return nil, err
	}
	defer root.Close()
	f, err := root.Open(name) // Root.ReadFile / WriteFile / MkdirAll / RemoveAll 为 Go 1.25 新增
	if err != nil {
		return nil, err
	}
	defer f.Close()
	return io.ReadAll(f)
}

type conn struct{ fd int }

// 替代 SetFinalizer：cleanup 与 arg 都不能引用 c 本身，否则 c 永远可达、cleanup 永不执行
// （arg == ptr 时 AddCleanup 直接 panic）
func newConn(fd int) *conn {
	c := &conn{fd: fd}
	runtime.AddCleanup(c, releaseFD, fd)
	return c
}

func releaseFD(fd int) { /* 归还连接池或 close(2) */ }
```

```go
type Config struct {
	Timeout time.Duration `json:"timeout,omitzero"` // Duration 是 int64，omitempty 也能省略 0；omitzero 语义更直接
	Since   time.Time     `json:"since,omitzero"`   // omitempty 对 Time/struct 不生效；有 IsZero() 方法时按其判断
}

func encode(ctx context.Context, c Config) ([]byte, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	return json.Marshal(c)
}

func TestEncode(t *testing.T) {
	ctx, cancel := context.WithTimeout(t.Context(), time.Second) // t.Context 在 Cleanup 之前自动取消
	defer cancel()
	if _, err := encode(ctx, Config{Timeout: time.Second}); err != nil {
		t.Fatal(err)
	}
}

func BenchmarkEncode(b *testing.B) {
	cfg := Config{Timeout: time.Second} // setup 不计时
	for b.Loop() {                      // 循环体内的调用结果自动 KeepAlive，不再需要 sink 变量
		_, _ = json.Marshal(cfg)
	}
}
```

### Go 1.25

- **`wg.Go(f)`** 替代 `wg.Add(1)` + `go func() { defer wg.Done(); ... }()`；`go vet` 新增 `waitgroup` 分析器。
- **`testing/synctest`**：`synctest.Test(t, f)` 在 bubble 内跑 f，bubble 内 `time` 为虚拟时钟；`synctest.Wait()` 等到其余 goroutine 全部阻塞。测超时、重试、防抖、定时器逻辑不再 `time.Sleep` 真等，也不再有 flaky 的"多等 50ms"。
- **容器感知 GOMAXPROCS**（`go.mod` `go >= 1.25` 生效）：默认取"逻辑 CPU 数、亲和掩码、cgroup CPU 配额"三者最小值，并周期性（≤1 次/秒）跟随 cgroup 变化；`uber-go/automaxprocs` 可以删掉。手动 `runtime.GOMAXPROCS(n)` 会关闭自动更新，`runtime.SetDefaultGOMAXPROCS()` 恢复。GODEBUG：`containermaxprocs=0` / `updatemaxprocs=0`。
- **`runtime/trace.NewFlightRecorder(cfg)`**：常驻环形 trace 缓冲，故障时 `WriteTo` 落盘最近 N 秒。
- **`t.Attr(key, value)`** 输出结构化测试属性（供 CI 解析）、**`t.Output()`** 取带缩进的 `io.Writer` 供被测代码写日志。
- **`net/http.CrossOriginProtection`**：标准库 CSRF 防护（基于 `Sec-Fetch-Site` / `Origin`），替代第三方 csrf 中间件；`os.Root` 补齐 `ReadFile` / `WriteFile` / `MkdirAll` / `RemoveAll` 等；`reflect.TypeAssert[T](v)` 替代 `v.Interface().(T)`；`go.mod` 新增 `ignore` 指令。

```go
// bubble 内 time 是虚拟时钟：Sleep 不真等，所有 goroutine 都阻塞时时钟才前进。
// 本测试 0.00s 跑完（Go 1.27 实测），替代用真实 time.Sleep 等并发结果的写法。
func TestFanOut(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		var hits atomic.Int32
		var wg sync.WaitGroup
		for range 3 {
			wg.Go(func() { // 替代 wg.Add(1) + go func() { defer wg.Done() }()
				time.Sleep(100 * time.Millisecond)
				hits.Add(1)
			})
		}
		synctest.Wait() // 等三个 goroutine 都阻塞在 Sleep 上
		if got := hits.Load(); got != 0 {
			t.Fatalf("hits before tick = %d, want 0", got)
		}
		time.Sleep(100 * time.Millisecond) // 推进虚拟时钟，三个 goroutine 同时醒来
		wg.Wait()
		if got := hits.Load(); got != 3 {
			t.Fatalf("hits = %d, want 3", got)
		}
	})
}
```

### Go 1.26

- **`new(expr)`**：`new` 接受表达式，返回指向该值的指针；无类型常量取默认类型。
- **`errors.AsType[T](err) (T, bool)`** 替代 `var e *T; errors.As(err, &e)`。
- **`testing.TB.ArtifactDir()`**：测试产物目录，`-artifacts` 时落到输出目录，否则测后自动删除。
- **`reflect.Type.Fields()` / `Methods()`、`reflect.Value.Fields()`** 返回迭代器，替代 `for i := 0; i < t.NumField(); i++`。
- **`bytes.Buffer.Peek(n)`** 不前进读指针地预读。
- **`httputil.ReverseProxy.Director` 标记废弃**：用 `Rewrite`（自动清理 hop-by-hop 与 `X-Forwarded-*` 头，Director 存在 IP 伪造风险）。

```go
type Patch struct { // 可选字段用指针区分"未传"与"零值"
	Timeout *int
	Debug   *bool
	Name    *string
}

// new 接受表达式并推断类型；无类型常量取默认类型（new(30) 是 *int）。不要写冗余的 new(int(0))
var defaultPatch = Patch{Timeout: new(30), Debug: new(true), Name: new("app")}

// 替代 var pe *os.PathError; errors.As(err, &pe)
func opOf(err error) string {
	if pe, ok := errors.AsType[*os.PathError](err); ok {
		return pe.Op
	}
	return ""
}
```

### Go 1.27（最新）

- **语言**：泛型方法（方法自带类型参数，接口中不能声明）；函数类型推断扩展到所有赋值上下文；结构体复合字面量的键可以是提升字段选择器（`Outer{X: 1}` 直接给嵌入字段赋值，Go 1.27 实测）。
- **`strings.CutLast` / `bytes.CutLast`** 从最后一个分隔符切分。
- **标准库 `uuid`**（`import "uuid"`）：`New`（等价 `NewV4`）/ `NewV7` / `Parse` / `MustParse` / `Nil()` / `Max()` / `Compare` / 文本 marshal，随机源为密码学安全随机数。
- **`encoding/json/v2` + `encoding/json/jsontext` 正式毕业**（不再需要 GOEXPERIMENT）；v1 `encoding/json` 改为 v2 实现，新增 `DefaultOptionsV1()` 等选项函数，`RawMessage` 成为 `jsontext.Value` 的别名。
- **`httptest.NewTestServer(t, h)`**：自动 `t.Cleanup(Close)`，默认走内存网络，替代 `NewServer` + `defer Close()`。
- **`url.URL.Clone()` / `url.Values.Clone()`** 深拷贝，替代手写复制。
- **`synctest.Sleep(d)`** 等价 `time.Sleep(d)` + `synctest.Wait()`。
- **`http.Server.MaxHeaderValueCount`**（默认 `DefaultMaxHeaderValueCount = 500`）限制请求头值个数；`math/rand/v2.(*Rand).N` 成为泛型方法；`hash/maphash.Hasher[T]` 让不可比较类型可做哈希表键。

```go
type List[E any] []E

// 泛型方法（Go 1.27）：方法自带类型参数。接口里不能声明泛型方法
// （编译报错 "interface method must have no type parameters"，Go 1.27 实测）
func (l List[E]) Map[F any](f func(E) F) List[F] {
	out := make(List[F], len(l))
	for i, x := range l {
		out[i] = f(x)
	}
	return out
}

// 替代 strings.LastIndex + 手工切片："archive.tar.gz" → "archive.tar", "gz", true
func splitExt(name string) (base, ext string, ok bool) {
	return strings.CutLast(name, ".")
}

// 替代 github.com/google/uuid：New/Parse/MustParse/String 签名一致；NewV7 在标准库只返回 UUID
// （google/uuid 返回 (UUID, error)），Nil/Max 是函数不是变量，迁移时这两处要改调用点
func newOrderID() string {
	return uuid.NewV7().String() // 时间有序，适合数据库主键；New() 等价 NewV4()
}
```

```go
type Order struct {
	ID    string   `json:"id"`
	Items []string `json:"items"` // v2 把 nil slice 编码为 []（v1 为 null）
}

// v2 默认比 v1 严格（Go 1.27 实测报错原文）：
//   重复字段名 → jsontext: duplicate object member name "id"
//   字段名大小写敏感："ID" 不再匹配 id，按未知字段处理
//   非法 UTF-8 → 拒绝，而不是替换成 U+FFFD
// 拒绝未知字段用选项 RejectUnknownMembers，不再靠 Decoder.DisallowUnknownFields
func decodeOrder(b []byte) (Order, error) {
	var o Order
	err := json.Unmarshal(b, &o, json.RejectUnknownMembers(true))
	return o, err
}
```

json/v2 与 v1 默认行为差异（`go doc encoding/json/v2` 与 Go 1.27 实测）：

| 行为 | v1 `encoding/json` | v2 `encoding/json/v2` | 回到 v1 行为的选项 |
|---|---|---|---|
| nil slice / map 编码 | `null` | `[]` / `{}` | `FormatNilSliceAsNull(true)` / `FormatNilMapAsNull(true)` |
| 重复字段名 | 后者覆盖 | 报错 `jsontext: duplicate object member name` | `jsontext.AllowDuplicateNames(true)` |
| 字段名匹配 | 大小写不敏感 | 大小写敏感 | `MatchCaseInsensitiveNames(true)` |
| 非法 UTF-8 | 替换为 U+FFFD | 报错 `jsontext: invalid UTF-8` | `jsontext.AllowInvalidUTF8(true)` |
| `omitempty` 语义 | 省略 `false` / `0` / nil / 空 slice·map·string | 只省略编码后为 `null` / `""` / `{}` / `[]` 的值：`0` 与 `false` 不再省略，空 slice/map 仍省略（Go 1.27 实测）；Go 零值省略用 `omitzero` | `json.OmitEmptyWithLegacySemantics(true)`（v1 包）或 `DefaultOptionsV1()` 整体切回 |

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
