# 错误分类：可重试 / 永久

```go
// errors.AsType 的类型参数必须满足 error，接口里要嵌入 error。
type retryable interface {
	error
	Retryable() bool
}

type permanent struct{ err error }

func (p *permanent) Error() string   { return p.err.Error() }
func (p *permanent) Unwrap() error   { return p.err }
func (p *permanent) Retryable() bool { return false }
func (p *permanent) Permanent() bool { return true } // 供熔断器：是确定性失败，不是下游故障

// Permanent 把一个本来会被判定为可重试的错误（如网络超时）标记为不可重试，
// 用于"已经知道重试无意义"的场景：签名错误、余额不足、下游明确返回 4xx。
func Permanent(err error) error {
	if err == nil {
		return nil
	}
	return &permanent{err: err}
}

// IsRetryable 是重试器唯一应该调用的判定函数。
// 优先级：ctx 取消（调用方已放弃，永不重试）> 显式标记（Permanent / AppError.Retryable）> net.Error 超时 > 默认不重试。
// 取消必须排在标记之前：带可重试标记却包着 context.Canceled 的错误，重试是在给没人等的请求耗资源。
func IsRetryable(err error) bool {
	if err == nil || errors.Is(err, context.Canceled) {
		return false
	}
	if r, ok := errors.AsType[retryable](err); ok {
		return r.Retryable()
	}
	if ne, ok := errors.AsType[net.Error](err); ok && ne.Timeout() {
		return true
	}
	return false
}
```

`AppError.Retryable()` 仅对 429/502/503/504 返回 true；`AppError.Permanent()` 对 4xx（429 除外）返回 true，供 go-stability-engineering 的熔断器 `IsSuccessful` 把"下游正常拒绝"从失败计数里剔除，5xx 与 429 仍计失败。`Permanent` 包在外层，`AsType` 深度优先先命中它、覆盖内层判定；带可重试标记却包着 `context.Canceled` 的错误不重试（均有 `TestFromAndRetryable` 反证）。`context.DeadlineExceeded` 与 `net.timeoutError`（dial 超时）都满足 `net.Error` 且 `Timeout()` 为 true，`IsRetryable` 视为超时类可重试；是否真的重试由重试器按调用方 `ctx.Err()` 与剩余预算决定，见 go-stability-engineering。
