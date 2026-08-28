---
name: go-redis-patterns
description: Go 中 go-redis/v9 的生产用法：UniversalClient 构造（单机/哨兵/Cluster）、超时与 MaxRetries 重试对非幂等命令的风险、连接池推导、redis.Hook/redisotel、数据结构选型与大 key 阈值、key 命名与序列化、Pipeline 与 TxPipeline、Cluster hash tag/CROSSSLOT、Lua 脚本（EVALSHA、限流、库存扣减）、SET NX 分布式锁与看门狗、Pub/Sub 与 Streams 消费组。当用户提到 go-redis、redis.Client、Redis Cluster、Lua/EVAL、Pipeline、分布式锁、Redis 限流、Pub/Sub、Streams、XREADGROUP、redis.Nil、大 key 时触发。分工：缓存一致性、穿透/击穿/雪崩、热 key、多级缓存、Redlock 争议见 go-cache-consistency；限流/熔断的整体策略见 go-stability-engineering。
---

# Go Redis 模式（go-redis/v9）

只讲客户端用法、数据结构、Lua、Pipeline、锁、Pub/Sub 与 Streams；缓存与 DB 的一致性、穿透击穿雪崩见 go-cache-consistency。行为结论以 go-redis v9.22.0 源码 / `go doc` 与 Redis 8.0.0 实测为准。

## 核心规则

1. 所有函数签名用 `redis.UniversalClient`，不用 `*redis.Client`：否则换 Cluster 时每个模式都要改签名。
2. `ReadTimeout` 零值不是"不超时"：`0` = 默认 5s，`-1` = 永不超时，`-2` = 不调 `SetReadDeadline`（v9.22.0 `options.go`）。
3. 默认 `MaxRetries` 为 3，且"命令已写出、读响应超时"也会重试（`redis.go` 的 `retryTimeout`）：INCR/DECRBY/ZADD/LPUSH 会重复执行。非幂等命令走 `MaxRetries: -1` 的独立 client，或在 Lua 内用幂等 token。
4. `redis.Nil` 是"key 不存在"，不是错误；反过来，Redis 故障也不能当 miss。每个读都要三态处理。
5. `pipe.Exec` 只返回第一个错误；必须逐个 `cmd.Err()`。
6. Cluster 里多 key 命令、`MULTI/EXEC`、Lua 的 KEYS 必须落同一 slot（hash tag `{...}`），否则 `CROSSSLOT Keys in request don't hash to the same slot`。
7. Lua 里不用 `math.random` 生成唯一值；唯一值由 Go 传入，时间用 `redis.call('TIME')`。
8. 锁的释放用 `context.WithoutCancel(ctx)` + 独立短超时；`ErrLockNotHeld` 是硬错误，必须上抛。
9. Pub/Sub 是 at-most-once，要"至少一次"用 Streams 消费组；`sub.Channel()` 关闭后收到的是 nil `*Message`，必须 `msg, ok := <-ch`。
10. `KEYS`、`SCAN MATCH` 全键遍历、无 TTL 的 key、`HMSET`（4.0 起废弃）不进生产代码。

## 客户端：构造、超时、重试

`redis.NewUniversalClient`：只有 `MasterName` → 哨兵 `FailoverClient`；`Addrs` ≥ 2 个或 `IsClusterMode` → `ClusterClient`；否则单机（`go doc NewUniversalClient`）。

