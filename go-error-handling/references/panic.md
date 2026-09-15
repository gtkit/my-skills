# panic 边界

| 位置 | 谁兜底 | 不兜底的后果 |
|---|---|---|
| Gin handler 链 | `Recovery` 中间件（见 go-gin-api） | 500 + 栈 |
| handler 内 `go func(){}` | 自己 `recover` | **进程退出**，所有在途请求 502 |
| `errgroup.Group.Go` | `Protect` 包装 | 进程退出（x/sync v0.22.0 明确不传播 panic） |
| MQ 消费回调 / cron 任务 | 框架 recover 或 `Protect` | 消费者停摆、消息积压 |
| library 代码 | 不 panic，返回 error | 调用方无法预期 |

```go
// Go 是自起 goroutine 的唯一入口：handler 里 `go func(){...}()` 一旦 panic，gin.Recovery 管不到，进程直接退出。
func Go(ctx context.Context, task string, fn func(ctx context.Context) error) {
	go func() {
		defer func() {
			if r := recover(); r != nil {
				logger.ErrorCtx(ctx, "goroutine panic", zap.String("task", task), zap.Any("panic", r), zap.Stack("stack"))
			}
		}()
		if err := fn(ctx); err != nil {
			logger.ErrorCtx(ctx, "task failed", zap.String("task", task), zap.Error(err))
		}
	}()
}

// Protect 把 panic 转成 error，供 errgroup / MQ 消费回调 / cron 任务使用。
// x/sync v0.22.0 的 errgroup 明确不传播 panic（见其源码注释），worker 内 panic 同样会杀进程。
func Protect(fn func() error) func() error {
	return func() (err error) {
		defer func() {
			if r := recover(); r != nil {
				err = fmt.Errorf("panic: %v\n%s", r, debug.Stack())
			}
		}()
		return fn()
	}
}
```

用法：`g.Go(panics.Protect(func() error { return do(ctx, id) }))`；MQ 消费回调同样用 `Protect` 包一层再交给 SDK。
