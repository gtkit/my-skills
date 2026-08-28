---
name: go-mq-patterns
description: Go 消息队列生产级模式库：Kafka / RocketMQ / NATS JetStream / RabbitMQ 的客户端选型、投递语义与消费端工程实现。当用户编写或审查 MQ 生产者、消费者、消费者组代码，涉及消费幂等、顺序消息、分区键、重试与死信队列（DLQ）、毒丸消息、事务消息 / 半消息回查、延迟消息、消息积压与 lag、位点 / offset 提交、rebalance、at-least-once / exactly-once、Outbox、消费者优雅关闭时触发。触发关键词包括但不限于：Kafka、franz-go、kgo、sarama、kafka-go、RocketMQ、rocketmq-client-go、NATS、JetStream、RabbitMQ、amqp091、消息队列、MQ、消费者组、consumer group、幂等消费、顺序消费、重试、死信、DLQ、事务消息、延迟消息、积压、lag、offset、位点提交、at-least-once、exactly-once、Outbox、本地消息表。分工：Outbox / 本地消息表与 DB 事务的实现见 go-data-consistency；限流、熔断、退避的通用策略见 go-stability-engineering；错误分类接口见 go-error-handling。
---

# Go 消息队列模式

MQ 客户端选型、投递语义与消费端实现（幂等、顺序、重试、死信、位点、积压）。Outbox 与 DB 事务见 go-data-consistency，限流熔断见 go-stability-engineering。
标「go doc」的结论来自客户端库文档，标「源码」的来自客户端源码；版本为核实时各库的最新发布。

## 核心规则

1. 所有主流 MQ 给消费端的保证都是 at-least-once；"exactly-once"只能靠消费端幂等实现，不是靠 broker 配置。
2. 位点在业务处理完成后提交。自动提交提交的是"已拉取"而不是"已处理"，崩溃即丢消息。
3. 顺序只在一个分区/队列内成立；重试会破坏顺序，需要顺序就原地重试，不投回队尾。
4. 重试必须有界、带退避、区分可重试与不可重试；超限与不可重试的消息进死信，不能无限重投阻塞分区。
5. handler 的 panic 必须在 handler 边界 recover；一条毒丸不能带走整个消费者进程。
6. Kafka 分区数只能增不能减，增分区会改变 key→分区映射；消费者数 ≤ 分区数，多出来的空转。
7. 死信写入失败时不能提交位点：宁可让消费者退出重启，不能让消息消失。
8. 生产端 acks=all + 幂等生产 + 有界缓冲 + 投递超时；kafka-go 的 `Writer.RequiredAcks` 默认 `RequireNone`（go doc），写丢不报错。
9. 消息头固定携带 message-id、traceparent、schema-version；正文超 1 MB 走对象存储 + 引用。
10. 需要同步结果、强一致读、或日消息量在万级以内且已有 DB 的场景，不引入 MQ。

## 选型

| 系统 / 客户端 | 版本（发布） | 适合 | 不适合 / 陷阱 |
|---|---|---|---|
| Kafka + `twmb/franz-go`（`pkg/kgo`） | v1.21.6（2026-08） | 高吞吐事件流；需要精细位点控制、事务、管理 API（`pkg/kadm` 查 lag、加分区） | 默认幂等生产、acks=all、cooperative-sticky 均衡器（go doc）；API 面大，用前读 go doc |
| Kafka + `IBM/sarama` | v1.60.2（2026-08） | 存量项目；SASL/Kerberos 生态最全 | `ConsumerGroupHandler` 回调式 API 冗长；默认均衡策略仍是 range（go doc）；幂等生产要求 `Net.MaxOpenRequests=1` + `WaitForAll`（go doc） |
| Kafka + `segmentio/kafka-go` | v0.4.51（2026-04） | 小项目，API 最简 | `Writer.RequiredAcks` 默认 `RequireNone`；`Reader.CommitInterval` 为 0 才是同步提交（go doc） |
| RocketMQ 4.x + `apache/rocketmq-client-go/v2` | v2.1.2（2023-08，之后无发布） | 阿里系存量集群；事务消息、18 级延迟、顺序消息、Tag 过滤是原生能力 | remoting 协议直连 NameServer；依赖 logrus 等旧库；三年无发布 |
| RocketMQ 5.x + `apache/rocketmq-clients/golang/v5` | v5.1.4（2026-06） | 新建 RocketMQ 5 集群；任意时间戳延迟 `SetDelayTimestamp`、`SetMessageGroup` 顺序 | 走 gRPC Proxy，连不上 4.x 集群 |
| NATS JetStream `nats-io/nats.go/jetstream` | v1.53.1（2026-08） | 云原生轻量事件、请求-响应与持久化混合 | 单条 `Ack/Nak/Term`、`MaxDeliver` + `BackOff`、`Nats-Msg-Id` 去重窗口默认 2 分钟（go doc）；不做长期留存与全量回放 |
| RabbitMQ `rabbitmq/amqp091-go` | v1.14.0（2026-08） | 任务队列、复杂路由（exchange/binding）、单条确认 | 无分区概念，顺序只在单队列单消费者成立；DLX 靠队列参数 `x-dead-letter-exchange`；吞吐量级低于 Kafka |

