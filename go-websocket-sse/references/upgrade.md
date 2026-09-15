# WebSocket：升级与连接规则

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
