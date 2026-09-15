# 隔仓与背压

```go
// Do 的三段：满且队列满 → 立即拒绝（快速失败，让上游熔断/降级），否则排队到拿到槽位或 ctx 超时。
func (b *Bulkhead) Do(ctx context.Context, fn func(ctx context.Context) error) error {
	if !b.sem.TryAcquire(1) {
		if b.waiting.Add(1) > b.maxQueue {
			b.waiting.Add(-1)
			return ErrOverloaded // 有界队列：无界排队只是把超时从下游搬到本服务
		}
		err := b.sem.Acquire(ctx, 1)
		b.waiting.Add(-1)
		if err != nil {
			return err // ctx 超时/取消：等待期间已耗掉预算，不再调用下游
		}
	}
	defer b.sem.Release(1)
	return fn(ctx)
}
```

```go
func (s *Shedder) Admit(p Priority) (release func(), ok bool) {
	n := s.inflight.Add(1)
	if (n > s.hard && p < Critical) || (n > s.soft && p == Low) {
		s.inflight.Add(-1)
		return nil, false
	}
	return func() { s.inflight.Add(-1) }, true
}
```

构造函数与 `retry.Policy` 一样 fail-closed：`New(limit, maxQueue)` 在 `limit <= 0`（TryAcquire 永远失败、Acquire 阻塞到 ctx 超时，现象是"下游没挂但本服务全 504"）或 `maxQueue < 0` 时返回 `ErrInvalidLimits`；`NewShedder(soft, hard)` 在 `soft <= 0` 或 `hard < soft`（优先级反转：Normal 比 Low 先被拒）时返回 `ErrInvalidLevels`。`limit` ≈ 该下游连接池大小；`maxQueue` 取 limit 的 1~2 倍。无界排队只是把下游的慢搬到本服务：goroutine 与内存随排队增长，最终整体超时而不是局部失败。负载卸载的优先级要在入口就定（header 或路由），过载时先丢预取、埋点、推荐，保住下单、支付。