## 投递语义

- at-most-once：先提交后处理，崩溃丢消息。只用于可丢的指标/日志。
- at-least-once：处理完再提交，崩溃重复。所有业务消息的默认。
- exactly-once：Kafka 事务（`kgo.TransactionalID` + `GroupTransactSession`）只覆盖"消费 Kafka → 写 Kafka"闭环；处理逻辑一旦写 DB / 调 HTTP，事务覆盖不到，重复照样出现。对外部副作用，**幂等消费是唯一可靠的 exactly-once**。
- 幂等键：优先生产端生成的业务消息 ID（订单号 + 事件类型）写进消息头；`topic-partition-offset` 只在同一 topic 内唯一，重放到新 topic 后失效。
- 幂等落点：与业务同一 DB 事务的唯一约束（下文 `ConsumeOnce`）优于 Redis `SET NX`——进程在 SETNX 之后、业务提交之前崩溃，键留下了业务没做，要再补"处理完置成功态"的第二阶段（见 go-data-consistency）。

## 位点提交与 rebalance

- franz-go 自动提交间隔默认 5s（go doc），提交的是已拉取位点：拉了 500 条处理到第 10 条时提交，崩溃后 490 条丢失。所以 `DisableAutoCommit()`，处理完一批再 `CommitUncommittedOffsets`。
- rebalance 默认与消费完全独立（go doc）：处理到一半分区被收走，提交会落到不再拥有的分区，甚至把别人已提交的位点倒回去。`BlockRebalanceOnPoll()` 让 rebalance 等你 `AllowRebalance()`；代价是处理超过 `RebalanceTimeout`（默认 60s，go doc）会被踢出组，所以必须用 `PollRecords(ctx, n)` 限批。
- 关停时提交不能用已取消的 ctx（最后一批白处理），用 `context.WithoutCancel(ctx)` + 独立短超时。
- 一批只提交一次，中途崩溃重放 ≤ 批大小：这是吞吐与重复量的取舍，靠幂等兜底，不靠逐条提交。

## 消费者骨架（franz-go）

