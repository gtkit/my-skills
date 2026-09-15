# 连接数与资源

- 每连接成本：2 个 goroutine（起始栈 2 KB 按需翻倍；Go 1.27 实测 80 条连接 +160 goroutine、栈合计约 11 KB/连接）+ gorilla 读写缓冲各 4 KB + `send` 队列 256 × 24 字节切片头 ≈ 6 KB + 内核 socket 缓冲，估 30–60 KB；10 万连接约 3–6 GB，先按这个算容量再谈优化。
- fd：`ulimit -n` 与 systemd `LimitNOFILE` 都要改，容器内还要看 runtime 的默认值；Go 1.19+ 进程启动时会自动把 soft limit 提到 hard limit，但 hard limit 本身仍需运维设置。
- 三层限制：全局上限（`Hub.Len() >= MaxConns` 返回 503 + `Retry-After`）、每用户上限（Hub 内按 `users` 索引拒绝第 N+1 条，1008）、连接建立速率（按 IP/账号限流，见 go-stability-engineering）。
- 指标（`promauto.With(reg)`，初始化见 go-observability）：连接数 gauge、消息计数按 direction、握手失败按 reason、发送队列深度直方图；user_id 永不进 label。

```go
func NewMetrics(reg prometheus.Registerer, hub *Hub) *Metrics {
	f := promauto.With(reg)
	return &Metrics{
		Connections: f.NewGaugeFunc(prometheus.GaugeOpts{Name: "ws_connections"},
			func() float64 { return float64(hub.Len()) }),
		Messages:          f.NewCounterVec(prometheus.CounterOpts{Name: "ws_messages_total"}, []string{"direction"}),
		HandshakeFailures: f.NewCounterVec(prometheus.CounterOpts{Name: "ws_handshake_failures_total"}, []string{"reason"}),
		QueueDepth: f.NewHistogram(prometheus.HistogramOpts{
			Name: "ws_send_queue_depth", Buckets: []float64{0, 8, 32, 64, 128, 256},
		}),
	}
}
```
