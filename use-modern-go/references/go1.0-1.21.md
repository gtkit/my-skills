# Go 1.0–1.21 特性速查

## Go 1.0–1.20（基础）

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

## Go 1.21

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