```go
// Handler 处理单条消息。返回 nil 表示"已处理或已安全停入死信"，位点可以前进；
// 返回 error 表示"无法安全前进"（如死信写入也失败），本批不提交并退出进程，交给编排器重启。
type Handler func(ctx context.Context, rec *kgo.Record) error

var errHandlerTimeout = errors.New("handler 超时")

type Consumer struct {
	cl      *kgo.Client
	handle  Handler
	m       *Metrics
	workers int           // 并发处理的分区数上限（分区内仍串行）
	timeout time.Duration // 单条消息处理超时，覆盖重试全程
}

func New(brokers []string, group string, topics []string, h Handler, m *Metrics) (*Consumer, error) {
	cl, err := kgo.NewClient(
		kgo.SeedBrokers(brokers...),
		kgo.ConsumerGroup(group),
		kgo.ConsumeTopics(topics...),
		kgo.DisableAutoCommit(),                         // 处理完再提交：at-least-once 的前提
		kgo.BlockRebalanceOnPoll(),                      // 处理期间不 rebalance，避免把位点提交到已不属于自己的分区
		kgo.ConsumeResetOffset(kgo.NewOffset().AtEnd()), // 无位点时从最新开始；补数场景改 AtStart
		kgo.OnPartitionsRevoked(func(ctx context.Context, cl *kgo.Client, _ map[string][]int32) {
			// 分区被收回前把已处理位点刷出去，否则新 owner 从旧位点重放
			if err := cl.CommitUncommittedOffsets(ctx); err != nil {
				logger.WarnCtx(ctx, "revoke 时提交位点失败", zap.Error(err))
			}
		}),
	)
	if err != nil {
		return nil, fmt.Errorf("kafka client: %w", err)
	}
	return &Consumer{cl: cl, handle: h, m: m, workers: 8, timeout: 30 * time.Second}, nil
}

// Run 阻塞到 ctx 取消：停止拉取 → 处理完已拉到的消息 → 提交位点 → 离开消费组。
func (c *Consumer) Run(ctx context.Context) error {
	defer c.cl.CloseAllowingRebalance() // 开了 BlockRebalanceOnPoll 就必须用这个 Close
	for {
		fetches := c.cl.PollRecords(ctx, 500) // 有界：一次最多 500 条，限制在途量与内存
		if fetches.IsClientClosed() {
			return nil
		}
		fetches.EachError(func(topic string, p int32, err error) {
			if !errors.Is(err, context.Canceled) {
				logger.ErrorCtx(ctx, "fetch 失败", zap.String("topic", topic), zap.Int32("partition", p), zap.Error(err))
			}
		})
		if err := c.processBatch(ctx, fetches); err != nil {
			return fmt.Errorf("本批未提交，退出重启: %w", err)
		}
		// 提交不能用已取消的 ctx，否则关停时最后一批白处理
		cctx, cancel := context.WithTimeout(context.WithoutCancel(ctx), 10*time.Second)
		err := c.cl.CommitUncommittedOffsets(cctx)
		cancel()
		if err != nil {
			logger.ErrorCtx(ctx, "提交位点失败", zap.Error(err)) // 下次循环会连同新位点一起重提
		}
		c.cl.AllowRebalance()
		if ctx.Err() != nil {
			return nil
		}
	}
}

// processBatch 分区间并发、分区内串行——这是 Kafka 唯一的有序单位。
func (c *Consumer) processBatch(ctx context.Context, fetches kgo.Fetches) error {
	base := context.WithoutCancel(ctx) // 在途消息不因关停被半路打断，靠单条超时兜底
	var g errgroup.Group
	g.SetLimit(c.workers)
	fetches.EachPartition(func(p kgo.FetchTopicPartition) {
		if len(p.Records) == 0 {
			return
		}
		g.Go(func() error {
			last := p.Records[len(p.Records)-1]
			c.m.lag.WithLabelValues(p.Topic, strconv.Itoa(int(p.Partition))).Set(float64(p.HighWatermark - last.Offset - 1))
			for _, rec := range p.Records {
				if err := c.processOne(base, rec); err != nil {
					return err
				}
			}
			return nil
		})
	})
	return g.Wait()
}

func (c *Consumer) processOne(ctx context.Context, rec *kgo.Record) (err error) {
	start := time.Now()
	result := "ok"
	defer func() {
		if r := recover(); r != nil { // 最后一道防线：handler 之外的 panic 不能带走整个进程
			result = "panic"
			err = fmt.Errorf("handler panic: %v", r)
			logger.ErrorCtx(ctx, "handler panic", zap.Any("panic", r), zap.ByteString("stack", debug.Stack()))
		}
		c.m.processed.WithLabelValues(rec.Topic, result).Inc()
		c.m.duration.WithLabelValues(rec.Topic).Observe(time.Since(start).Seconds())
	}()
	hctx, cancel := context.WithTimeoutCause(ctx, c.timeout, errHandlerTimeout)
	defer cancel()
	hctx = ExtractTrace(hctx, rec)
	if err = c.handle(hctx, rec); err != nil {
		result = "error"
		logger.ErrorCtx(hctx, "消费失败", zap.String("topic", rec.Topic),
			zap.Int32("partition", rec.Partition), zap.Int64("offset", rec.Offset), zap.Error(err))
	}
	return err
}
```

