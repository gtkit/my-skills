# Pub/Sub 与 Streams

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