```go
// New 返回 UniversalClient：业务代码全部依赖这个接口，单机 / 哨兵 / Cluster 只靠配置切换。
func New(ctx context.Context, cfg Config) (redis.UniversalClient, error) {
	rdb := redis.NewUniversalClient(&redis.UniversalOptions{
		Addrs:           cfg.Addrs,
		MasterName:      cfg.MasterName,
		Password:        cfg.Password,
		DB:              cfg.DB,
		PoolSize:        cfg.PoolSize,
		MinIdleConns:    cfg.PoolSize / 4,
		ConnMaxIdleTime: 5 * time.Minute, // 必须小于服务端 timeout，否则拿到的是已被服务端关闭的连接
		DialTimeout:     2 * time.Second,
		ReadTimeout:     500 * time.Millisecond, // 0 = 默认 5s；-1 = 永不超时；-2 = 不调用 SetReadDeadline
		// RouteByLatency / RouteRandomly 默认不开：二者隐含 ReadOnly，读命令会落到从库，刚 SET 的值可能 GET 不到
	})
	pingCtx, cancel := context.WithTimeout(ctx, 3*time.Second)
	defer cancel()
	if err := rdb.Ping(pingCtx).Err(); err != nil {
		return nil, fmt.Errorf("redis ping %v: %w", cfg.Addrs, err)
	}
	if err := redisotel.InstrumentTracing(rdb); err != nil { // TracerProvider 需先初始化，见 go-observability
		return nil, fmt.Errorf("redisotel tracing: %w", err)
	}
	rdb.AddHook(slowLogHook{threshold: 50 * time.Millisecond})
	return rdb, nil
}
```

- 非幂等命令的 client 只多一行 `MaxRetries: -1`（同文件 `NewWriter`）；`-1` 才是关闭，`0` 是默认 3 次。
- `RouteByLatency` / `RouteRandomly` 文档原文 "It automatically enables ReadOnly"：读走从库，主从异步复制下刚写的值读不到。只在"读旧几十毫秒无所谓"的只读流量上单独建 client 开启。
- 阻塞命令（`BLPOP`、`XREADGROUP ... BLOCK`）go-redis 按 `Block` 参数单独设读超时，不受 `ReadTimeout` 限制；Pub/Sub 连接同样不受它控制。
- `WriteTimeout` 为 0 时跟随 `ReadTimeout`；`PoolTimeout` 默认 `ReadTimeout + 1s`，池耗尽的等待比命令超时还长，QPS 高时显式设小。重试退避默认 10ms → 1s；`context.Canceled`/`DeadlineExceeded` 不重试，池超时、`LOADING`、`READONLY`、`TRYAGAIN`、`CLUSTERDOWN` 会重试。

### 连接池推导

- `PoolSize` 默认 `10 × GOMAXPROCS`。按 Little 定律估：并发连接 ≈ QPS × 平均 RTT（约 1ms），一般 20–50 足够；`副本数 × PoolSize` 必须 < 服务端 `maxclients`（默认 10000），否则扩容一次就把 Redis 连满。
- `ConnMaxIdleTime` < 服务端 `timeout`；`ConnMaxLifetime` 配合 `ConnMaxLifetimeJitter` 避免整池同秒重连。监控 `rdb.PoolStats()`：`Timeouts` 增长 = 池小或慢命令，`StaleConns` 增长 = 服务端在踢连接。

### Hook：tracing 与慢命令

`redisotel.InstrumentTracing(rdb)` 与 `InstrumentMetrics(rdb)` 接 OpenTelemetry（TracerProvider/MeterProvider 初始化见 go-observability，未初始化则全是 no-op）。慢命令用自定义 `redis.Hook`（`DialHook`、`ProcessHook`、`ProcessPipelineHook` 三个方法，`New` 里的 `slowLogHook`）：`ProcessHook` 里计时，超阈值 `logger.WarnCtx`，只记 `cmd.FullName()` 不记 `cmd.String()`——后者含参数值，会把用户数据写进日志。

## 数据结构选型与大 key

| 需求 | 结构 | 注意 |
|---|---|---|
| 对象缓存、计数、锁 | String（`SET EX`、`INCR`、`SET NX PX`） | 值 > 10KB 即大 key；对象整体读写用 String 而不是 Hash |
| 对象的部分字段频繁单独更新 | Hash | 字段 > 5000 即大 key；`HGETALL` 大 hash 阻塞主线程 |
| 排行榜、滑动窗口、延时队列 | ZSET | `ZRANGEBYSCORE` 分页取，不 `ZRANGE 0 -1` |
| 去重、标签、交并差 | Set | `SINTER` 大集合 O(N×M)，超过万级放离线 |
| 队列、最近 N 条 | List | 只做简单队列；要消费组/ACK 用 Streams |
| 事件流、可靠消费 | Stream | `XADD MAXLEN ~ N` 必设，否则无限增长 |
| 签到、在线状态、布隆位图 | Bitmap | offset 大时首次 `SETBIT` 分配整块内存 |
| UV 估算 | HyperLogLog | 标准误差 0.81%，12KB 定长 |