- 分区间并发（`errgroup.SetLimit`）、分区内串行——分区是 Kafka 唯一的有序单位。按 key 再拆 worker 只在分区内消息互不相关时才值得。
- `PollRecords` 在 ctx 取消或客户端关闭时注入带错误的假 fetch（go doc），循环靠 `IsClientClosed()` 与 `ctx.Err()` 退出，已拉到的消息处理完再走。
- `processOne` 的 recover 是最后防线；handler 自己的 panic 在 `WithRetry` 里转成 Permanent 进死信。
- 指标 `Metrics` 由 `promauto.With(reg)` 建：`mq_consume_total{topic,result}`、`mq_consume_duration_seconds{topic}`、`mq_consumer_lag_records{topic,partition}`；label 不放 key 与消息 ID。

## 重试与死信

```go
// Permanent 标记不可重试的错误（参数非法、业务规则拒绝、反序列化失败），实现 go-error-handling 的
// Retryable() 接口；生产代码直接复用那里的 Permanent() / IsRetryable()，这里只为示例自包含。
type Permanent struct{ Err error }

func (p Permanent) Error() string   { return p.Err.Error() }
func (p Permanent) Unwrap() error   { return p.Err }
func (p Permanent) Retryable() bool { return false }

// retryable：显式标记优先；未标记的错误（网络、超时、下游 5xx、死锁）默认可重试——
// 与 go-error-handling 的"默认不重试"相反，因为这里的重试有界且以死信收尾，误重试的代价只是几次退避。
func retryable(err error) bool {
	if r, ok := errors.AsType[interface {
		error
		Retryable() bool
	}](err); ok {
		return r.Retryable()
	}
	return true
}
```

```go
// WithRetry 把 handler 包成"有界重试 + 指数退避 + 死信"。重试在原分区原地进行，不破坏顺序；
// 退避期间该分区后续消息被阻塞，所以 maxAttempts 次退避总和必须远小于单条超时与 RebalanceTimeout（默认 60s）。
// 单条超时到期（ctx.Done）同样进死信：一条慢消息不能让消费者退出重启、无限重放。
func WithRetry(h Handler, dlq *DLQ, maxAttempts int, base time.Duration) Handler {
	maxAttempts, base = max(maxAttempts, 1), max(base, time.Millisecond) // 0/负值：至少调一次 handler；rand.N(0) 会 panic
	return func(ctx context.Context, rec *kgo.Record) error {
		var err error
		for attempt := 1; ; attempt++ {
			if err = safeCall(h, ctx, rec); err == nil {
				return nil
			}
			if !retryable(err) || attempt == maxAttempts {
				break
			}
			select {
			case <-time.After(base<<(attempt-1) + rand.N(base)): // 指数退避 + 抖动，避免同批消息同时重试
			case <-ctx.Done():
				err = fmt.Errorf("%w（最后一次错误: %w）", context.Cause(ctx), err)
			}
			if ctx.Err() != nil {
				break
			}
		}
		// 死信用独立 ctx：走到这里 ctx 可能已因单条超时到期。写失败必须上抛——此时不能提交位点，否则消息就丢了
		dctx, cancel := context.WithTimeout(context.WithoutCancel(ctx), 5*time.Second)
		defer cancel()
		if derr := dlq.Send(dctx, rec, maxAttempts, err); derr != nil {
			return fmt.Errorf("死信写入失败（原错误 %v）: %w", err, derr)
		}
		return nil
	}
}

// safeCall 把 handler 的 panic 转成 Permanent 错误：panic 是代码 bug，重试也不会好，直接进死信。
func safeCall(h Handler, ctx context.Context, rec *kgo.Record) (err error) {
	defer func() {
		if r := recover(); r != nil {
			err = Permanent{Err: fmt.Errorf("panic: %v", r)}
		}
	}()
	return h(ctx, rec)
}
```

