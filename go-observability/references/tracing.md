# Tracing：OpenTelemetry

```go
// Init 在 main 最先调用。不调用时 otel.Tracer 返回 no-op：span 全部静默丢弃且没有任何报错
// （Go 1.27 + otel v1.46 实测：SpanContext().IsValid()==false，TraceID 全 0）。
// 返回的 shutdown 在 srv.Shutdown 之后调用，把批处理队列里剩余的 span 刷出去。
func Init(ctx context.Context, service, version, collectorAddr string, ratio float64) (shutdown func(context.Context) error, err error) {
	exp, err := otlptracegrpc.New(ctx,
		otlptracegrpc.WithEndpoint(collectorAddr), // 形如 "otel-collector:4317"，无 scheme
		otlptracegrpc.WithInsecure(),              // 集群内明文；跨公网改 TLS
	)
	if err != nil {
		return nil, fmt.Errorf("otlp exporter: %w", err)
	}
	res, err := resource.Merge(resource.Default(), resource.NewWithAttributes(semconv.SchemaURL,
		semconv.ServiceName(service),
		semconv.ServiceVersion(version),
	))
	if err != nil {
		return nil, fmt.Errorf("otel resource: %w", err)
	}
	tp := sdktrace.NewTracerProvider(
		sdktrace.WithResource(res),
		sdktrace.WithBatcher(exp, sdktrace.WithBatchTimeout(2*time.Second)),
		// head-based 采样：根 span 按比例抽样，子 span 跟随父决定，一条 trace 要么完整要么没有。
		sdktrace.WithSampler(sdktrace.ParentBased(sdktrace.TraceIDRatioBased(ratio))),
	)
	otel.SetTracerProvider(tp)
	// 不设 Propagator 同样是 no-op：出站请求不带 traceparent，跨服务链路在这里断掉。
	otel.SetTextMapPropagator(propagation.NewCompositeTextMapPropagator(
		propagation.TraceContext{}, propagation.Baggage{},
	))
	return tp.Shutdown, nil
}
```

`semconv` 导入用与 SDK 相同的版本（sdk v1.46.0 的 `resource.Default()` 用 `semconv/v1.43.0`），否则 `resource.Merge` 返回 `ErrSchemaURLConflict`。

自动埋点接入：

```go
// Wire 接入自动埋点：入站 HTTP、GORM、Redis 各一行。手写 span 只补业务边界。
func Wire(r *gin.Engine, db *gorm.DB, rdb redis.UniversalClient, service string) error {
	// otelgin 解析 traceparent、创建 server span，并把带 span 的 ctx 写回 c.Request（v0.71.0 源码确认），
	// 所以必须是第一个中间件，后面的 RequestID / AccessLog / 业务代码才能从 c.Request.Context() 拿到 trace_id。
	r.Use(otelgin.Middleware(service))
	// WithoutQueryVariables：span 里只留带 ? 的 SQL，参数值（可能含 PII）不进 trace。
	if err := db.Use(gormotel.NewPlugin(gormotel.WithoutQueryVariables())); err != nil {
		return fmt.Errorf("gorm otel plugin: %w", err)
	}
	if err := redisotel.InstrumentTracing(rdb, redisotel.WithDBStatement(false)); err != nil {
		return fmt.Errorf("redis otel: %w", err)
	}
	return nil
}

// gRPC：服务端与客户端各挂一个 stats.Handler；拦截器路线的选项在 v0.71.0 已标 "Deprecated: Use stats handlers instead"。
func NewGRPCServer() *grpc.Server {
	return grpc.NewServer(grpc.StatsHandler(otelgrpc.NewServerHandler()))
}
```

出站 HTTP：`&http.Client{Timeout: 5 * time.Second, Transport: otelhttp.NewTransport(http.DefaultTransport)}`，进程内复用一个，自动注入 `traceparent`。模块：`gorm.io/plugin/opentelemetry/tracing`（别名 `gormotel`，包名与 `otel/trace` 冲突）、`github.com/redis/go-redis/extra/redisotel/v9`、`go.opentelemetry.io/contrib/instrumentation/...`。手写 span 只补业务边界：

```go
// 包级 tracer 可以在 Init 之前创建：otel 全局 provider 是延迟代理，SetTracerProvider 后自动切到真实实现。
var tracer = otel.Tracer("order-service")

// CreateOrder 手写 span 只用于业务边界；DB / Redis / HTTP 的 span 交给自动埋点。
func (s *OrderService) CreateOrder(ctx context.Context, userID int64, productID string) (int64, error) {
	ctx, span := tracer.Start(ctx, "OrderService.CreateOrder",
		trace.WithAttributes(attribute.String("product_id", productID)))
	defer span.End()

	orderID, err := s.repo.Create(ctx, userID, productID) // 必须传新 ctx，子 span 才挂得上
	if err != nil {
		span.RecordError(err)                       // 作为 event 记录，含错误文本与类型
		span.SetStatus(codes.Error, "create order") // 状态描述写固定文案，便于按描述聚合
		return 0, err
	}
	span.SetAttributes(attribute.Int64("order_id", orderID))
	return orderID, nil
}
```

导入：`attribute` 来自 `go.opentelemetry.io/otel/attribute`，`codes` 来自 `go.opentelemetry.io/otel/codes`，`trace.WithAttributes` 来自 `go.opentelemetry.io/otel/trace`——三者缺一都编译失败。

采样策略：

| 方式 | 决策点 | 能做到 | 做不到 |
|---|---|---|---|
| head-based `ParentBased(TraceIDRatioBased(r))` | 根 span 创建时 | 成本可控、跨服务一致（子服务跟随 `traceparent` 的 sampled 位） | 不知道请求最终是否出错 / 变慢，错误 trace 也只保留 r 比例 |
| tail-based（Collector `tail_sampling` processor） | trace 结束后 | 错误与 P99 以上的慢 trace 100% 保留，正常流量 1% | Collector 要缓存完整 trace，内存与延迟成本在 Collector 侧 |

生产组合：SDK 侧 `ParentBased(TraceIDRatioBased(1.0))` 全采，Collector 侧 tail sampling 决定留什么；QPS 极高时 SDK 侧降到 0.1~0.3 并接受"错误 trace 有缺失"。
