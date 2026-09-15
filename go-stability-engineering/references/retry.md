# 重试

```go
// Policy 的零值不可用；Do 对非法配置直接报错而不是退化成"零退避紧循环"。
type Policy struct {
	MaxAttempts int           // 含首次；3 表示最多重试 2 次
	BaseDelay   time.Duration // 首次退避，如 100ms
	MaxDelay    time.Duration // 单次退避上限；无上限时 1<<attempt 在几十次后溢出、等待变成分钟级
	Budget      *rate.Limiter // 全进程共享：重试流量 ≤ 正常流量的 10%，如 rate.NewLimiter(qps*0.1, qps*0.1)
}
```

```go
// backoff 返回第 attempt 次（从 0 起）重试前的等待：指数 + 全抖动，再压到 MaxDelay。
func (p Policy) backoff(attempt int, err error) time.Duration {
	if ra, ok := errors.AsType[RetryAfter](err); ok && ra.RetryAfter() > 0 {
		return min(ra.RetryAfter(), p.MaxDelay) // 尊重下游给的 Retry-After
	}
	exp := p.BaseDelay << min(attempt, 16) // 限制移位位数；BaseDelay 本身很大时仍会溢出成负数
	d := min(exp, p.MaxDelay)
	if d <= 0 { // 溢出兜底：rand.Int64N(0) 与负数都会 panic（Go 1.27 实测）
		d = p.MaxDelay
	}
	return time.Duration(rand.Int64N(int64(d))) // 全抖动 [0, d)：同一时刻失败的请求不会同一时刻重试
}
```

```go
// Do 只在一层做重试：客户端、网关、服务各重试 3 次会放大成 27 倍流量。
func Do[T any](ctx context.Context, p Policy, fn func(ctx context.Context) (T, error)) (T, error) {
	var zero T
	if p.MaxAttempts < 1 || p.BaseDelay <= 0 || p.MaxDelay <= 0 {
		return zero, ErrInvalidPolicy
	}
	var lastErr error
	for attempt := range p.MaxAttempts {
		if err := ctx.Err(); err != nil {
			return zero, errors.Join(err, lastErr) // 首次尝试前也检查：ctx 已取消就别发请求
		}
		if attempt > 0 && p.Budget != nil && !p.Budget.Allow() {
			return zero, errors.Join(ErrBudgetExhausted, lastErr)
		}
		v, err := fn(ctx)
		if err == nil {
			return v, nil
		}
		lastErr = err
		if !shouldRetry(err) || attempt == p.MaxAttempts-1 {
			break
		}
		t := time.NewTimer(p.backoff(attempt, err))
		select {
		case <-ctx.Done():
			t.Stop()
			return zero, errors.Join(ctx.Err(), lastErr)
		case <-t.C:
		}
	}
	return zero, lastErr
}
```

| 决策 | 规则 | 反面现象 |
|---|---|---|
| 重试位置 | 只在最靠近失败点的一层（通常是服务内对下游的调用） | 网关也重试：下游雪崩时流量按乘积放大 |
| 可重试判定 | 429/502/503/504、网络超时；4xx、500、校验失败、业务拒绝不重试；连接重置、`io.ErrUnexpectedEOF` 由客户端层显式标记 `Retryable()` 后才重试 | 对 400 重试 3 次，日志里同一错误刷 4 遍 |
| 非幂等写 | 没有幂等键就不重试（幂等设计见 go-microservice） | 扣款重试成双扣 |
| 退避 | 指数 + 全抖动 + 上限；`rand.Int64N` 的参数 ≤ 0 会 panic，退避为 0 与左移溢出为负都要防 | 无抖动：同一秒失败的请求同一秒重试，下游第二波尖峰 |
| 预算 | 全进程共享 `rate.Limiter`，重试 ≤ 10% | 无预算：下游越慢重试越多，正反馈 |
| `Retry-After` | 429/503 带该头时按头等待，不按自己的退避 | 忽略头继续打，触发对方封禁 |
| 熔断打开 | `ErrOpenState`/`ErrTooManyRequests` 直接走降级，不重试 | 重试抢光半开态探测名额，熔断永远合不上 |
