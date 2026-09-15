---
name: go-websocket-sse
description: Go 长连接推送：WebSocket 与 SSE 选型、升级前鉴权、单读单写、actor Hub、背压、心跳与中间层超时、优雅关闭、Redis 水平扩展、Last-Event-ID 补发。实现或审查实时推送时使用。
allowed-tools: "Read, Write, Edit, Bash, Glob, Grep"
---

# Go WebSocket 与 SSE

长连接服务的选型、连接生命周期、Hub、背压、关闭时序与水平扩展。HTTP 服务器与关闭顺序的主线在 go-microservice，跨实例广播的 Redis 客户端在 go-redis-patterns，限流器实现在 go-stability-engineering。

## 核心规则

1. 单向推送选 SSE，双向选 WebSocket；SSE 上生产必须走 HTTP/2——HTTP/1.1 浏览器同域只有 6 条连接，多 tab 会互相饿死。
2. 鉴权、Origin 校验、连接上限判断全部在 `Upgrade` 之前；升级后只能发 Close 帧，返回不了 401/503。
3. 一条 gorilla 连接只允许一个 goroutine 写、一个 goroutine 读，违反直接 `panic("concurrent write to websocket connection")`。所有写走 writePump，Hub 不碰 `conn`。
4. Hub 状态（clients、users 索引）只在 `Run` goroutine 内读写，不加锁；对外只暴露 channel 与 atomic 计数。混用"部分加锁"就是读锁下写 map 的来源。`close(c.send)` 同样只发生在 `Run` goroutine（`remove` / `shutdown` / 注册拒绝）；readPump 只把关闭码交给 `Unregister`——在 readPump 里 `close(send)` 与 Hub 的 `deliver` 交错，就是 `panic: send on closed channel`（build 里有反证测试）。
5. 进入 Hub 的每个 channel 发送都 `select` 上 hub 的 `done`：Hub 退出后 readPump 的 defer `unregister` 不能永久阻塞。
6. ping 周期必须小于链路上所有中间层的空闲超时（Nginx `proxy_read_timeout` 默认 60s、AWS ALB idle 60s）；`SetReadLimit`、读写 deadline 缺一不可。
7. `http.Server.Shutdown` 不关闭、不等待被 hijack 的连接；Hub 关闭必须自己发 `1001 Going Away` 并等 Close 帧写出。
8. 入站消息统一封包 `{type, payload}`，按 type 白名单分发，每连接限速；不做"收到什么就广播什么"。
9. 升级后不要把 `c.Request.Context()` 直接传给 pump：ServeHTTP 返回即取消它，用 `context.WithoutCancel` 保留 trace 值。
10. SSE 端点所在 server 的 `WriteTimeout` 为 0，或每次写前 `ResponseController.SetWriteDeadline` 续期；`id:` 必须配 `Last-Event-ID` 读取与补发，否则字段无意义。
11. 每条 `Fprintf`/`Write` 的错误立即 `return`；客户端断开的第一信号是写失败，不是 ctx 取消。

## 选型先行

| 需求 | 选择 | 理由 |
|---|---|---|
| 服务端单向推送（通知、进度、行情） | SSE | 纯 HTTP，过代理/网关/CDN 无需特殊配置，浏览器 `EventSource` 自带重连与 `Last-Event-ID` |
| 双向低延迟（聊天、协作、游戏） | WebSocket | 全双工，帧开销小 |
| 穿透企业代理 / 老旧中间层 | SSE 或长轮询 | 部分代理不转发 `Upgrade` |
| 二进制流 | WebSocket | SSE 只有 UTF-8 文本 |
| 每分钟一两次的低频更新 | 长轮询或普通轮询 | 长连接的 fd、心跳、粘性都白付 |

库：`gorilla/websocket`（2022-12 归档、2024 恢复维护，API 稳定、生态最广，本文示例基于它）；`github.com/coder/websocket`（原 nhooyr，所有操作接受 `ctx`，`wsjson` 直接读写 JSON，无 goroutine 泄漏面）；`gobwas/ws`（零拷贝、不绑定 goroutine-per-conn，配 epoll 做百万连接网关时才值得引入其复杂度）。

## WebSocket：升级与连接规则

