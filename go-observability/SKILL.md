---
name: go-observability
description: Go 可观测性三支柱（日志 / metrics / tracing）的初始化与 Gin 中间件唯一实现处。当用户涉及 gtkit/logger 初始化与选项、日志字段规范、request_id 中间件、访问日志、trace_id 与日志关联、OpenTelemetry（TracerProvider、OTLP exporter、otelgin、otelhttp、otelgrpc、otelgorm、redisotel、采样）、Prometheus RED 指标与 label 基数、exemplar、Go runtime 指标、慢 SQL 日志、SLO 与 burn-rate 告警时触发。关键词：gtkit/logger、zap.Field、WithContextFields、WithSampling、WithRedactKeys、request_id、trace_id、traceparent、OpenTelemetry、otel、otelgin、Prometheus、promauto、histogram、exemplar、RED、SLO、burn rate、慢查询日志。分工：go-gin-api / go-microservice 直接引用本文中间件；限流熔断降级见 go-stability-engineering；pprof 与 GC 调优见 go-performance。
allowed-tools: "Read, Write, Edit, Bash, Glob, Grep"
---

# Go 可观测性

日志、metrics、tracing 的初始化与 Gin 中间件只在这里实现一次，其他 skill 只引用。目标是一条链路：告警 → P99 曲线 → exemplar 跳到 trace → 用 trace_id 捞出这条请求在所有服务的日志。

## 核心规则

1. 日志库只有 `github.com/gtkit/logger/v2`（底层 zap，字段构造器沿用 `zap.String` 等）。调用点用包级 `*Ctx` 函数，不传 logger 实例，不把 `*zap.Logger` 当参数类型。
2. `request_id` / `trace_id` / `span_id` 由 `WithContextFields` 注入，业务代码不手写这三个字段。
3. 不调 `otel.SetTracerProvider`，`otel.Tracer` 返回 no-op，span 全部静默丢弃（Go 1.27 + otel v1.46 实测：`SpanContext().IsValid()==false`，TraceID 全 0）；不调 `otel.SetTextMapPropagator`，本地 span 正常但出站不带 `traceparent`，跨服务链路断在这里。两者都不报错。
4. metric label 值域必须有限可枚举；每个 label 组合是一条独立时间序列。user_id / URL 原文 / IP / order_id 永远不做 label。
5. metrics 用 `prometheus.NewRegistry()` + `promauto.With(reg)`，不碰默认注册表。
6. 自动埋点（otelgin / otelhttp / otelgrpc / otelgorm / redisotel）优先；手写 span 只放业务边界。
7. 5xx 与慢请求 100% 留痕：日志侧 ERROR / WARN 单独 message 不被采样淹没，trace 侧靠 Collector tail sampling 保留；正常请求按比例采。
8. 结构化字段里不放 PII；`WithRedactKeys` 是兜底不是许可。
9. 慢 SQL 通过 GORM `logger.Interface` 适配器接 gtkit，日志里的 SQL 只含 `?` 占位符。

## 日志：gtkit/logger/v2

main 里初始化一次，`TraceFields` 同时负责 trace ↔ log 关联：

```go
// TraceFields 交给 WithContextFields：每条 *Ctx 日志自动带 request_id / trace_id / span_id。
// 只读 ctx、不碰共享状态，因此并发安全（库要求该函数可被多个 goroutine 同时调用）。
func TraceFields(ctx context.Context) []zap.Field {
	fields := make([]zap.Field, 0, 3)
	if id := logger.RequestIDFromContext(ctx); id != "" {
		fields = append(fields, zap.String("request_id", id))
	}
	if sc := trace.SpanContextFromContext(ctx); sc.IsValid() {
		fields = append(fields,
			zap.String("trace_id", sc.TraceID().String()),
			zap.String("span_id", sc.SpanID().String()),
		)
	}
	return fields
}

// Init 在 main 里调用一次；返回值在进程退出前 defer 调用。
func Init(production bool) func() {
	level, console, jsonOut := "debug", true, false
	if production {
		level, console, jsonOut = "info", false, true
	}
	logger.SetDefault(logger.MustNew(
		logger.WithLevel(level),
		logger.WithOutJSON(jsonOut),
		logger.WithConsole(console),
		logger.WithFile(true),
		logger.WithPath("/var/log/app/app"),
		logger.WithDivision("daily"),
		logger.WithRedactKeys("password", "token", "authorization", "id_card", "phone"),
		logger.WithSampling(100, 100),
		logger.WithContextFields(TraceFields),
		logger.WithChannel("audit", logger.WithChannelPath("/var/log/app/audit")),
	))
	return logger.Sync
}
```

