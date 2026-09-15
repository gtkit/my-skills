# 消费者骨架（franz-go）

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
