# SSE 正确实现

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