| 选项 | 作用（v2.3.0，`go doc` 核对） |
|---|---|
| `WithLevel("info")` | debug / info / warn / error / dpanic / panic / fatal，默认 info；实例 `SetLevel` 可运行期调整 |
| `WithOutJSON(true)` | JSON 编码，默认 false（console 编码）；生产必开，聚合系统才能按字段检索 |
| `WithConsole(true)` | 同时写 stdout，默认 false |
| `WithFile(true)` | 写文件，默认 true |
| `WithPath(p)` | 文件路径前缀，最终 `{path}-{level}.log`，默认 `./logs/` |
| `WithDivision("daily")` | 切割方式 size / daily / both，默认 both |
| `WithRedactKeys(keys...)` | 命中 Key 的结构化字段值替换为 `[REDACTED]`；大小写敏感精确匹配；只作用于结构化字段，拼进 message 的文本不管 |
| `WithSampling(first, thereafter)` | 每 1 秒窗口内，相同 level+message 前 `first` 条全记，之后每 `thereafter` 条记 1 条；`first<=0` 回退为 1，`thereafter==0` 表示首批之后全部丢弃。按 message 文本去重，所以 message 必须固定、变量进字段 |
| `WithContextFields(fn)` | 注册从 ctx 提取字段的函数，`*Ctx` 系列自动合并；fn 必须并发安全 |
| `WithChannel(name, WithChannelPath(p))` | 独立文件路由（audit / access），继承切割与脱敏配置；`logger.Default().Channel("audit")` 取用 |

调用点：`logger.InfoCtx(ctx, "order created", zap.Int64("order_id", id))`；sugar 风格 `logger.ErrorwCtx(ctx, "payment failed", "order_id", id, "error", err)`；`logger.LogIfCtx(ctx, err)`；`logger.Fatal` 只在 main 初始化阶段。

### 字段规范

| 字段 | 规则 |
|---|---|
| 命名 | snake_case；跨服务同名同义（`order_id` 不写成 `orderId` / `oid`），否则聚合查询要写 N 个 OR |
| `error` | 固定名，用 `zap.Error(err)`；不把 err 拼进 message，否则采样失效、也无法按错误类型聚合 |
| `request_id` / `trace_id` / `span_id` | 由 `TraceFields` 注入，业务代码不写 |
| `user_id` | 内部数字 ID 可记；手机号、邮箱、身份证、token 不记，其键名列进 `WithRedactKeys` |
| `elapsed` | `zap.Duration`，默认编码为秒（浮点）；全仓统一，不混用毫秒整数 |
| message | 固定文案（"order created"），变量全部进字段 |

级别规则：ERROR 只给"当前请求确实失败且需要人处理"的事件，同一错误只在最外层记一次，内层 `return err` 透传；WARN 给降级已生效的情况（重试成功、fallback、慢 SQL、4xx）；`context.Canceled` / `DeadlineExceeded` 记 WARN 不记 ERROR（客户端走了不是服务故障）；INFO 是业务事件与每请求一条访问日志；DEBUG 线上关闭；FATAL 只在 main。

成本：每请求一条 300 字节的 INFO，1 万 QPS × 86400 秒 ≈ 260 GB/天（未压缩），留 30 天是 7.8 TB。所以访问日志 message 固定 + `WithSampling`，循环体内不记日志，请求 / 响应体不进生产日志。

## request_id 与访问日志中间件（唯一实现）

