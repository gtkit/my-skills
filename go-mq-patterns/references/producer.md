# 生产端与 trace 传递

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