`Upgrader.CheckOrigin` 为 nil 时 gorilla 只放行 `Origin` 与 `Host` 相同的请求，跨域前端要显式白名单（`slices.Contains(allowedOrigins, r.Header.Get("Origin"))`），不要写 `return true`。`EnableCompression`（permessage-deflate）默认关：文本消息可省 60% 以上带宽，代价是每帧 CPU 与每连接额外内存；二进制或已压缩载荷不要开。

```go
func (s *Server) ServeWS(c *gin.Context) {
	userID, ok := s.Auth(c)
	if !ok {
		c.AbortWithStatus(http.StatusUnauthorized)
		return
	}
	if s.Hub.Len() >= s.MaxConns {
		c.Header("Retry-After", "5")
		c.AbortWithStatus(http.StatusServiceUnavailable)
		return
	}
	conn, err := s.Upgrader.Upgrade(c.Writer, c.Request, nil) // 失败时 Upgrade 已自行回复 4xx
	if err != nil {
		logger.WarnCtx(c.Request.Context(), "ws upgrade", zap.Error(err))
		return
	}
	client := NewClient(s.Hub, conn, userID)
	if !s.Hub.Register(client) { // Hub 已停：直接关，不留孤儿 goroutine
		_ = conn.Close()
		return
	}
	// ServeHTTP 返回即取消 Request.Context()；WithoutCancel 保留 trace/request_id 等值，脱离取消链。
	// 直接传 c.Request.Context() 会让 handler 里的 SendToUser/Broadcast 随机拿到 context.Canceled。
	ctx := context.WithoutCancel(c.Request.Context())
	go client.WritePump()
	go client.ReadPump(ctx, s.Handlers)
}
```

## Hub：纯 actor

字段：`register/unregister/broadcast/direct` 四个请求 channel（`unregister` 携带关闭码与原因）、`done`（Run 退出时 close）、`clients map[*Client]struct{}`、`users map[string]map[*Client]struct{}`（`SendToUser` 索引）、`count atomic.Int64`（给 metrics 与全局上限读，不碰 map）。`Run` 必须先于 `ListenAndServe` 启动：`register` 无缓冲，Hub 没跑时 `Register` 会把 handler 永久卡住。

```go
func (h *Hub) Run(ctx context.Context) {
	defer close(h.done)
	for {
		select {
		case <-ctx.Done():
			h.shutdown()
			return
		case c := <-h.register:
			if set := h.users[c.userID]; len(set) >= h.maxPerUser {
				c.kick(websocket.ClosePolicyViolation, "too many connections") // 也可改为踢掉最旧的一条
				continue
			}
			h.add(c)
		case u := <-h.unregister:
			h.remove(u.c, u.code, u.reason)
		case msg := <-h.broadcast:
			for c := range h.clients {
				h.deliver(c, msg)
			}
		case d := <-h.direct:
			for c := range h.users[d.userID] {
				h.deliver(c, d.data)
			}
		}
	}
}

func (h *Hub) deliver(c *Client, msg []byte) {
	select {
	case c.send <- msg:
	default:
		logger.Warn("slow consumer, dropping connection", zap.String("user_id", c.userID))
		h.remove(c, websocket.CloseTryAgainLater, "slow consumer")
	}
}

func (h *Hub) shutdown() {
	deadline := time.After(5 * time.Second)
	for c := range h.clients {
		c.kick(websocket.CloseGoingAway, "server shutdown")
	}
	for c := range h.clients {
		select {
		case <-c.closed:
		case <-deadline:
			_ = c.conn.Close()
		}
	}
	h.clients, h.users = nil, nil
	h.count.Store(0)
}
```

```go
func (h *Hub) Register(c *Client) bool {
	select {
	case h.register <- c:
		return true
	case <-h.done:
		return false
	}
}

func (h *Hub) Unregister(c *Client, code int, reason string) {
	select {
	case h.unregister <- unregReq{c: c, code: code, reason: reason}:
	case <-h.done:
	}
}

func (h *Hub) Broadcast(ctx context.Context, msg []byte) error {
	select {
	case h.broadcast <- msg:
		return nil
	case <-h.done:
		return ErrHubClosed
	case <-ctx.Done():
		return ctx.Err()
	}
}
```

