# 客户端：构造、超时、重试

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