- 分类先于重试：反序列化失败、参数非法、业务规则拒绝是 Permanent，重试 100 次结果一样，直接进死信；网络、超时、5xx、死锁可重试。判定走 `Retryable() bool` 接口（go-error-handling），MQ 侧对未标记错误默认重试，因为重试有界且以死信收尾。
- 原地重试保顺序但阻塞该分区后续消息：`maxAttempts` 次退避总和必须小于单条超时；单条超时到期也进死信让位点前进，死信写入用 `WithoutCancel` + 独立超时——否则一条慢消息就让消费者退出重启、无限重放同一条。
- `DLQ.Send` 原样转存 Key/Value，头里追加 `x-origin-topic/partition/offset`、`x-attempts`、`x-error`；重放工具按头回放到原 topic，不直接改 DB。
- RocketMQ 把这套做在服务端：返回 `consumer.ConsumeRetryLater` 进 `%RETRY%<group>` 按延迟等级递增重投，客户端 `MaxReconsumeTimes` 默认 -1 即取 16 次（源码）后进 `%DLQ%<group>`；顺序消费返回 `SuspendCurrentQueueAMoment` 原地重试。NATS：`Nak()` 立即重投、`NakWithDelay`、`Term()` 终止投递，`MaxDeliver` 配 `BackOff` 列表。RabbitMQ：`Nack(requeue=false)` 进 DLX，quorum 队列用 `x-delivery-limit` 限次。

## 消费幂等

```go
// processed_messages(msg_id PRIMARY KEY, consumed_at) 与业务写入在同一事务里：
// 要么"标记 + 业务"一起提交，要么一起回滚，不存在"业务成了标记没写"的窗口。
const insertMark = `INSERT INTO processed_messages (msg_id, consumed_at) VALUES ($1, NOW()) ON CONFLICT (msg_id) DO NOTHING`

// ConsumeOnce 以 msgID 为幂等键执行 apply；重复消息返回 ErrDuplicate，调用方按成功处理（提交位点）。
func ConsumeOnce(ctx context.Context, db *sql.DB, msgID string, apply func(ctx context.Context, tx *sql.Tx) error) error {
	tx, err := db.BeginTx(ctx, nil)
	if err != nil {
		return fmt.Errorf("begin: %w", err)
	}
	defer func() { _ = tx.Rollback() }() // Commit 成功后 Rollback 返回 ErrTxDone，忽略即可
	res, err := tx.ExecContext(ctx, insertMark, msgID)
	if err != nil {
		return fmt.Errorf("标记消息: %w", err)
	}
	n, err := res.RowsAffected()
	if err != nil {
		return fmt.Errorf("rows affected: %w", err)
	}
	if n == 0 {
		return ErrDuplicate
	}
	if err := apply(ctx, tx); err != nil {
		return err
	}
	return tx.Commit()
}
```

- 标记与业务写入同一事务，不存在"业务成了标记没写"或反过来的窗口。MySQL 用 `INSERT IGNORE`。
- `ErrDuplicate` 对消费者是成功：位点照常提交。标记表按 `consumed_at` 清理，保留期大于最长可能的重放跨度。

## 事务消息与 Outbox

RocketMQ 事务消息 = 半消息（消费者不可见）→ 本地事务 → Commit/Rollback；客户端没回应时 broker 回查 `CheckLocalTransaction`（broker 侧默认半消息 6s 后开始回查、每 30s 一次、最多 15 次：`transactionTimeOut` / `transactionCheckInterval` / `transactionCheckMax`，BrokerConfig 源码）。

