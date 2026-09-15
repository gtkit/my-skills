# Hub：纯 actor

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
