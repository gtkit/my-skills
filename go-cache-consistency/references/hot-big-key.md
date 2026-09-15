# 热 key 与大 key

## 热 key

- 检测：`redis-cli --hotkeys` 与 `OBJECT FREQ key` 都要求 `maxmemory-policy` 为 LFU，否则报 `ERR An LFU maxmemory policy is not selected, access frequency not tracked`（Redis 8.0.0 实测）；不想改策略就在客户端 Hook 里按 key 采样计数上报。
- 本地二级缓存：选 `maypok86/otter/v2`——`Set` 同步可见、泛型 API、`Get(ctx, key, loader)` 对同一 key 的并发加载自动合并（`go doc otter.Cache.Get`）、`Logger` 可注入。`ristretto` 的 `Set` 是异步写缓冲，文档写明 "the Set was dropped" 的可能，需要 `Wait()` 才对后续 `Get` 可见，做失效时不好推理。
- 分片读：热 key 复制 n 份 `key:0..n-1`，写用 pipeline 全写，读随机一份；单 key 的 QPS 摊到 n 个 slot/节点。库存类热 key 用分段库存：`stock:sku:{id}:0..n`，扣减随机选段，不足换段，最后汇总。

```go
func New(rdb redis.UniversalClient, channel string) *TwoLevel {
	return &TwoLevel{
		l1: otter.Must(&otter.Options[string, []byte]{
			MaximumSize:      10_000,
			ExpiryCalculator: otter.ExpiryWriting[string, []byte](10 * time.Second), // 按写入时间过期：失效广播丢了最多脏 10s
			Logger:           otterLogger{},                                         // 不设则 otter 走标准库默认日志
		}),
		rdb: rdb, channel: channel,
	}
}
```

```go
// Get：L1 → L2。L1 不按访问续期——热 key 一直被读，按访问续期就永不过期、广播丢失后永远脏。
func (t *TwoLevel) Get(ctx context.Context, key string) ([]byte, bool, error) {
	if v, ok := t.l1.GetIfPresent(key); ok {
		return v, true, nil
	}
	v, err := t.rdb.Get(ctx, key).Bytes()
	if errors.Is(err, redis.Nil) {
		return nil, false, nil
	}
	if err != nil {
		return nil, false, fmt.Errorf("l2 get %s: %w", key, err)
	}
	t.l1.Set(key, v)
	return v, true, nil
}

// Invalidate：先删 L2 再广播删 L1。顺序反了，别的实例删完 L1 立刻从 L2 读回旧值。
func (t *TwoLevel) Invalidate(ctx context.Context, key string) error {
	if err := t.rdb.Del(ctx, key).Err(); err != nil {
		return fmt.Errorf("l2 del %s: %w", key, err)
	}
	t.l1.Invalidate(key)
	return t.rdb.Publish(ctx, t.channel, key).Err() // Pub/Sub at-most-once：断线实例收不到，靠 L1 短 TTL 兜底
}
```

```go
// ShardedGet：热 key 复制 n 份 key:0..n-1（写时 pipeline 全写），读随机一份，把单 key QPS 摊到 n 个槽。
func ShardedGet(ctx context.Context, rdb redis.UniversalClient, key string, n int) *redis.StringCmd {
	return rdb.Get(ctx, fmt.Sprintf("%s:%d", key, rand.IntN(max(n, 1)))) // n ≤ 0 时 IntN 会 panic
}
```

`ListenInvalidations`（同文件）每个实例订阅失效频道，收到 key 就 `l1.Invalidate`。Pub/Sub 断线期间的广播丢失，靠 L1 的 10s 写入过期兜底——这就是 L1 不能按访问续期、不能设长 TTL 的原因。

## 大 key

- 口径：String > 10KB、集合 > 5000 元素或 > 1MB。检测 `redis-cli --bigkeys`（生产可跑，基于 SCAN 采样）、`MEMORY USAGE key`。
- 治理：Hash 按字段 hash 分桶 `user:tags:{id}:0..15`；大 String 压缩或拆字段；List 用 `LTRIM` 限长；Stream `XADD MAXLEN ~`。
- 删除：`DEL` 百万元素集合阻塞主线程数百毫秒。`UNLINK` 把释放放到后台线程（4.0+），或 `lazyfree-lazy-user-del yes` 让 `DEL` 等价 `UNLINK`；集合类先分批缩小：

```go
// DeleteBigHash 渐进删除：HSCAN 分批 HDEL 缩小后再 UNLINK。
// 直接 DEL 百万字段的 hash 会阻塞主线程数百毫秒；UNLINK 只把释放放到后台线程，字段仍要逐个回收。
func DeleteBigHash(ctx context.Context, rdb redis.UniversalClient, key string) error {
	var cursor uint64
	for {
		fields, next, err := rdb.HScan(ctx, key, cursor, "*", 500).Result() // 返回 field,value 交错
		if err != nil {
			return fmt.Errorf("hscan %s: %w", key, err)
		}
		names := make([]string, 0, len(fields)/2)
		for pair := range slices.Chunk(fields, 2) {
			names = append(names, pair[0])
		}
		if len(names) > 0 {
			if err := rdb.HDel(ctx, key, names...).Err(); err != nil {
				return fmt.Errorf("hdel %s: %w", key, err)
			}
		}
		if cursor = next; cursor == 0 {
			break
		}
	}
	return rdb.Unlink(ctx, key).Err()
}
```
