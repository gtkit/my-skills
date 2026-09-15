# Go 1.25–1.27 特性速查

## Go 1.25

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

## Go 1.26

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

## Go 1.27（最新）

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
