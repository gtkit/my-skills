---
name: go-redis-patterns
description: go-redis/v9 生产用法：客户端构造与超时重试、连接池、数据结构选型与大 key、Pipeline、Cluster 约束、Lua 脚本、SET NX 锁、Pub/Sub 与 Streams。在 Go 里读写 Redis 时使用；缓存一致性另见 go-cache-consistency。
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

## 按任务读取

以下内容按任务读取，只读本次需要的文件；核心规则与审查清单已覆盖其结论。

| 任务 | 读 |
|---|---|
| 构造 UniversalClient、配超时重试与连接池、接 redisotel | `references/client.md` |
| 用 Pipeline / TxPipeline，处理 Cluster CROSSSLOT | `references/pipeline.md` |
| 写 Lua 脚本：限流、库存扣减、EVALSHA | `references/lua.md` |
| 实现 SET NX 分布式锁与看门狗 | `references/lock.md` |
| 用 Pub/Sub 或 Streams 消费组 | `references/pubsub-streams.md` |
| 封装缓存读写（命中 / 未命中 / 空值三态） | `references/cache-wrapper.md` |

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
