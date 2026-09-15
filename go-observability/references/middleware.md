# request_id 与访问日志中间件

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
