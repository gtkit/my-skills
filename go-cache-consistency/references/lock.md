# 分布式锁：Redlock、fencing token 与选型

- 单节点 Redis 锁的丢锁：主写入锁后未复制即宕机，从升主上没有这把锁，第二个客户端拿到同名锁。Redlock 用 N（≥3、奇数）个独立主节点、多数派成功、扣除获取耗时后的剩余有效期，解决的是"单点丢锁"。
- Kleppmann（2016，How to do distributed locking）的批评：① 锁有效期依赖各节点时钟不跳变，NTP 回拨、VM 暂停都能让锁提前失效；② 客户端 GC 停顿、网络延迟可让"持锁写入"发生在锁过期之后，而客户端不知道；③ 锁服务不下发单调递增的 fencing token，资源侧无法拒绝过期持有者的写。antirez 的回应承认 ① 依赖有界时钟漂移假设。结论：Redlock 适合"效率"目的（避免重复计算、防重复任务），不适合"正确性"目的（不能重复扣款）。
- fencing token：每次加锁拿到单调递增编号（ZooKeeper zxid、etcd revision），带着它写资源，资源侧 `WHERE fence < ?` 拒绝更小的 token。DB 场景等价做法是乐观锁 `WHERE version = ?`（见 go-data-consistency），此时 Redis 锁只是减少冲突的优化。
- 只能用强一致锁的场景：跨服务互斥且资源侧无法做条件写（调第三方接口、发短信、文件系统）——用 etcd `concurrency.Mutex` / ZooKeeper，接受更高延迟。
- `redsync` 适用边界：3/5 个独立单机 Redis（不是一个 Cluster、不是主从）；默认过期 8s、重试 32 次、时钟漂移因子 0.01（redsync v4.17.0 `redsync.go` 默认值）；临界区必须在 `mu.Until()` 前完成，超过就当作没拿到锁。

```go
// WithMutex：临界区必须在 mu.Until() 之前完成写入；超过即视为锁已失效，结果不可信。
func WithMutex(ctx context.Context, rs *redsync.Redsync, name string, fn func(ctx context.Context) error) error {
	mu := rs.NewMutex(name, redsync.WithExpiry(8*time.Second), redsync.WithTries(3))
	if err := mu.LockContext(ctx); err != nil {
		return fmt.Errorf("redlock %s: %w", name, err)
	}
	defer func() {
		ok, err := mu.UnlockContext(context.WithoutCancel(ctx))
		if err != nil || !ok {
			logger.WarnCtx(ctx, "redlock unlock failed", zap.String("name", name), zap.Bool("ok", ok), zap.Error(err))
		}
	}()
	fnCtx, cancel := context.WithDeadline(ctx, mu.Until())
	defer cancel()
	if err := fn(fnCtx); err != nil {
		return err
	}
	if time.Now().After(mu.Until()) {
		return fmt.Errorf("redlock %s: expired before critical section finished", name)
	}
	return nil
}
```