```go
const HeaderRequestID = "X-Request-ID"

// RequestID 透传或生成 X-Request-ID，写入 request ctx 与响应头。
// 注册在 otelgin.Middleware 之后：ctx 里已有 span，后面的访问日志才能同时带 trace_id。
func RequestID() gin.HandlerFunc {
	return func(c *gin.Context) {
		id := c.GetHeader(HeaderRequestID)
		if !validRequestID(id) { // 外部头不可信：只接受 1~64 位 [A-Za-z0-9._-]，防日志注入与超长字段
			id = uuid.NewString()
		}
		c.Request = c.Request.WithContext(logger.ContextWithRequestID(c.Request.Context(), id))
		c.Header(HeaderRequestID, id)
		c.Next()
	}
}

// AccessLog 每请求一条日志：5xx 记 ERROR，4xx 或超过 slow 记 WARN，其余 INFO。
// message 固定为 "http request"，WithSampling 才能按 message 聚合采样；变量全部进字段。
func AccessLog(slow time.Duration) gin.HandlerFunc {
	return func(c *gin.Context) {
		start := time.Now()
		c.Next()
		status, elapsed := c.Writer.Status(), time.Since(start)
		fields := []zap.Field{
			zap.String("method", c.Request.Method), zap.String("route", routeLabel(c)),
			zap.String("path", c.Request.URL.Path), zap.Int("status", status),
			zap.Duration("elapsed", elapsed), zap.Int("resp_bytes", c.Writer.Size()),
		}
		if last := c.Errors.Last(); last != nil {
			fields = append(fields, zap.Error(last.Err))
		}
		ctx := c.Request.Context()
		switch {
		case status >= http.StatusInternalServerError:
			logger.ErrorCtx(ctx, "http request", fields...)
		case status >= http.StatusBadRequest || elapsed > slow:
			logger.WarnCtx(ctx, "http request", fields...)
		default:
			logger.InfoCtx(ctx, "http request", fields...)
		}
	}
}

// routeLabel 返回路由模板（/users/:id）；未匹配路由时 FullPath 为空串，归入 unmatched 防止 label 爆炸。
func routeLabel(c *gin.Context) string {
	if p := c.FullPath(); p != "" {
		return p
	}
	return "unmatched"
}
```

- 中间件顺序：`otelgin.Middleware` → `RequestID` → `AccessLog` → metrics → `Recovery` → 业务。otelgin 会把带 span 的 ctx 写回 `c.Request`（v0.71.0 源码确认），放在最前面下游才拿得到 trace_id。
- 只 `c.Set("request_id", id)` 是错的：service / repo 层拿的是 `c.Request.Context()`，`c.Set` 的值到不了那里。
- 跨服务传播以 W3C `traceparent` 为主键（otelhttp / otelgrpc 自动注入解析）；`X-Request-ID` 退为兼容字段，给网关与老系统检索用。日志里两者都有。

## Tracing：OpenTelemetry

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

## Metrics：Prometheus

```go
// NewRegistry 建独立 registry，不用 prometheus.DefaultRegisterer：默认注册表是包级全局状态，
// 测试里重复注册会 panic，第三方库也可能往里塞不想要的指标。
func NewRegistry() *prometheus.Registry {
	reg := prometheus.NewRegistry()
	reg.MustRegister(
		collectors.NewProcessCollector(collectors.ProcessCollectorOpts{}),
		// 基于 runtime/metrics 采集，不走 ReadMemStats（后者 stop-the-world）。
		collectors.NewGoCollector(collectors.WithGoCollectorRuntimeMetrics(
			collectors.MetricsGC,
			collectors.MetricsScheduler,
			collectors.GoRuntimeMetricsRule{Matcher: regexp.MustCompile(`^/cpu/classes/gc/.*`)},
		)),
	)
	return reg
}
```

暴露：`promhttp.HandlerFor(reg, promhttp.HandlerOpts{EnableOpenMetrics: true})` 挂在独立 admin 端口（与 pprof 同口，不对公网），exemplar 只在 OpenMetrics 格式下输出。连接池：`reg.MustRegister(collectors.NewDBStatsCollector(sqlDB, "orders"))` 暴露 `go_sql_open_connections` / `go_sql_in_use_connections` / `go_sql_idle_connections` / `go_sql_wait_duration_seconds_total`，`wait_duration` 持续上涨就是 `MaxOpenConns` 不够。

RED 中间件（唯一实现）：

