# Go 1.22–1.24 特性速查

## Go 1.22

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

## Go 1.23

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

## Go 1.24

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
