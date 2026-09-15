# Gin 错误中间件与跨服务映射

## Gin 错误中间件：ctx 取消、request_id、不回显

```go
// ErrorBody 是所有非 2xx 响应的唯一形状。request_id 让用户报障时能直接定位到日志。
type ErrorBody struct {
	Code      int    `json:"code"`
	Message   string `json:"message"`
	RequestID string `json:"request_id,omitzero"`
}

// Errors 必须注册在业务中间件之前（它在 c.Next() 之后工作）。
// handler 里只做 `_ = c.Error(err); c.Abort(); return`，不自己写错误响应。
func Errors() gin.HandlerFunc {
	return func(c *gin.Context) {
		c.Next()
		if len(c.Errors) == 0 || c.Writer.Written() {
			return // handler 已写响应再写一次会触发 "superfluous response.WriteHeader" 并输出两段 body
		}
		err := c.Errors.Last().Err
		ctx := c.Request.Context()
		ae := apperror.From(err)
		fields := []zap.Field{zap.Int("code", ae.Code), zap.Int("status", ae.HTTP), zap.Error(err)}
		switch {
		case ae.HTTP == apperror.StatusClientClosedRequest || ae.HTTP == http.StatusGatewayTimeout:
			logger.WarnCtx(ctx, "request aborted", fields...) // 客户端断开/超时是噪音，不进 ERROR 告警
		case ae.HTTP >= http.StatusInternalServerError:
			logger.ErrorCtx(ctx, "request failed", fields...)
		default:
			logger.DebugCtx(ctx, "request rejected", fields...)
		}
		c.JSON(ae.HTTP, ErrorBody{Code: ae.Code, Message: ae.Message, RequestID: logger.RequestIDFromContext(ctx)})
	}
}

// Fail 是 handler 内统一的失败出口。
func Fail(c *gin.Context, err error) {
	_ = c.Error(err)
	c.Abort()
}
```

handler 侧：`if err != nil { ginmw.Fail(c, err); return }`。`c.Error` 有返回值，`_ =` 显式丢弃以过 errcheck。中间件不判 `c.Writer.Written()` 的后果：handler 已写 200 又 `c.Error` 时输出两段 body 并打印 `http: superfluous response.WriteHeader`。

## 跨服务错误映射

```go
// FromGRPC 把下游 gRPC 错误翻译为本服务的 AppError。
// 原则：下游的 Internal/Unknown 对终端用户是 502 "upstream error"，不透传下游文案（含内部主机名、SQL）。
func FromGRPC(err error) error {
	if err == nil {
		return nil
	}
	switch status.Code(err) {
	case codes.NotFound:
		return apperror.Wrap(apperror.ErrNotFound, err)
	case codes.AlreadyExists, codes.FailedPrecondition, codes.Aborted:
		return apperror.Wrap(apperror.ErrConflict, err)
	case codes.InvalidArgument:
		return apperror.Wrap(apperror.ErrInternal, err) // 我们发出了非法请求：是本服务的 bug，不是用户的
	case codes.Unauthenticated, codes.PermissionDenied:
		return apperror.Wrap(apperror.ErrInternal, err) // 服务间凭证问题同理
	case codes.ResourceExhausted:
		return apperror.Wrap(apperror.ErrTooManyRequests, err)
	case codes.DeadlineExceeded:
		return apperror.Wrap(apperror.ErrTimeout, err)
	case codes.Canceled:
		return apperror.Wrap(apperror.ErrClientClosed, err)
	case codes.Unavailable:
		return apperror.Wrap(apperror.ErrUnavailable, err)
	default:
		return apperror.Wrap(apperror.ErrUpstream, err)
	}
}
```

HTTP 下游同理（`downstream.FromHTTP`）：404/409/429/503/504 按语义映射；5xx → 502 `upstream error`；**其余 4xx 表示我们的调用有 bug，对用户是 500**，不能把下游的 400 文案当成用户输入错误返回。