build 目录的 `hub_test.go` 在 `-race` 下并发 `Broadcast`/`SendToUser`/`Len` 与连接进出交错，断言 ctx 取消后客户端收到 1001、`Run` 返回、且 Hub 退出后所有入口立即返回——这是"无数据竞争、无退出泄漏"两条契约的反证测试；`kick_race_test.go` 让客户端反复发坏封包触发 readPump 侧踢出，同时另一 goroutine 持续 `Broadcast`，断言收到 1003 且无 panic——这是"只有 Hub 关 send"的反证测试。

## 读写泵

```go
const (
	writeWait      = 10 * time.Second
	pongWait       = 50 * time.Second
	pingPeriod     = pongWait * 9 / 10 // 45s < 60s
	maxMessageSize = 64 << 10
)

// 只允许 Hub goroutine 调用：deliver 与 close(send) 若在两个 goroutine 里交错，就是 panic: send on closed channel。
func (c *Client) kick(code int, reason string) {
	c.kickOnce.Do(func() {
		c.code, c.reason = code, reason
		close(c.send)
	})
}
```

```go
func (c *Client) ReadPump(ctx context.Context, handlers map[string]Handler) {
	code, reason := websocket.CloseNormalClosure, ""
	// 退出只把关闭码交给 Hub：send 由 Hub 在 remove 里关闭，conn 由 writePump 写完 Close 帧后关闭。
	defer func() { c.hub.Unregister(c, code, reason) }()
	c.conn.SetReadLimit(maxMessageSize) // 超限：向对端发 1009 并返回 ErrReadLimit
	_ = c.conn.SetReadDeadline(time.Now().Add(pongWait))
	c.conn.SetPongHandler(func(string) error { return c.conn.SetReadDeadline(time.Now().Add(pongWait)) })
	for {
		_, raw, err := c.conn.ReadMessage()
		if err != nil {
			if websocket.IsUnexpectedCloseError(err, websocket.CloseGoingAway, websocket.CloseNormalClosure) {
				logger.WarnCtx(ctx, "ws read", zap.String("user_id", c.userID), zap.Error(err))
			}
			return
		}
		if !c.limiter.Allow() {
			code, reason = websocket.ClosePolicyViolation, "rate limit"
			return
		}
		var env Envelope
		if err := json.Unmarshal(raw, &env); err != nil || env.Type == "" {
			code, reason = websocket.CloseUnsupportedData, "bad envelope"
			return
		}
		h, ok := handlers[env.Type] // 白名单：未知 type 直接丢，不做"透传广播"
		if !ok {
			continue
		}
		if err := h(ctx, c, env.Payload); err != nil {
			logger.WarnCtx(ctx, "ws handler", zap.String("type", env.Type), zap.Error(err))
		}
	}
}
```

writePump 是唯一 writer，也是 `conn.Close` 的唯一常规调用方：`send` 被关闭时把 `kick` 记录的关闭码写成 Close 帧再退出并关 conn（readPump 先关 conn 会让 Close 帧写不出去，客户端拿到的是 1006）；正常消息用 `NextWriter` 把 `send` 里积压的 `len(c.send)` 条合并成一帧（客户端按 `\n` 拆），高频小消息下 syscall 次数下降一个量级。

```go
		case msg, ok := <-c.send:
			_ = c.conn.SetWriteDeadline(time.Now().Add(writeWait))
			if !ok { // Hub 关了 send：把关闭码写出去再退出
				_ = c.conn.WriteControl(websocket.CloseMessage,
					websocket.FormatCloseMessage(c.code, c.reason), time.Now().Add(writeWait))
				return
			}
			w, err := c.conn.NextWriter(websocket.TextMessage)
			if err != nil {
				return
			}
			_, _ = w.Write(msg)
			for range len(c.send) { // 客户端按 '\n' 拆分
				_, _ = w.Write([]byte{'\n'})
				_, _ = w.Write(<-c.send)
			}
			if err := w.Close(); err != nil {
				return
			}
```

## 背压策略

`deliver` 里 `select default` 命中即缓冲满。四种处置，按业务选一种写死，不要运行时可配：

