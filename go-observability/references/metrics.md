# Metrics：Prometheus

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
