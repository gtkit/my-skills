# 超时预算传播

```go
// Remaining 返回 ctx 剩余预算；无 deadline 时返回 fallback。
func Remaining(ctx context.Context, fallback time.Duration) time.Duration {
	dl, ok := ctx.Deadline()
	if !ok {
		return fallback
	}
	return time.Until(dl)
}

// ForHop 为一次下游调用派生 ctx：取 min(剩余预算 - reserve, hopMax)。
// reserve 是留给本服务在下游返回后继续工作（写 DB、序列化响应）的时间；
// 剩余不足时直接失败，不发起注定超时的调用。返回 err 时 ctx 与 cancel 都是 nil：
// 调用方必须先判 err 再 defer cancel()，写成 ctx, cancel, err := ...; defer cancel() 会 panic。
func ForHop(ctx context.Context, hopMax, reserve time.Duration, hop string) (context.Context, context.CancelFunc, error) {
	rem := Remaining(ctx, hopMax) - reserve
	if rem <= 0 {
		return nil, nil, ErrBudgetExhausted
	}
	timeout := min(rem, hopMax)
	cctx, cancel := context.WithTimeoutCause(ctx, timeout, errors.New("hop timeout: "+hop))
	return cctx, cancel, nil
}

// Inject 把当前 ctx 的 deadline 写入出站 HTTP 头。
func Inject(ctx context.Context, req *http.Request) {
	if dl, ok := ctx.Deadline(); ok {
		req.Header.Set(HeaderDeadline, strconv.FormatInt(dl.UnixMilli(), 10))
	}
}
```

传绝对时刻而不是剩余时长：网络与排队耗掉的时间不会被下游"重新计时"。`Extract` 只缩短不放大——上游给的截止晚于本地默认时以本地为准。超时值怎么定、每层留多少 reserve 见 go-stability-engineering。