| 策略 | 做法 | 适用 |
|---|---|---|
| 断开（示例默认） | `h.remove(c)`，客户端重连后全量同步 | 聊天、协作等不能丢消息的场景，把"补数据"责任交给重连 |
| 丢最旧 | `<-c.send` 弹出一条再 `send <- msg` | 行情、位置等只关心最新值 |
| 合并 | 同 key 新值覆盖旧值（`map` + 定时 flush） | 仪表盘、计数器 |
| 降级拉取 | 发一条 `{"type":"resync"}` 让客户端走 REST | 消息体大、积压意味着客户端已落后太多 |

## 优雅关闭时序

与 go-microservice 的顺序衔接：`/readyz` 先翻红让 LB 摘流 → `srv.Shutdown(ctx)` 拒绝新升级并等普通请求 → 取消 Hub ctx，`shutdown` 给每个客户端 1001 并最多等 5s 让 Close 帧写出 → 等 `Run` 返回 → 关依赖。整段时长必须小于 k8s `terminationGracePeriodSeconds`。客户端拿到 1001 才会按退避重连，拿到 RST 会立即重连形成惊群。

## 水平扩展

- 多实例时 Hub 是单机内存，跨实例广播走 Redis Pub/Sub（客户端用法见 go-redis-patterns；它是 at-most-once，订阅者断线期间的消息丢失，不能丢就用 Redis Streams / Kafka / NATS JetStream）。每个实例订阅同一 channel，收到后本地 `Broadcast`。
- 在线状态集中存 Redis（`user_id → 实例 ID` 带 TTL，由心跳续期），`SendToUser` 先查所在实例再定向发布，避免全量广播。
- LB 不需要会话粘性：连接建立后就固定在一台机器；需要的是 LB idle timeout > ping 周期。

## 连接数与资源

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

## SSE 正确实现

- 头部：`Content-Type: text/event-stream`、`Cache-Control: no-cache`、`X-Accel-Buffering: no`（Nginx）。不设 `Connection: keep-alive`——HTTP/1.1 默认即是，HTTP/2 下该头非法且被 Go 服务端静默删除。
- `http.NewResponseController(w)`（Go 1.20）穿透中间件包装调用 `Flush`/`SetWriteDeadline`；不支持时返回 `http.ErrNotSupported`，此时直接 return，不能再回 JSON——Content-Type 已经是 event-stream。
- `retry:` 告诉浏览器重连间隔，值要带抖动（固定 3000 会让实例重启后所有客户端同刻回来）；WebSocket 侧没有这个字段，抖动只能写在客户端：指数退避 + `random(0, base)` 偏移，服务端能做的是关闭时发 1001 而不是让对端拿 RST。
- `id:` 单调递增，重连时读 `Last-Event-ID` 从环形缓冲补发；三种情况必须先发 `event: reset` 让客户端全量重拉——缓冲已覆盖、ID 非数字、ID 超过本进程发过的最大值（进程重启后 `nextID` 归零，老客户端就落在这一类）。慢订阅者关 channel 令其重连补发，而不是静默丢事件。
- `data:` 必须单行（JSON 序列化后天然满足）；心跳用注释行 `: ping`，客户端忽略、代理不会因空闲断开。

```go
func (b *Broker) Publish(typ string, data []byte) {
	b.mu.Lock()
	defer b.mu.Unlock()
	b.nextID++
	ev := Event{ID: b.nextID, Type: typ, Data: data}
	if len(b.ring) == cap(b.ring) {
		copy(b.ring, b.ring[1:])
		b.ring = b.ring[:len(b.ring)-1]
	}
	b.ring = append(b.ring, ev)
	for ch := range b.subs {
		select {
		case ch <- ev:
		default: // 订阅者积压：断开让它带 Last-Event-ID 重连
			delete(b.subs, ch)
			close(ch)
		}
	}
}
```