```go
// NewHTTPMetrics 用显式 registry 注册 RED 指标；同一 reg 重复调用会 panic（promauto 即 MustRegister 语义）。
func NewHTTPMetrics(reg prometheus.Registerer) *HTTPMetrics {
	f := promauto.With(reg)
	return &HTTPMetrics{
		requests: f.NewCounterVec(prometheus.CounterOpts{
			Name: "http_requests_total", Help: "HTTP requests by method, route template and status code.",
		}, []string{"method", "route", "status"}),
		duration: f.NewHistogramVec(prometheus.HistogramOpts{
			Name: "http_request_duration_seconds", Help: "HTTP request latency in seconds.",
			Buckets: []float64{.005, .01, .025, .05, .1, .25, .5, 1, 2.5, 5, 10},
		}, []string{"method", "route"}),
	}
}

// Middleware 记录 Rate / Errors / Duration；label 只用有界值：method 白名单、route 模板、status 码。
func (m *HTTPMetrics) Middleware() gin.HandlerFunc {
	return func(c *gin.Context) {
		start := time.Now()
		c.Next()
		method, route := methodLabel(c.Request.Method), routeLabel(c)
		m.requests.WithLabelValues(method, route, strconv.Itoa(c.Writer.Status())).Inc()

		seconds := time.Since(start).Seconds()
		obs := m.duration.WithLabelValues(method, route)
		// exemplar：把 trace_id 挂到直方图样本上，Grafana 里可从 P99 曲线直接跳到对应 trace。
		if sc := trace.SpanContextFromContext(c.Request.Context()); sc.IsSampled() {
			if eo, ok := obs.(prometheus.ExemplarObserver); ok {
				eo.ObserveWithExemplar(seconds, prometheus.Labels{"trace_id": sc.TraceID().String()})
				return
			}
		}
		obs.Observe(seconds)
	}
}

// methodLabel：method 由客户端任意填写，不在白名单的归入 other，否则一条请求就能新增一条时间序列。
func methodLabel(method string) string {
	if _, ok := knownMethods[method]; ok {
		return method
	}
	return "other"
}
```

高基数 label 禁令（每个 label 组合 = 一条时间序列 ≈ Prometheus 内存几 KB + 查询变慢）：

| 值 | 后果 | 替代 |
|---|---|---|
| `c.Request.URL.Path` 原文 | `/users/123`、`/users/124`… 每个 ID 一条序列，爬虫扫一遍 404 路径直接打爆 | `c.FullPath()` 模板 + 空串映射 `unmatched` |
| user_id / order_id / IP | 序列数 = 用户数 × 路由数 | 不做 label；需要按用户看就查日志或 trace |
| 未过滤的 HTTP method | 客户端可伪造任意 method | 白名单外归 `other` |
| 完整 error 文本 | 每个错误串一条序列 | 用错误码 / 错误类型（有限集合） |

Histogram bucket：按 SLO 目标布点，SLO 是 300 ms 就保证 0.25 与 0.5 之间有边界，否则 `histogram_quantile` 在那一段线性插值误差极大；11~15 个桶够用，每多一个桶所有 label 组合都多一条序列。业务指标计数器命名 `payment_attempts_total{result="success|failed"}`，"rate" 是 PromQL `rate()` 算出来的，不是指标名。

## 慢 SQL

```go
// Trace 由 GORM 在每条 SQL 结束后调用；fc 惰性生成 SQL 文本，只在真要记日志时才调用。
func (l *GormLogger) Trace(ctx context.Context, begin time.Time, fc func() (string, int64), err error) {
	if l.level <= gormlogger.Silent {
		return
	}
	elapsed := time.Since(begin)
	switch {
	case err != nil && !errors.Is(err, gorm.ErrRecordNotFound) && l.level >= gormlogger.Error:
		sql, rows := fc()
		logger.ErrorCtx(ctx, "sql error", zap.Error(err), zap.String("sql", sql),
			zap.Int64("rows", rows), zap.Duration("elapsed", elapsed))
	case l.slow > 0 && elapsed > l.slow && l.level >= gormlogger.Warn:
		sql, rows := fc()
		logger.WarnCtx(ctx, "slow sql", zap.String("sql", sql), zap.Int64("rows", rows),
			zap.Duration("elapsed", elapsed), zap.Duration("threshold", l.slow))
	}
}

// ParamsFilter 实现 gorm.ParamsFilter：丢弃参数值，fc 返回的 SQL 只含 ? 占位符——
// 参数里的手机号、身份证不落日志（与 GORM 自带 logger 的 ParameterizedQueries 机制相同）。
func (l *GormLogger) ParamsFilter(_ context.Context, sql string, _ ...any) (string, []any) {
	return sql, nil
}
```

`GormLogger` 其余方法（`LogMode` 拷贝自身改级别；`Info/Warn/Error` 按级别转 `logger.InfoCtx` 等）见 build 文件；接入 `gorm.Open(mysql.Open(dsn), &gorm.Config{Logger: slowsql.New(200 * time.Millisecond)})`。`Trace` 收到的 ctx 就是业务传给 `db.WithContext(ctx)` 的 ctx，所以慢 SQL 日志天然带 trace_id。