大 key 口径：String > 10KB、集合元素 > 5000 或整体 > 1MB。检测：`redis-cli --bigkeys`（采样，生产可跑）、`MEMORY USAGE key`；治理：拆 key（`user:tags:{id}:0..n`）、Hash 按字段分桶、删除用 `UNLINK` 或 `SCAN`+`HSCAN` 渐进删（见 go-cache-consistency）。

## key 命名与序列化

- 命名 `业务:对象:id[:子项]`，全小写、冒号分隔、不含空格与 `{}`（`{}` 是 Cluster hash tag，误用会把不相关 key 挤进同一 slot）。前缀区分环境或库，不靠 `SELECT db`——Cluster 只有 db 0。每个 key 必须有 TTL；`maxmemory-policy` 纯缓存用 `allkeys-lfu`，混用存储语义时 `volatile-lfu`。
- 序列化：JSON 可读、跨语言、便于排障，默认选它；值 > 1KB 且 QPS 高时换 msgpack / protobuf，体积更小编解码更快，代价是 `redis-cli` 里不可读。结构体加字段要向后兼容（新字段可缺省），否则发布期间新旧版本互相读坏。

## Pipeline 与 TxPipeline

- `Pipeline()` 只是把命令一次发出、一次读回，中间可插入其他客户端的命令；`TxPipeline()` 额外包 `MULTI/EXEC`，保证不被插队，但没有回滚：EXEC 里一条失败其余照常执行。Cluster 上 `Pipeline` 按 key 所在节点拆成多组并行发送（`osscluster.go` `mapCmdsByNode`），`MOVED` 自动重试；`TxPipeline` 要求全部 key 同 slot。Lua 在 pipeline 里 `NOSCRIPT` 无法回退（Redis 文档），用 `Eval` 或先 `Script.Load`。

```go
// BatchGetUsers：pipe.Exec 只返回第一个错误，必须逐 cmd 检查 Err()；redis.Nil 是 miss，其他错误是故障。
func BatchGetUsers(ctx context.Context, rdb redis.UniversalClient, ids []int64) (hit map[int64]User, miss []int64, err error) {
	pipe := rdb.Pipeline() // 只是打包发送；要 MULTI/EXEC 原子性用 rdb.TxPipeline()
	cmds := make(map[int64]*redis.StringCmd, len(ids))
	for _, id := range ids {
		cmds[id] = pipe.Get(ctx, fmt.Sprintf("user:profile:%d", id))
	}
	if _, err := pipe.Exec(ctx); err != nil && !errors.Is(err, redis.Nil) {
		return nil, nil, fmt.Errorf("pipeline exec: %w", err) // 第一个错误是网络级：整批失败
	}
	hit = make(map[int64]User, len(ids))
	for id, cmd := range cmds {
		data, err := cmd.Bytes()
		switch {
		case errors.Is(err, redis.Nil):
			miss = append(miss, id)
		case err != nil: // 第一个错误是 Nil 时，后面的真实错误只能在这里发现
			return nil, nil, fmt.Errorf("get user %d: %w", id, err)
		default:
			var u User
			if err := json.Unmarshal(data, &u); err != nil {
				return nil, nil, fmt.Errorf("decode user %d: %w", id, err)
			}
			hit[id] = u
		}
	}
	return hit, miss, nil
```

Cluster 约束：hash tag `order:{1001}:items` 与 `order:{1001}:status` 按 `1001` 计算 slot，多 key 命令（`MGET`、`SINTER`、`RENAME`）、`MULTI/EXEC`、Lua 声明的 KEYS 都要同 slot；`SCAN` 只扫单节点，全量遍历用 `ClusterClient.ForEachMaster`；Cluster 上 Pub/Sub 是全节点广播，Redis 7 起改用 `SPUBLISH`/`SSubscribe`；`MaxRedirects` 默认 3。

## Lua 脚本