```go
// orderTxListener 实现事务消息的两个回调。半消息先到 broker（消费者不可见），
// 本地事务成功才 Commit 让消息可见；本地事务结果未知时 broker 会回查。
type orderTxListener struct{ db *sql.DB }

func (l *orderTxListener) ExecuteLocalTransaction(msg *primitive.Message) primitive.LocalTransactionState {
	// 本地事务必须把 msg 的业务键（如 msg.GetKeys()）一起落库，回查才有依据
	if err := l.createOrder(context.Background(), msg); err != nil {
		logger.Error("本地事务失败", zap.String("keys", msg.GetKeys()), zap.Error(err))
		return primitive.RollbackMessageState
	}
	return primitive.CommitMessageState
}

func (l *orderTxListener) CheckLocalTransaction(msg *primitive.MessageExt) primitive.LocalTransactionState {
	var n int
	err := l.db.QueryRowContext(context.Background(), `SELECT COUNT(1) FROM orders WHERE order_no = $1`, msg.GetKeys()).Scan(&n)
	switch {
	case err != nil:
		return primitive.UnknowState // 查不出来就继续 Unknown，等下一次回查；不要在不确定时 Rollback
	case n > 0:
		return primitive.CommitMessageState
	default:
		return primitive.RollbackMessageState
	}
}

func NewTxProducer(nameServers []string, group string, db *sql.DB) (rocketmq.TransactionProducer, error) {
	return rocketmq.NewTransactionProducer(&orderTxListener{db: db},
		producer.WithNsResolver(primitive.NewPassthroughResolver(nameServers)),
		producer.WithGroupName(group),
		producer.WithRetry(2),
	)
}
```

- 回查查不出就返回 `UnknowState` 等下次，不能因为查询失败 Rollback；本地事务必须把消息业务键落库，否则回查无据。
- Kafka 没有半消息。"写 DB + 发消息"的原子性用 Outbox：业务事务内写 outbox 表，relay 轮询或 CDC 发到 Kafka 后标记已发。relay 的失败模式：发成功但标记失败 → 重发（消费端幂等兜底）；多 relay 并发 → `SELECT ... FOR UPDATE SKIP LOCKED` 或单实例主备。实现见 go-data-consistency。

## 延迟消息

- RocketMQ 4.x `WithDelayTimeLevel(1..18)`：1s 5s 10s 30s 1m 2m … 10m 20m 30m 1h 2h 固定等级（go doc），不能任意时刻；5.x `SetDelayTimestamp` 任意时刻。
- Kafka 原生无延迟：按档位建 `delay-5m`、`delay-1h` 等 topic，专用消费者读到未到期消息就 `PauseFetchPartitions` 等待再转投目标 topic（同档位 topic 内先进先到期，队头未到期后面必未到期）；任意时刻延迟用 DB / Redis ZSET 做时间轮再投 Kafka。
- NATS `NakWithDelay` 是重投延迟不是业务延迟；RabbitMQ 用 `x-delayed-message` 插件或 TTL + DLX。

## 生产端与 trace 传递

```go
func NewProducer(brokers []string) (*kgo.Client, error) {
	return kgo.NewClient(
		kgo.SeedBrokers(brokers...),
		kgo.RequiredAcks(kgo.AllISRAcks()),                                          // 默认即 all；显式写出防止被改成 leader ack
		kgo.RecordDeliveryTimeout(30*time.Second),                                   // 默认无限期：broker 不可用时消息会无限堆在内存里
		kgo.MaxBufferedRecords(10_000),                                              // 缓冲上限，满了 Produce 阻塞而不是吃光内存
		kgo.ProducerLinger(5*time.Millisecond),                                      // 攒批 5ms 换吞吐；默认 0
		kgo.RecordPartitioner(kgo.UniformBytesPartitioner(64<<10, true, true, nil)), // 与默认相同：有 key 按 murmur2 哈希（同 key 同分区），无 key 按字节数粘性；显式写出防止被改成随机
	)
}
```

```go
// InjectTrace 生产端：把当前 span 写进消息头；ExtractTrace 消费端：恢复上游 span 作为父节点。
// 未初始化 TracerProvider/Propagator 时两者都是 no-op（初始化见 go-observability）。
func InjectTrace(ctx context.Context, rec *kgo.Record) {
	otel.GetTextMapPropagator().Inject(ctx, headerCarrier{rec})
}

func ExtractTrace(ctx context.Context, rec *kgo.Record) context.Context {
	return otel.GetTextMapPropagator().Extract(ctx, headerCarrier{rec})
}
```