要做 DB 耗时 histogram 时用 Before / After 回调配对：`db.Callback().Query().Before("gorm:query").Register(name, fn)` 里 `db.InstanceSet(key, time.Now())`，After 回调 `v, ok := db.InstanceGet(key)` 再 `start, isTime := v.(time.Time)` 带 ok 断言，label 只用 `db.Statement.Table`（空串映射 `raw`）。`Statement.Context.Value(key)` 拿不到 Before 里设的值（没人往 ctx 里写过），对 nil 裸断言 `.(time.Duration)` 直接 panic——这是此前版本的错误。

## SLO 与告警

```promql
# P99 延迟（按路由）
histogram_quantile(0.99, sum by (le, route) (rate(http_request_duration_seconds_bucket[5m])))
# 错误率 SLI（5xx 占比）
sum(rate(http_requests_total{status=~"5.."}[5m])) / sum(rate(http_requests_total[5m]))
# 多窗口 burn rate：30 天 99.9% SLO，1h 窗口烧掉 2% 预算（14.4×）且 5m 窗口同时超标才告警，避免尖刺误报
(error_ratio_1h > 14.4 * 0.001 and error_ratio_5m > 14.4 * 0.001)
  or (error_ratio_6h > 6 * 0.001 and error_ratio_30m > 6 * 0.001)
```

`error_ratio_*` 用 recording rule 预先算好。告警只挂 SLI（错误率、延迟），原因指标（CPU、连接数）进 dashboard 用于定位。错误预算、告警分级与降级策略见 go-stability-engineering。

## 何时不该记 / 不该做 label

| 场景 | 做法 | 理由 |
|---|---|---|
| 循环体 / 每条消息一行 INFO | 循环外汇总一条，或 DEBUG | 10 万条/秒的日志先打爆磁盘再打爆采集 agent |
| 请求 / 响应体 | 不记；排障用 trace 的 event 或抓包 | 体积大且几乎必含 PII |
| 客户端已取消的请求 | WARN，不 ERROR，不触发告警 | 不是服务故障，进 ERROR 会淹没真告警 |
| 按用户 / 订单维度看指标 | 查日志或 trace，不加 label | 高基数直接压垮 Prometheus |
| health check 路由 | 访问日志与 metrics 中间件跳过 `/livez` `/readyz` | 探针每秒来一次，全是噪音 |

## 审查清单

- [ ] 日志只 import `github.com/gtkit/logger/v2` + `go.uber.org/zap`（字段）；没有 `log`、`log/slog`、`*zap.Logger` 参数
- [ ] `WithContextFields` 注入了 request_id / trace_id / span_id，业务代码里 grep 不到手写这三个字段
- [ ] main 里 `otelsetup.Init` 与 `otel.SetTextMapPropagator` 都执行了；随手起一个 span 检查 `SpanContext().IsValid()` 为 true
- [ ] 中间件顺序：otelgin → RequestID → AccessLog → metrics；request_id 写进 `c.Request.Context()` 而不只 `c.Set`
- [ ] 出站 HTTP 用 `otelhttp.NewTransport`，gRPC 用 `otelgrpc.NewServerHandler/NewClientHandler`，GORM / Redis 插件已 `Use` / `InstrumentTracing`
- [ ] 所有 label 值域可枚举：route 用 `FullPath()` 且空串映射 `unmatched`，method 有白名单，没有 user_id / IP / URL 原文 / 错误文本
- [ ] metrics 注册用 `promauto.With(reg)` + 独立 registry；`/metrics` 与 pprof 在独立 admin 端口
- [ ] `WithRedactKeys` 覆盖 password / token / authorization / id_card / phone；高频日志 message 固定、无变量拼接（否则 `WithSampling` 失效）
- [ ] 慢 SQL 日志的 SQL 只含 `?`（`ParamsFilter` 或 `WithoutQueryVariables`）；GORM 回调用 `InstanceGet` 带 ok 断言
- [ ] histogram bucket 在 SLO 目标附近有边界；告警基于 SLI 多窗口 burn rate，不是单点阈值
- [ ] `logger.Sync()` 与 tracing `shutdown(ctx)` 都在 `srv.Shutdown` 之后执行
