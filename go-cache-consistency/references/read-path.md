# 读路径三件套：穿透、击穿、雪崩

| 问题 | 现象 | 对策 |
|---|---|---|
| 穿透 | 查不存在的 id，缓存永远 miss，每次打 DB；常见于恶意扫描 | 空值缓存（短 TTL 30s~5min）；id 空间可枚举时前置布隆过滤器（`bits-and-blooms/bloom`），误判率按 1% 设，只挡"一定不存在" |
| 击穿 | 单个热 key 过期瞬间，成百上千并发同时回源 | 进程内 `singleflight.Group` 单飞；跨实例极热 key 用逻辑过期：值里带过期时间，过期后返回旧值并异步重建 |
| 雪崩 | 大批 key 同秒过期，或 Redis 整体故障，DB 被打挂 | TTL 随机抖动；多级缓存；Redis 故障时回源限流 + 熔断到降级值（见 go-stability-engineering） |

```go
// GetOrLoad：击穿 → singleflight 单飞重建；穿透 → 空值短 TTL；雪崩 → TTL 抖动；Redis 故障 → 受限回源、不写回。
func GetOrLoad[T any](ctx context.Context, c *Cache, key string, ttl time.Duration, load Loader[T]) (T, error) {
	var zero T
	if ttl <= 0 { // go-redis Set：expiration 0 不带 EX/PX（永不过期），-1 是 KEEPTTL，都违反"每个 key 必须有 TTL"
		return zero, fmt.Errorf("cache %s: ttl %v must be positive", key, ttl)
	}
	raw, err := c.rdb.Get(ctx, key).Result()
	switch {
	case err == nil && raw == nullMarker:
		return zero, ErrNotFound
	case err == nil:
		var v T
		if json.Unmarshal([]byte(raw), &v) == nil {
			return v, nil
		}
		// 解码失败（结构体改版残留）按 miss 重建，不报错
	case !errors.Is(err, redis.Nil):
		logger.WarnCtx(ctx, "redis get failed, fallback to loader", zap.String("key", key), zap.Error(err))
	}
	redisDown := err != nil && !errors.Is(err, redis.Nil)

	v, err, _ := c.sf.Do(key, func() (any, error) {
		if err := c.sem.Acquire(ctx, 1); err != nil {
			return nil, err
		}
		defer c.sem.Release(1)
		v, err := load(ctx)
		if errors.Is(err, ErrNotFound) {
			if !redisDown {
				c.set(ctx, key, nullMarker, c.nullTTL)
			}
			return nil, ErrNotFound
		}
		if err != nil {
			return nil, err
		}
		if !redisDown { // Redis 已故障时不再写回：大概率再等一个超时
			if data, merr := json.Marshal(v); merr == nil {
				c.set(ctx, key, string(data), jitter(ttl))
			}
		}
		return v, nil
	})
	if err != nil {
		return zero, err
	}
	return v.(T), nil
}
```

```go
// jitter：ttl × [0.9, 1.1)，同批写入的 key 不在同一秒集体过期。
func jitter(ttl time.Duration) time.Duration {
	if ttl < 10*time.Millisecond { // rand.N(0) 会 panic；这么短的 TTL 也没有抖动的意义
		return ttl
	}
	return ttl*9/10 + rand.N(ttl/5)
}
```

- `singleflight` 的 leader ctx 取消会让所有等待者一起失败；请求超时紧的路径用 `DoChan` 加自己的超时，或给 loader 用 `context.WithoutCancel`。它只在进程内去重，N 个副本仍有 N 次回源，可接受。
- `sem` 限制的是回源总并发（如 50），Redis 故障期间 DB 最多承受这个并发，多余请求等待或按 ctx 超时失败，比全部穿透可控。
- 空值哨兵不能和合法值撞：`"\x00null"` 不是合法 JSON。记录被创建后，写路径的 Del 顺带清掉空值，不会一直返回"不存在"。

反例（无保护，四个问题全占）：

```go
// 反例：无保护的 GetOrSet。
// 击穿：热 key 过期瞬间 N 个并发全部回源；穿透：不存在的 id 每次都打 DB；
// 雪崩转移：Redis 故障时 err 被当 miss，全部请求静默打到 DB；同批 key 同 TTL 同秒过期。
func GetOrSet[T any](ctx context.Context, rdb redis.UniversalClient, key string, ttl time.Duration, load func() (T, error)) (T, error) {
	var v T
	if data, err := rdb.Get(ctx, key).Bytes(); err == nil && json.Unmarshal(data, &v) == nil {
		return v, nil
	}
	v, err := load()
	if err != nil {
		return v, err
	}
	data, _ := json.Marshal(v)
	rdb.Set(ctx, key, data, ttl)
	return v, nil
}
```
