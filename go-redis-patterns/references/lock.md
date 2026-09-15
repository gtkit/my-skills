# 分布式锁（单节点）

- 加锁 `SET key token NX PX ttl`，token 每次唯一，释放和续期用 Lua 比较 token 再操作；重试退避 `rand.N(backoff)` 全抖动、`backoff = min(backoff*2, 500ms)`（`math/rand/v2`，同文件 `Acquire`），固定间隔会让所有等待者同一时刻撞 Redis。`TryAcquire` 拒绝 `ttl ≤ 0`：go-redis `SetNX` 的 expiration 为 0 时发出的是不带 PX 的 `SET NX`，锁永不过期。
- 单节点锁的边界：主挂、从升主、锁没复制过去 → 两个持有者。只能靠资源侧校验（版本号 / fencing token）兜底，Redlock 是否解决问题见 go-cache-consistency。

```go
// Release 用不受调用方取消影响的 ctx：fn 跑到超时才返回时 ctx 已取消，用它释放必失败，锁泄漏到 TTL。
func (l *Lock) Release(ctx context.Context) error {
	ctx, cancel := context.WithTimeout(context.WithoutCancel(ctx), 2*time.Second)
	defer cancel()
	n, err := releaseScript.Run(ctx, l.rdb, []string{l.key}, l.token).Int64()
	if err != nil {
		return fmt.Errorf("release %s: %w", l.key, err)
	}
	if n == 0 {
		return ErrLockNotHeld
	}
	return nil
}
```

```go
// WithLock：看门狗每 ttl/3 续期；续期失败即取消 fn 的 ctx（fn 必须监听 ctx 停止写共享资源）。
// ErrLockNotHeld 一律作为硬错误返回，调用方必须按"临界区可能已重复执行"处理：告警、对账、补偿。
func WithLock(ctx context.Context, rdb redis.UniversalClient, key string, ttl time.Duration, fn func(ctx context.Context) error) error {
	if ttl < 100*time.Millisecond {
		return fmt.Errorf("lock %s: ttl %v too short for watchdog", key, ttl)
	}
	l, err := Acquire(ctx, rdb, key, ttl)
	if err != nil {
		return err
	}
	fnCtx, cancel := context.WithCancelCause(ctx)
	var wg sync.WaitGroup
	var wdErr error
	wg.Go(func() {
		t := time.NewTicker(ttl / 3)
		defer t.Stop()
		for {
			select {
			case <-fnCtx.Done():
				return
			case <-t.C:
				if e := l.extend(fnCtx); e != nil {
					if fnCtx.Err() != nil { // fn 已返回（cancel(nil)）或上游取消：不是锁丢失，不能报成 wdErr
						return
					}
					wdErr = e
					cancel(e)
					return
				}
			}
		}
	})
	err = fn(fnCtx)
	cancel(nil)
	wg.Wait() // wg.Wait 之后读 wdErr 才有 happens-before
	return errors.Join(err, wdErr, l.Release(ctx))
}
```