- `RecordDeliveryTimeout` 默认无限（go doc）：broker 不可用时消息无限堆内存、调用方永不报错。`MaxBufferedRecords` 默认 10,000，满了 `Produce` 阻塞（go doc）。
- 幂等生产默认开启（go doc），关掉才会因重试在 broker 端产生重复；不要为"性能"关。
- 批上限 `ProducerBatchMaxBytes` 默认 1,000,012 字节，对应 broker `max.message.bytes`（go doc）。大消息放对象存储，消息只带 URL + 摘要。
- `headerCarrier` 实现 `propagation.TextMapCarrier`，把 `traceparent`/`tracestate` 放消息头；Propagator 未初始化时两端都是 no-op，初始化见 go-observability。

## 积压处理

- lag 两处测：消费者进程内按批算 `HighWatermark - offset`（进程死了就没数据）；broker 侧 `kadm.Client.Lag(ctx, groups...)` 返回 `DescribedGroupLags`（按组名索引的 map），逐组先查 `Error()`（描述组失败 / 拉位点失败）再用 `Lag.Sorted()` / `Lag.Total()` 上报——消费者全挂也能报警。告警按"lag 持续增长 N 分钟"，不按绝对值。
- 扩容顺序：先看处理耗时（慢在下游 DB / HTTP 时加消费者只会压垮下游）→ 消费者数加到等于分区数 → 再考虑加分区。加分区不可逆且打乱 key 映射，需要顺序的 topic 改为建新 topic 双写迁移。
- 旁路消费：积压的是可丢或可延迟的消息时，临时消费者只做"落盘 + 跳过"，让主流量先恢复。

## 消息设计

- schema 用 protobuf / Avro：只加字段、不删不改类型、字段号不复用；消费端忽略未知字段。
- 消息头固定：`message-id`（幂等键）、`traceparent`、`schema-version`、`produced-at`；正文只放业务数据。
- key 是顺序与幂等的锚：订单事件 key = 订单号，用户事件 key = 用户 ID；随机 key 等于放弃顺序。

## 何时不该用 MQ

| 场景 | 选择 | 理由 |
|---|---|---|
| 调用方要同步结果（下单立刻要库存扣减结果） | RPC / HTTP | MQ 拿不到返回值，凑请求-响应要两条队列 + 关联 ID |
| 强一致读（扣完钱立刻查余额） | 同一 DB 事务 | MQ 是最终一致，读到旧值是设计内行为 |
| 日消息量万级、已有 DB | DB 表 + `FOR UPDATE SKIP LOCKED` 轮询 | 少一个基础设施、可用 SQL 排障 |

## 审查清单

- [ ] 关闭自动提交，处理完再提交；关停时提交用 `WithoutCancel` + 独立超时
- [ ] 开了 `BlockRebalanceOnPoll` 就配 `PollRecords` 限批、批后 `AllowRebalance`、关闭用 `CloseAllowingRebalance`
- [ ] `OnPartitionsRevoked` 里提交位点
- [ ] handler 有单条超时与边界 recover；panic 不杀进程
- [ ] 重试有界、有退避、区分 Permanent；超限进死信；死信写失败不提交位点
- [ ] 幂等键来自业务 / 消息 ID，落在与业务同事务的唯一约束
- [ ] 顺序消息 key 选对；分区内串行；重试原地不投队尾
- [ ] 生产端 acks=all、幂等开、设了 `RecordDeliveryTimeout` 与 `MaxBufferedRecords`；kafka-go 显式设 `RequiredAcks`
- [ ] 消息头带 message-id / traceparent / schema-version；大消息外置
- [ ] broker 侧 lag 监控与"持续增长"告警；消费者数 ≤ 分区数
- [ ] RocketMQ 事务：回查未知返回 `UnknowState`；本地事务落了业务键
- [ ] 评估过不用 MQ：同步结果 / 强一致 / 小量场景没有硬上