- `redis.NewScript(src)` + `script.Run(ctx, rdb, keys, args...)`：先 `EVALSHA`，遇 `NOSCRIPT` 自动回退 `EVAL`。脚本缓存在重启、主从切换、`SCRIPT FLUSH` 后清空，所以永远不要裸调 `EvalSha`。
- 时间用 `redis.call('TIME')` 取服务端时钟，不由每个 app 实例传 `time.Now()`——多实例时钟漂移会让窗口忽大忽小。
- 唯一值必须由 Go 传入。Redis < 5.0 默认整段脚本复制，`math.random` 每次执行用相同种子（官方文档："always uses the same seed for every execution"）；Redis 5.0 起默认、7.0 起只有效果复制，PRNG 每次调用随机播种（Redis 8.0.0 实测三次 `EVAL "return math.random(1000000)"` 返回不同值）。随机不等于唯一，用 `math.random` 拼 ZSET member 在旧版本上必然重复，在新版本上会小概率重复。
- 写命令用 `HSET`（多字段）而不是废弃的 `HMSET`；脚本要短，Redis 单线程，5ms 的脚本就是 5ms 的全局停顿。Cluster 模式下带 `#!lua` shebang 的脚本（7.0+）访问未声明的 key 会受同 slot 校验（单机不校验，Redis 8.0.0 实测），任何版本都以声明全部 KEYS 为准。

### 滑动窗口限流 + 令牌桶

```go
// 滑动窗口。KEYS[1] 限流 key；ARGV[1] 窗口毫秒；ARGV[2] 上限；ARGV[3] 唯一 member（Go 侧生成）。
var slidingWindow = redis.NewScript(`
local t = redis.call('TIME')
local now = t[1] * 1000 + math.floor(t[2] / 1000)  -- 服务端时钟：多实例时钟漂移不影响窗口
local window, limit = tonumber(ARGV[1]), tonumber(ARGV[2])
redis.call('ZREMRANGEBYSCORE', KEYS[1], 0, now - window)
local count = redis.call('ZCARD', KEYS[1])
if count >= limit then
  return {0, 0}
end
redis.call('ZADD', KEYS[1], now, ARGV[3])
redis.call('PEXPIRE', KEYS[1], window)
return {1, limit - count - 1}
`)
```

```go
// AllowSliding：window 内最多 limit 次。member 唯一由 Go 侧保证；同一 member 重试 ZADD 只更新分值，重试幂等。
// window ≤ 0 会让脚本里的 PEXPIRE 立刻删 key、限流形同虚设（Redis 8.0.0 实测），所以先拦。
func (l Limiter) AllowSliding(ctx context.Context, key string, limit int64, window time.Duration) (bool, int64, error) {
	if limit <= 0 || window <= 0 {
		return false, 0, fmt.Errorf("ratelimit %s: limit %d and window %v must be positive", key, limit, window)
	}
	member := strconv.FormatInt(time.Now().UnixNano(), 36) + "-" + strconv.FormatUint(rand.Uint64(), 36)
	res, err := slidingWindow.Run(ctx, l.rdb, []string{"rl:sw:" + key}, window.Milliseconds(), limit, member).Int64Slice()
	return pair(res, err)
}

// AllowBucket：rate 每秒补充、capacity 突发上限、n 本次申请。读超时重试会重复扣令牌，用 MaxRetries=-1 的 client。
// n ≤ 0 不拦：负数在脚本里等于补充令牌，桶会超过 capacity（Redis 8.0.0 实测 cap=5 时 n=-3 得到 8）。
func (l Limiter) AllowBucket(ctx context.Context, key string, rate, capacity, n int64) (bool, int64, error) {
	if rate <= 0 || capacity <= 0 || n <= 0 {
		return false, 0, fmt.Errorf("ratelimit %s: rate %d, capacity %d and n %d must be positive", key, rate, capacity, n)
	}
	res, err := tokenBucket.Run(ctx, l.rdb, []string{"rl:tb:" + key}, rate, capacity, n).Int64Slice()
	return pair(res, err)
}
```

