---
name: go-cache-consistency
description: Go 服务的缓存一致性与缓存防护：Cache-Aside / Read-Through / Write-Behind 取舍、先更 DB 再删缓存的时序、延迟双删、binlog（Canal/Debezium）订阅失效、版本号防 ABA、缓存穿透（空值缓存、布隆过滤器）、击穿（singleflight、逻辑过期）、雪崩（TTL 抖动、多级缓存、降级限流）、热 key 与大 key 检测治理、本地缓存（otter）与多级缓存失效顺序、Redlock 争议与 fencing token、事务与缓存失效顺序。当用户提到缓存一致性、双删、延迟双删、缓存穿透、击穿、雪崩、布隆过滤器、singleflight、热 key、大 key、本地缓存、多级缓存、Redlock、fencing token、redsync 时触发。分工：go-redis 客户端用法、Lua、Pipeline、Streams 见 go-redis-patterns；DB 事务、乐观锁、outbox 见 go-data-consistency。
---

# Go 缓存一致性与防护

回答"缓存什么时候删、删失败怎么办、读会不会打穿 DB、锁到底靠不靠得住"。客户端 API 见 go-redis-patterns，DB 侧事务与 outbox 见 go-data-consistency。

## 核心规则

1. 缓存只能做到最终一致；需要读到刚写的值的路径直接读 DB，不要试图用缓存实现强一致。
2. 写路径默认 Cache-Aside：先提交 DB，再删缓存（不是更新缓存、不是先删再更）。
3. 缓存失效放在事务提交之后；事务内删缓存等于没删。
4. 删缓存失败不能吞：DB 已提交时，失效动作要进重试队列，binlog 订阅做最终兜底。
5. 每个 `GetOrLoad` 必配三件：`singleflight`（击穿）、空值短 TTL（穿透）、TTL 抖动（雪崩）；Redis 故障时回源必须限流，不能让全部请求打到 DB。
6. 热 key 先检测再治理：本地缓存按写入时间过期而不是按访问续期；分片读时写要全写。
7. 大 key（String > 10KB、集合 > 5000 元素）不能 `DEL`，要 `HSCAN`/`SSCAN` 分批缩小后 `UNLINK`。
8. Redis 锁（包括 Redlock）只做效率互斥；正确性靠资源侧的 fencing token / 版本条件更新，或改用 etcd/ZooKeeper/DB 锁。
9. 多级缓存失效顺序：先远端（L2）再本地（L1）再广播；本地缓存必须有短 TTL 兜底广播丢失。
10. 写多读少、数据量小到能全放内存、要求读己之写的场景，不加缓存。

## 写路径：怎么让缓存和 DB 一致

Cache-Aside 四种时序，只有"先更 DB 后删缓存"的脏窗口是毫秒级且可被延迟双删覆盖：

| 方案 | 并发下的问题 | 结论 |
|---|---|---|
| 先删缓存，再更新 DB | 删后、DB 提交前，读请求 miss → 读旧值 → 写回缓存；脏到下次失效 | 不用 |
| 先更新 DB，再更新缓存 | 写 A、写 B 到 DB 顺序 A→B，到缓存顺序 B→A，缓存永久停在 A；写多读少时白算 | 不用 |
| 先更新 DB，再删缓存 | 读请求在 DB 提交前查到旧值、在删之后才写回——需要"读比写慢"，窗口毫秒级 | 默认方案 |
| 延迟双删 | 提交后删一次，延迟 500ms~1s 再删一次，覆盖上面的窗口 | 补丁：延迟值凭经验，读请求 GC 停顿超过延迟仍会脏 |

```go
// UpdateName：先更 DB（提交），后删缓存，再投递延迟二删。
// 不"先删后更"：删完到提交之间并发读把旧值写回缓存，脏到下次失效。
// 不"更新缓存"：两个写请求 DB 顺序 A→B、缓存顺序 B→A，缓存永久停在 A。
// 不在事务内删：Del 后到 Commit 前的读把旧值写回，等于没删。
func (w Writer) UpdateName(ctx context.Context, id int64, name string) error {
	tx, err := w.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	if _, err := tx.ExecContext(ctx, `UPDATE users SET name = ?, version = version + 1 WHERE id = ?`, name, id); err != nil {
		return errors.Join(err, tx.Rollback())
	}
	if err := tx.Commit(); err != nil {
		return fmt.Errorf("commit: %w", err)
	}
	key := fmt.Sprintf("user:profile:%d", id)
	if err := w.rdb.Del(ctx, key).Err(); err != nil {
		// DB 已提交，不能回滚。脏窗口 = 缓存剩余 TTL，必须补偿：延迟队列重试 + binlog 订阅兜底
		logger.ErrorCtx(ctx, "cache invalidate failed", zap.String("key", key), zap.Error(err))
	}
	select {
	case w.delay <- key: // 延迟双删：覆盖"读请求在提交前查到旧值、在 Del 之后才写回"的窗口
	default:
		logger.WarnCtx(ctx, "delay-delete queue full", zap.String("key", key))
	}
	return nil
}
```

