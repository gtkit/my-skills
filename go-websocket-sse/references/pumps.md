# 读写泵

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