令牌桶脚本（同文件 `tokenBucket`）：`HMGET tokens ts` → 按 `(now-ts)/1000*rate` 补充、`math.min(cap, ...)` 截断 → 够则扣 → `HSET`+`PEXPIRE`，返回 `{ok, 剩余}`。限流策略（单机 vs 分布式、失败开/闭）见 go-stability-engineering。

## 分布式锁（单节点）

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

## Pub/Sub 与 Streams

| 需求 | 选择 | 理由 |
|---|---|---|
| 本地缓存失效通知、配置刷新 | Pub/Sub | 丢一条无害；无持久化、无 ACK、订阅者不在线就丢 |
| 订单事件、任务分发、必须处理到 | Streams 消费组 | `XADD` 持久化、`XREADGROUP` 分发、`XACK` 确认、pending 可重投 |
| 跨系统、海量、需回溯天级 | Kafka/RocketMQ | Streams 是单 key，容量受单节点内存限制；见 go-mq-patterns |

订阅循环（同文件 `SubscribeLoop`）：`ch := sub.Channel()` 后 `select` 里必须 `case msg, ok := <-ch: if !ok { return }`——PubSub 关闭后 channel 关闭、`msg` 为 nil，直接读 `msg.Payload` 会 panic；完整循环见 go-cache-consistency 的 `ListenInvalidations`。`Channel()` 默认缓冲 100，消费者阻塞满 1 分钟消息被丢弃；go-redis 每分钟 ping，收不到 pong 会重连重订阅，重连期间的消息全部丢失（`go doc PubSub.Channel`）。

```go
func (c Consumer) Run(ctx context.Context, handle func(ctx context.Context, m redis.XMessage) error) error {
	err := c.rdb.XGroupCreateMkStream(ctx, c.stream, c.group, "$").Err()
	if err != nil && !redis.HasErrorPrefix(err, "BUSYGROUP") { // 组已存在不是错误
		return fmt.Errorf("create group %s: %w", c.group, err)
	}
	for ctx.Err() == nil {
		c.claimStale(ctx, handle)
		streams, err := c.rdb.XReadGroup(ctx, &redis.XReadGroupArgs{
			Group: c.group, Consumer: c.consumer,
			Streams: []string{c.stream, ">"}, Count: 100, Block: 5 * time.Second,
		}).Result()
		if errors.Is(err, redis.Nil) {
			continue // Block 超时无新消息
		}
		if err != nil {
			logger.WarnCtx(ctx, "xreadgroup failed", zap.String("stream", c.stream), zap.Error(err))
			select {
			case <-ctx.Done():
			case <-time.After(time.Second):
			}
			continue
		}
		for _, s := range streams {
			for _, m := range s.Messages {
				c.process(ctx, m, handle)
			}
		}
	}
	return ctx.Err()
}
```

`process` 成功才 `XAck`，失败不 ACK 留在 pending；`claimStale` 用 `XAutoClaim(MinIdle: 1m)` 接管崩溃消费者的消息。重投是"至少一次"，handler 必须幂等；重投上限与死信见 go-mq-patterns。

## 库存扣减（Lua 原子 + 幂等）

```go
var deductScript = redis.NewScript(`
if redis.call('EXISTS', KEYS[2]) == 1 then
  return {2, tonumber(redis.call('GET', KEYS[1]) or '0')}
end
local stock = tonumber(redis.call('GET', KEYS[1]) or '0')
local n = tonumber(ARGV[1])
if stock < n then
  return {0, stock}
end
local left = redis.call('DECRBY', KEYS[1], n)
redis.call('SET', KEYS[2], 1, 'EX', ARGV[2])
return {1, left}
`)

// Deduct 原子扣减。orderID 作幂等 token，让 MaxRetries 重试 / 上游重发都只扣一次。
func Deduct(ctx context.Context, rdb redis.UniversalClient, sku, orderID string, n int64) (ok bool, left int64, err error) {
	if n <= 0 { // DECRBY 负数会加库存
		return false, 0, fmt.Errorf("deduct %s: quantity %d must be positive", sku, n)
	}
	if orderID == "" { // 空 token 让所有请求共用一个 dedup key，第二单起全部被判为重复
		return false, 0, fmt.Errorf("deduct %s: empty order id", sku)
	}
	keys := []string{"stock:sku:{" + sku + "}", "stock:dedup:{" + sku + "}:" + orderID} // hash tag 保证 Cluster 同槽
	res, err := deductScript.Run(ctx, rdb, keys, n, 86400).Int64Slice()
	if err != nil {
		return false, 0, fmt.Errorf("deduct %s: %w", sku, err)
	}
	if len(res) != 2 {
		return false, 0, fmt.Errorf("deduct %s: unexpected reply %v", sku, res)
	}
	return res[0] != 0, res[1], nil
```

