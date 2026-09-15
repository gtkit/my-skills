# gRPC 基础

```go
// UnaryLogging 记录每个 RPC 的方法、耗时、状态码。metrics 在同一位置打点（见 go-observability）。
func UnaryLogging() grpc.UnaryServerInterceptor {
	return func(ctx context.Context, req any, info *grpc.UnaryServerInfo, handler grpc.UnaryHandler) (any, error) {
		start := time.Now()
		resp, err := handler(ctx, req)
		code := status.Code(err) // err 为 nil 时返回 codes.OK；非 status 错误返回 Unknown
		fields := []zap.Field{
			zap.String("method", info.FullMethod),
			zap.Duration("duration", time.Since(start)),
			zap.String("code", code.String()),
		}
		switch code {
		case codes.OK:
			logger.InfoCtx(ctx, "rpc", fields...)
		case codes.Canceled, codes.DeadlineExceeded, codes.InvalidArgument, codes.NotFound:
			logger.WarnCtx(ctx, "rpc", fields...) // 调用方问题或调用方放弃，不是本服务故障
		default:
			logger.ErrorCtx(ctx, "rpc", append(fields, zap.Error(err))...)
		}
		return resp, err
	}
}
```

流拦截器（`StreamLogging`，`grpc.StreamServerInterceptor` 签名）只在流结束记一条，逐消息记日志会把日志量放大到不可用。

```go
// ToStatus 把业务错误映射成 gRPC status；ctx 错误必须映射，否则客户端只看到 Unknown。
func ToStatus(err error) error {
	switch {
	case err == nil:
		return nil
	case errors.Is(err, context.DeadlineExceeded):
		return status.Error(codes.DeadlineExceeded, "deadline exceeded")
	case errors.Is(err, context.Canceled):
		return status.Error(codes.Canceled, "canceled")
	case errors.Is(err, ErrNotFound):
		st, derr := status.New(codes.NotFound, "resource not found").WithDetails(
			&errdetails.ErrorInfo{Reason: "ORDER_NOT_FOUND", Domain: "order.example.com"})
		if derr != nil {
			return status.Error(codes.NotFound, "resource not found")
		}
		return st.Err()
	default:
		return status.Error(codes.Internal, "internal error") // 5xx 同理：不回显 err.Error()
	}
}

// NewServer 装配拦截器链、keepalive 与健康检查协议。
func NewServer() (*grpc.Server, *health.Server) {
	srv := grpc.NewServer(
		grpc.ChainUnaryInterceptor(UnaryLogging()),
		grpc.ChainStreamInterceptor(StreamLogging()),
		grpc.KeepaliveParams(keepalive.ServerParameters{
			MaxConnectionAge:      30 * time.Minute, // 定期换连接，让客户端重新做负载均衡；内置 ±10% 抖动
			MaxConnectionAgeGrace: 30 * time.Second,
			Time:                  2 * time.Minute, // 默认 2h，NAT/LB 早就把空闲连接丢了
			Timeout:               20 * time.Second,
		}),
		grpc.KeepaliveEnforcementPolicy(keepalive.EnforcementPolicy{
			MinTime:             time.Minute, // 默认 5min；客户端 ping 更频繁会被 GOAWAY 断开
			PermitWithoutStream: true,
		}),
	)
	hs := health.NewServer() // 关闭时先 hs.Shutdown() 置 NOT_SERVING，等 endpoint 摘除再 srv.GracefulStop()
	grpc_health_v1.RegisterHealthServer(srv, hs)
	// 空服务名默认已是 SERVING（源码）；探针按服务名查询时必须显式注册，否则返回 NotFound 被判失败
	hs.SetServingStatus("order.v1.OrderService", grpc_health_v1.HealthCheckResponse_SERVING)
	return srv, hs
}
```

| 项 | 事实（grpc-go v1.83 go doc） | 决策 |
|---|---|---|
| deadline | 客户端 ctx deadline 自动编码为 `grpc-timeout` 头，服务端 ctx 带同一 deadline | 不要再造 header；HTTP 才需要 `X-Request-Deadline` |
| keepalive | 客户端默认关闭；服务端 `Time` 默认 2h；`EnforcementPolicy.MinTime` 默认 5min，客户端 ping 更频繁会被 GOAWAY | 两端一起配，客户端 `Time` ≥ 服务端 `MinTime` |
| `WaitForReady` | 默认 false：TRANSIENT_FAILURE 时 RPC 立即失败 | 保持 false，让重试/熔断接手；true 只用于启动预热 |
| `grpc.NewClient` | 不做 I/O；不传 `WithTransportCredentials` 返回 `no transport security set`（实测） | 客户端 `WithKeepaliveParams{Time: 2m, Timeout: 20s, PermitWithoutStream: true}` |
| `MaxConnectionAge` | 服务端定期 GOAWAY 换连接，内置 ±10% 抖动 | 配 30min 级别，否则 k8s 扩容后新 Pod 收不到长连接流量 |
| `status.Code(nil)` | 返回 `codes.OK`；非 status 错误返回 `Unknown` | handler 出口统一过 `ToStatus` |