```go
func (b *Broker) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	var lastID uint64
	var badID bool
	if v := r.Header.Get("Last-Event-ID"); v != "" {
		id, err := strconv.ParseUint(v, 10, 64)
		// 非法值不能当 0：那等于"只订阅新事件"，客户端自以为已同步、实际整段丢失。一律走 reset。
		lastID, badID = id, err != nil
	}
	rc := http.NewResponseController(w)
	h := w.Header()
	h.Set("Content-Type", "text/event-stream")
	h.Set("Cache-Control", "no-cache")
	h.Set("X-Accel-Buffering", "no") // Nginx 不缓冲
	w.WriteHeader(http.StatusOK)
	if err := rc.Flush(); err != nil { // ErrNotSupported：中间件包了不支持 Flush 的 writer
		logger.WarnCtx(r.Context(), "sse flush unsupported", zap.Error(err))
		return
	}
	ch, replay, reset, unsub := b.Subscribe(lastID)
	defer unsub()
	write := func(format string, args ...any) error {
		if err := rc.SetWriteDeadline(time.Now().Add(writeWait)); err != nil && !errors.Is(err, http.ErrNotSupported) {
			return err // 不支持续期的 writer（如被中间件包裹）只能依赖服务器 WriteTimeout=0
		}
		if _, err := fmt.Fprintf(w, format, args...); err != nil {
			return err // 客户端已断：立刻退出，不等 ctx
		}
		return rc.Flush()
	}
	// 重连间隔带抖动：固定值会让实例重启后所有客户端同刻回来，把刚起来的进程再打死。
	if err := write("retry: %d\n\n", 3000+rand.IntN(2000)); err != nil {
		return
	}
	if reset || badID {
		if err := write("event: reset\ndata: {}\n\n"); err != nil {
			return
		}
	}
	for _, ev := range replay {
		if err := write("id: %d\nevent: %s\ndata: %s\n\n", ev.ID, ev.Type, ev.Data); err != nil {
			return
		}
	}
	b.loop(r.Context(), ch, write)
}

		case <-tick.C:
			if err := write(": ping\n\n"); err != nil { // 注释行：客户端忽略，只为探活与保活代理
				return
			}
```

build 目录的 `broker_test.go` 断言 `Last-Event-ID=1` 时补发 2、3 且不 reset，缓冲覆盖后发 reset，非数字与超前 ID 也发 reset——`id:` 字段的契约由它兜底。

## 何时不该用长连接

| 场景 | 选择 | 理由 |
|---|---|---|
| 更新频率低于每分钟一次 | 轮询 | 心跳流量比业务流量还大 |
| 客户端是无浏览器的批处理 / 脚本 | Webhook 或队列 | 长连接的重连、心跳、粘性全是负担 |
| 移动端弱网 | SSE + 短 `retry` 或 MQTT | WebSocket 在网络切换时的半开连接靠 ping 才能发现，延迟 = pongWait |
| 需要严格 at-least-once 送达 | MQ + 拉取确认 | Hub 内存队列在进程重启时全丢，补发只能覆盖环形缓冲窗口 |
| 网关不支持 HTTP/2 | WebSocket 而非 SSE | 见核心规则 1 |

## 审查清单

- [ ] 鉴权、Origin、全局上限在 `Upgrade` 之前；`CheckOrigin` 不是 `return true`
- [ ] 每条连接只有 writePump 调用写方法；Hub 与业务代码 grep 不到 `conn.Write`
- [ ] Hub 的 map 只在 `Run` 内访问；对外计数用 atomic；无 `RWMutex`；`close(c.send)` 只在 Hub goroutine（`kick` 的调用方只有 `remove` / `shutdown` / 注册拒绝）
- [ ] `Register/Unregister/Broadcast/SendToUser` 全部 `select` 上 `done`
- [ ] `SetReadLimit`、`SetReadDeadline` + pong 续期、每次写前 `SetWriteDeadline`；pingPeriod < 所有中间层 idle timeout
- [ ] pump 拿到的是 `context.WithoutCancel(c.Request.Context())`
- [ ] Hub 关闭发 1001 并等待 Close 帧写出；主流程等 `Run` 返回后才关依赖
- [ ] 入站有封包、type 白名单、每连接限速；缓冲满的策略明确且写在 `deliver`
- [ ] 每用户上限、全局上限、建连速率三层都有；`ulimit -n` / `LimitNOFILE` 已调
- [ ] 指标：连接数、消息计数、握手失败、队列深度；label 无 user_id
- [ ] 多实例：跨实例广播走 Pub/Sub 或 Streams；在线状态在 Redis 且带 TTL
- [ ] SSE：Flush 不支持时直接 return；`WriteTimeout` 为 0 或每次续期；读 `Last-Event-ID` 并补发，非法/超前 ID 发 `reset`；`retry:` 带抖动；心跳注释行；写错误即 return；无 `Connection` 头
- [ ] `-race` 下有并发进出 + 广播 + 关闭的测试