单 SKU 一个 key 是天然热 key，大促下单节点 CPU 打满；分段库存（`stock:sku:{id}:0..n`，扣减随机选段、失败换段）与热 key 检测见 go-cache-consistency。

## 缓存读写封装：三态返回

```go
// Get 三态返回：found=false 只代表 key 不存在（redis.Nil）；err != nil 是 Redis 故障，
// 由调用方决定降级还是失败，绝不能当 miss 处理（否则故障期间所有请求穿透到 DB）。
func Get[T any](ctx context.Context, rdb redis.UniversalClient, key string) (v T, found bool, err error) {
	data, err := rdb.Get(ctx, key).Bytes()
	if errors.Is(err, redis.Nil) {
		return v, false, nil
	}
	if err != nil {
		return v, false, fmt.Errorf("redis get %s: %w", key, err)
	}
	if err := json.Unmarshal(data, &v); err != nil {
		return v, false, fmt.Errorf("decode %s: %w", key, err)
	}
	return v, true, nil
}
```

Session 就是它的一个用法：key `session:user:<id>`，续期 `rdb.Expire(ctx, key, ttl)`，过期时间不写进 payload（续期后必然不一致）。

## 何时不该用 Redis

| 场景 | 不用 Redis 的原因 | 用什么 |
|---|---|---|
| 强一致互斥（扣款、发号） | 主从异步复制，切主丢锁 | DB 行锁 / 乐观锁；etcd、ZooKeeper 锁 |
| 不能丢的消息 | Pub/Sub at-most-once；Streams 单 key 容量受内存限制 | Kafka/RocketMQ，见 go-mq-patterns |
| 按前缀批量失效 | `SCAN MATCH` 全键空间 O(N)，千万 key 一次扫几秒 | 版本号命名空间（`v2:user:*`）、维护 key 集合 |
| 主存储 | 内存成本、持久化最多 1s 丢数据（AOF everysec） | DB 为准，Redis 只做缓存/派生数据 |

## 审查清单

- [ ] 签名类型是 `redis.UniversalClient`，没有 `*redis.Client` / `*redis.ClusterClient`
- [ ] `ReadTimeout`/`WriteTimeout`/`DialTimeout`/`PoolTimeout` 全部显式设置；没有把 `0` 当"不超时"
- [ ] 非幂等命令（INCR/DECRBY/ZADD/LPUSH/写 Lua）走 `MaxRetries: -1` 的 client 或带幂等 token
- [ ] 每个读区分 `redis.Nil`（miss）与其他错误（故障）；故障没有被当作 miss 静默穿透
- [ ] `pipe.Exec` 后逐 `cmd.Err()` 检查
- [ ] Cluster：多 key / 事务 / Lua KEYS 同 hash tag；没有 `KEYS`、没有单节点 `SCAN` 当全量
- [ ] Lua：唯一值来自 ARGV，时间来自 `TIME`，没有 `HMSET`，脚本经 `Script.Run` 而不是裸 `EvalSha`
- [ ] 锁：唯一 token、Lua 释放、`Release` 用 `WithoutCancel` + 短超时、`ErrLockNotHeld` 上抛、看门狗与 `fn` 监听 ctx
- [ ] Pub/Sub 只承载可丢消息；`msg, ok := <-ch` 判 ok；需要可靠投递的用 Streams 且 handler 幂等
- [ ] 每个 key 有 TTL；大 key 口径（String > 10KB、集合 > 5000）核过；慢命令 Hook / redisotel 已接且日志不含参数值
