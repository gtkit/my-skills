# 重试与死信

```go
// Permanent 标记不可重试的错误（参数非法、业务规则拒绝、反序列化失败），实现 go-error-handling 的
// Retryable() 接口；生产代码直接复用那里的 Permanent() / IsRetryable()，这里只为示例自包含。
type Permanent struct{ Err error }

func (p Permanent) Error() string   { return p.Err.Error() }
func (p Permanent) Unwrap() error   { return p.Err }
func (p Permanent) Retryable() bool { return false }

// retryable：显式标记优先；未标记的错误（网络、超时、下游 5xx、死锁）默认可重试——
// 与 go-error-handling 的"默认不重试"相反，因为这里的重试有界且以死信收尾，误重试的代价只是几次退避。
func retryable(err error) bool {
	if r, ok := errors.AsType[interface {
		error
		Retryable() bool
	}](err); ok {
		return r.Retryable()
	}
	return true
}
```

```go
// WithRetry 把 handler 包成"有界重试 + 指数退避 + 死信"。重试在原分区原地进行，不破坏顺序；
// 退避期间该分区后续消息被阻塞，所以 maxAttempts 次退避总和必须远小于单条超时与 RebalanceTimeout（默认 60s）。
// 单条超时到期（ctx.Done）同样进死信：一条慢消息不能让消费者退出重启、无限重放。
func WithRetry(h Handler, dlq *DLQ, maxAttempts int, base time.Duration) Handler {
	maxAttempts, base = max(maxAttempts, 1), max(base, time.Millisecond) // 0/负值：至少调一次 handler；rand.N(0) 会 panic
	return func(ctx context.Context, rec *kgo.Record) error {
		var err error
		for attempt := 1; ; attempt++ {
			if err = safeCall(h, ctx, rec); err == nil {
				return nil
			}
			if !retryable(err) || attempt == maxAttempts {
				break
			}
			select {
			case <-time.After(base<<(attempt-1) + rand.N(base)): // 指数退避 + 抖动，避免同批消息同时重试
			case <-ctx.Done():
				err = fmt.Errorf("%w（最后一次错误: %w）", context.Cause(ctx), err)
			}
			if ctx.Err() != nil {
				break
			}
		}
		// 死信用独立 ctx：走到这里 ctx 可能已因单条超时到期。写失败必须上抛——此时不能提交位点，否则消息就丢了
		dctx, cancel := context.WithTimeout(context.WithoutCancel(ctx), 5*time.Second)
		defer cancel()
		if derr := dlq.Send(dctx, rec, maxAttempts, err); derr != nil {
			return fmt.Errorf("死信写入失败（原错误 %v）: %w", err, derr)
		}
		return nil
	}
}

// safeCall 把 handler 的 panic 转成 Permanent 错误：panic 是代码 bug，重试也不会好，直接进死信。
func safeCall(h Handler, ctx context.Context, rec *kgo.Record) (err error) {
	defer func() {
		if r := recover(); r != nil {
			err = Permanent{Err: fmt.Errorf("panic: %v", r)}
		}
	}()
	return h(ctx, rec)
}
```

- 分类先于重试：反序列化失败、参数非法、业务规则拒绝是 Permanent，重试 100 次结果一样，直接进死信；网络、超时、5xx、死锁可重试。判定走 `Retryable() bool` 接口（go-error-handling），MQ 侧对未标记错误默认重试，因为重试有界且以死信收尾。
- 原地重试保顺序但阻塞该分区后续消息：`maxAttempts` 次退避总和必须小于单条超时；单条超时到期也进死信让位点前进，死信写入用 `WithoutCancel` + 独立超时——否则一条慢消息就让消费者退出重启、无限重放同一条。
- `DLQ.Send` 原样转存 Key/Value，头里追加 `x-origin-topic/partition/offset`、`x-attempts`、`x-error`；重放工具按头回放到原 topic，不直接改 DB。
- RocketMQ 把这套做在服务端：返回 `consumer.ConsumeRetryLater` 进 `%RETRY%<group>` 按延迟等级递增重投，客户端 `MaxReconsumeTimes` 默认 -1 即取 16 次（源码）后进 `%DLQ%<group>`；顺序消费返回 `SuspendCurrentQueueAMoment` 原地重试。NATS：`Nak()` 立即重投、`NakWithDelay`、`Term()` 终止投递，`MaxDeliver` 配 `BackOff` 列表。RabbitMQ：`Nack(requeue=false)` 进 DLX，quorum 队列用 `x-delivery-limit` 限次。
