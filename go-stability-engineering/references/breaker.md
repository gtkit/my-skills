# 熔断

```go
// New 为一个下游建一个熔断器；不同下游绝不共用，否则 A 挂了会把 B 也熔断。
func New[T any](name string) *gobreaker.CircuitBreaker[T] {
	return gobreaker.NewCircuitBreaker[T](gobreaker.Settings{
		Name:         name,
		MaxRequests:  5,                // 半开态放行数；0 表示只放 1 个
		Interval:     10 * time.Second, // 闭合态计数清零周期；0 表示永不清零
		BucketPeriod: time.Second,      // 滚动窗口，避免 Interval 边界上计数突然清零
		Timeout:      30 * time.Second, // 打开态持续时间；0 时库默认 60s
		ReadyToTrip: func(c gobreaker.Counts) bool {
			// 被 IsExcluded 排除的请求仍计入 Requests（gobreaker v2.4.0 实测），分母必须减掉，
			// 否则大量调用方取消会稀释失败率，该熔断时不熔断。
			effective := c.Requests - c.TotalExclusions
			if effective < 20 { // 先判样本数：QPS 低时 2/3 失败就是 66%，不是故障
				return false
			}
			return float64(c.TotalFailures)/float64(effective) >= 0.5
		},
		// 不设 IsSuccessful 时所有非 nil error 都算失败：调用方取消、下游 4xx 都会把熔断器打开。
		IsSuccessful: func(err error) bool {
			if err == nil {
				return true
			}
			p, ok := errors.AsType[Permanent](err)
			return ok && p.Permanent() // 下游正常工作并拒绝了请求，算下游"健康"
		},
		// 调用方取消不计入成功也不计入失败（gobreaker v2.4.0 起）
		IsExcluded: func(err error) bool { return errors.Is(err, context.Canceled) },
		OnStateChange: func(name string, from, to gobreaker.State) {
			logger.Warn("circuit breaker state changed", zap.String("name", name),
				zap.String("from", from.String()), zap.String("to", to.String()))
		},
	})
}
```

```go
// Call 统一处理两种拒绝：ErrOpenState（打开态）与 ErrTooManyRequests（半开态超过 MaxRequests）。
// 两者都应立刻走降级，绝不重试——重试会把半开态探测名额抢光。
func Call[T any](cb *gobreaker.CircuitBreaker[T], fn func() (T, error)) (T, error) {
	v, err := cb.Execute(fn)
	if errors.Is(err, gobreaker.ErrOpenState) || errors.Is(err, gobreaker.ErrTooManyRequests) {
		return v, errors.Join(ErrUnavailable, err)
	}
	return v, err
}
```

已验证的行为（gobreaker v2.4.0，Go 1.27 实测）：不设 `IsSuccessful` 时所有非 nil error 计失败；`IsExcluded` 排除的请求 `Requests` 仍加 1、`TotalExclusions` 加 1，比率分母必须用 `Requests - TotalExclusions`；半开态超过 `MaxRequests` 的并发调用立即得到 `ErrTooManyRequests`；半开态连续成功数达到 `MaxRequests` 才回到 closed 并清零计数，期间任一失败立刻重回 open；`Timeout` 为 0 时默认 60s，`MaxRequests` 为 0 时只放 1 个。`Permanent()` 由 go-error-handling 的 `*AppError`（4xx 且非 429）、`Permanent(err)` 包装以及 go-microservice 的 `StatusError` 实现；5xx、429、网络错误不实现或返回 false，计入失败。

何时不该用：QPS < 1 的下游，10s 窗口凑不齐 20 个样本，比率毫无统计意义，改用超时 + 降级；同一个熔断器包多个下游，一个挂全部熔断。