- 延迟任务投递到队列（本地 channel 只是示意）：`time.AfterFunc` 在发布重启时任务全丢；有 MQ 就用延迟消息。
- binlog 订阅（MySQL 用 Canal，MySQL/PG 用 Debezium）：消费 row 变更事件 → 按主键删 key。优点是覆盖所有写入口（DBA 脚本、批处理、别的服务），业务代码零侵入；代价是 ms~s 级延迟、需要按主键分区保序、消费者必须幂等。它是兜底，不是替代应用层删除。
- 版本号防 ABA：慢读请求拿着旧版本 DB 结果回来写缓存，会覆盖新值。缓存值携带 `version`（DB 行的 version 列或 `updated_at` 微秒），写回用 Lua 比较：

```go
var setIfNewer = redis.NewScript(`
local cur = redis.call('HGET', KEYS[1], 'v')
if cur and tonumber(cur) >= tonumber(ARGV[1]) then
  return 0
end
redis.call('HSET', KEYS[1], 'v', ARGV[1], 'd', ARGV[2])
redis.call('PEXPIRE', KEYS[1], ARGV[3])
return 1
`)
```

| 策略 | 一致性 | 复杂度 | 适用 |
|---|---|---|---|
| Cache-Aside + 提交后删 | 最终一致，脏窗口 ms 级 | 低 | 默认；读多写少 |
| + 延迟双删 | 缩小窗口 | 低 | 对脏读敏感但容忍秒级 |
| + binlog 订阅失效 | 最终一致，兜底所有写入口 | 中（多一套消费者） | 多写入口、大团队 |
| + 版本号 CAS 写回 | 杜绝旧值覆盖新值 | 中 | 读慢（复杂查询）且并发写 |
| Read-Through（缓存组件代读） | 同 Cache-Aside | 低 | 想把回源逻辑收口到一处 |
| Write-Behind（先写缓存异步刷 DB） | 缓存宕机丢写 | 高 | 计数器、点赞等可丢场景 |
| 读 DB | 强一致 | 无 | 支付结果、库存校验等读己之写 |

### 缓存与事务

事务内 `Del`：Del 到 Commit 之间的并发读查到未提交的旧行，写回缓存，等于没删；上面的 `UpdateName` 把 Del 放在 `Commit` 之后。提交后 Del 失败时 DB 无法回滚，只能记录 + 重试 + binlog 兜底；要保证"提交即一定失效"，把失效事件写进同事务的 outbox 表（见 go-data-consistency）。

## 读路径三件套：穿透、击穿、雪崩

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

## 分布式锁：Redlock、fencing token 与选型

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

## 何时不该加缓存

| 场景 | 原因 | 做法 |
|---|---|---|
| 写多读少（写 ≥ 读的 1/3） | 每次写都失效，命中率低，多一次 Redis 往返纯亏 | 直接读 DB，优化索引 |
| 强一致读（支付状态、库存校验、余额） | 缓存只有最终一致 | 读主库；DB 条件更新 |
| 数据量小且变化少（字典表、配置） | 进程内 `sync.Map`/otter 一份就够，还省一跳 | 本地缓存 + 定时刷新或配置中心推送 |
| 单次查询本身 < 1ms | Redis 往返也是 0.5~1ms，收益为零 | 不加 |
| 结果依赖请求方（权限过滤后的列表） | key 维度爆炸，命中率趋近 0 | 缓存原始数据，过滤在应用层 |

## 审查清单

- [ ] 写路径：DB 提交 → Del；Del 不在事务内；Del 失败有重试队列或 binlog 兜底，没有被吞
- [ ] 没有"更新缓存"或"先删后更"的写法；需要写回的路径用版本号 CAS
- [ ] 每个 `GetOrLoad`：`singleflight` + 空值短 TTL + TTL 抖动 + Redis 故障时回源限流；Redis 错误没有被当 miss
- [ ] 空值哨兵与合法值不可能相等；创建记录后清掉空值
- [ ] 热 key 有检测手段；本地缓存按写入过期、有 `MaximumSize`；失效顺序 L2 → L1 → 广播
- [ ] 大 key 口径核过；删除走 `UNLINK` 或分批缩小
- [ ] Redis 锁只用于效率互斥；正确性靠 fencing token / 版本条件更新；`redsync` 传入的是 ≥3 个独立实例
- [ ] 临界区结束时间 < 锁有效期（`mu.Until()`），fn 监听 ctx
- [ ] 评审过"要不要加缓存"：读写比、一致性要求、数据量
