---
name: go-microservice
description: Go 微服务进程边界：优雅关闭与 k8s 发布时序、/livez /readyz、幂等键、http.Client 连接池、gRPC 拦截器/keepalive/status 映射、超时预算逐跳传播、服务发现。处理服务启停、探针、服务间调用时使用。
allowed-tools: "Read, Write, Edit, Bash, Glob, Grep"
---

# Go 微服务：生命周期与服务间通信

一个请求从入口到下游的"进程边界"问题：怎么停、怎么被探活、怎么防重放、怎么调别人。限流、熔断、重试、超时值怎么定归 go-stability-engineering；本文只放传播代码。

## 核心规则

1. `ListenAndServe` 与 `Shutdown` 的错误经 `errgroup` 收敛到 main 统一处理；goroutine 里 `Fatal` 会 `os.Exit` 跳过全部 defer，日志不刷、连接不关。
2. `http.Server` 必设 `ReadHeaderTimeout`（gosec G112）；`Shutdown` 超时 + `preStop` 时长 < `terminationGracePeriodSeconds`，否则被 SIGKILL 时仍有在途请求。
3. `/livez` 只回 200，不查任何依赖；`/readyz` 查依赖，每个依赖独立 2s 超时，响应只有 up/down。
4. 幂等记录是状态机 `none → processing → done(result)`：processing 返回 409，done 返回缓存结果；`SetNX` 失败就 `return nil` 是把"别人正在做"报告成"已成功"。
5. 出站 HTTP 复用一个 `http.Client`；`MaxIdleConnsPerHost` 默认只有 2；`resp.Body` 必须读尽再 Close，否则连接不能归还池。
6. gRPC 服务端 handler 返回的错误必须是 `status` 错误，`context` 错误映射到 `Canceled`/`DeadlineExceeded`，否则客户端只看到 `Unknown`。
7. 超时预算传绝对截止时刻（`ctx.Deadline()`），逐跳只减不增；剩余不足以覆盖本跳就直接失败，不发起注定超时的调用。
8. 网格（Istio）已接管重试/熔断/超时时，SDK 侧同类能力必须关掉，否则重试次数相乘、超时互相覆盖。

## 优雅关闭

关闭是四步串行：readiness 翻红 → 等 endpoint 摘除 → 排空在途请求 → 逆序关依赖。每一步都有时间上限，加起来必须小于 k8s 的宽限期。

```go
// Closer 是需要在 HTTP 排空后关闭的依赖（DB、Redis、MQ）。
type Closer interface{ Close() error }

func main() {
	logger.SetDefault(logger.MustNew(logger.WithLevel("info"), logger.WithOutJSON(true), logger.WithConsole(true)))
	defer logger.Sync()

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	checker := health.NewChecker(map[string]health.Pinger{ /* "db": sqlDB.PingContext, ... */ })
	mux := http.NewServeMux()
	mux.HandleFunc("GET /livez", health.Livez)
	mux.HandleFunc("GET /readyz", checker.Readyz)

	srv := &http.Server{
		Addr:              ":8080",
		Handler:           mux,
		ReadHeaderTimeout: 5 * time.Second,  // 防 Slowloris，gosec G112
		ReadTimeout:       15 * time.Second, // 含 body；上传接口按路由单独放宽
		WriteTimeout:      30 * time.Second, // SSE/WebSocket 路由用 ResponseController 另设
		IdleTimeout:       120 * time.Second,
	}
	// 被 hijack 的 WebSocket 连接不受 Shutdown 管理，在此触发 hub 关闭（不阻塞）。
	srv.RegisterOnShutdown(func() { logger.Info("notify hijacked connections to close") })
	var deps []Closer // 初始化顺序 DB → Redis → MQ，关闭时逆序

	g, gctx := errgroup.WithContext(ctx)
	g.Go(func() error {
		// 禁止在这里 Fatal：os.Exit 会跳过所有 defer，日志不刷、依赖不关。
		if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			return err // errgroup 取消 gctx，唤醒下面的 Shutdown 分支
		}
		return nil
	})
	g.Go(func() error {
		<-gctx.Done()           // 收到 SIGTERM，或 ListenAndServe 失败
		checker.SetReady(false) // readiness 先翻红；endpoint 摘除是异步的，靠 preStop sleep 等它生效
		// preStop 5s + 排空 20s + 关依赖/刷日志余量 5s = terminationGracePeriodSeconds 30s，见时序表
		sctx, cancel := context.WithTimeoutCause(context.Background(), 20*time.Second, errors.New("drain timeout"))
		defer cancel()
		if err := srv.Shutdown(sctx); err != nil { // 超时只记日志并继续关依赖，不在这里退出
			logger.Error("http shutdown not clean", zap.Error(err), zap.NamedError("cause", context.Cause(sctx)))
			return err
		}
		return nil
	})
	err := g.Wait()
	for i := len(deps) - 1; i >= 0; i-- {
		if cerr := deps[i].Close(); cerr != nil {
			logger.Error("close dependency", zap.Error(cerr))
		}
	}
	if err != nil {
		logger.Error("server exited with error", zap.Error(err))
		logger.Sync()
		os.Exit(1)
	}
	logger.Info("server exited")
}
```

`Shutdown` 只关 listener、等活跃连接变空闲；被 `Hijack` 的 WebSocket 连接不在其管理范围（go doc 原文：does not attempt to close nor wait for hijacked connections），必须用 `RegisterOnShutdown` 触发 hub 关闭并自己等待（连接管理见 go-websocket-sse）。

k8s 发布时序（`terminationGracePeriodSeconds` 默认 30s，倒计时从 Pod 进入 Terminating 开始，**包含 preStop**）：

| 时刻 | 发生什么 | 服务侧动作 |
|---|---|---|
| T+0 | Pod 标记 Terminating；endpoint 摘除与 preStop **并行**开始 | — |
| T+0 ~ T+5s | `preStop: exec sleep 5`，等 kube-proxy/Ingress 同步完 endpoint | 仍在正常服务，此时新流量还会进来 |
| T+5s | preStop 结束，kubelet 发 SIGTERM | `SetReady(false)`；`Shutdown(20s)` 开始排空 |
| T+5s ~ T+25s | 排空在途请求 | 新连接被拒绝（listener 已关） |
| T+25s ~ T+30s | 逆序关 DB/Redis/MQ；`logger.Sync()` | 排空超时也要走到这里，余量 5s |
| T+30s | 宽限期到，SIGKILL | 到这一步就是事故：说明 20s 内没排空且关依赖也超时 |

没有 preStop sleep 时，SIGTERM 到达早于 endpoint 摘除，关闭期间仍有新请求被路由进来并收到 connection refused——这是"发布期间 5xx 抖动"的最常见原因。

## 健康检查

```go
// Readyz 检查依赖，失败只把 Pod 从 Service endpoint 摘掉，不重启。
// 每个依赖独立 2s 超时并行检查，总耗时受最慢者约束而非求和：串行时 5 个依赖最坏 10s，
// 远超 kubelet 默认 timeoutSeconds=1，探针会先超时重试、请求堆积（go-gin-api 的 gin 版实现相同）。
func (c *Checker) Readyz(w http.ResponseWriter, r *http.Request) {
	type result struct {
		Status string            `json:"status"`
		Checks map[string]string `json:"checks"`
	}
	if !c.ready.Load() {
		http.Error(w, "shutting down", http.StatusServiceUnavailable)
		return
	}
	res := result{Status: "up", Checks: make(map[string]string, len(c.deps))}
	code := http.StatusOK
	var mu sync.Mutex
	var wg sync.WaitGroup
	for name, ping := range c.deps {
		wg.Go(func() {
			ctx, cancel := context.WithTimeout(r.Context(), perCheckTimeout)
			defer cancel()
			err := ping(ctx)
			mu.Lock()
			defer mu.Unlock()
			if err != nil {
				// 只返回 up/down；err.Error() 常含 DSN、主机名，进日志不进响应。
				logger.WarnCtx(r.Context(), "readiness check failed", zap.String("dep", name), zap.Error(err))
				res.Checks[name], res.Status, code = "down", "down", http.StatusServiceUnavailable
				return
			}
			res.Checks[name] = "up"
		})
	}
	wg.Wait()
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(res)
}
```

`Livez` 只写 `w.WriteHeader(http.StatusOK)`；`perCheckTimeout` 是包级常量 2s；`Checker.ready` 是 `atomic.Bool`，`SetReady(false)` 让 `Readyz` 直接回 503，是关闭流程的第一步。

| 探针 | 检查什么 | 失败后果 | 常见错误 |
|---|---|---|---|
| `livenessProbe` → `/livez` | 进程能响应 HTTP | kubelet 重启容器 | 带上 DB 检查：DB 抖动 → 全部 Pod 重启 → 连接重建风暴压垮 DB |
| `readinessProbe` → `/readyz` | 依赖可用、未在关闭 | 摘出 Service endpoint，不重启 | 用 `r.Context()` 直接 Ping 无超时，或串行检查多个依赖：耗时求和超过 kubelet `timeoutSeconds`，探针卡死后重试堆积 |
| `startupProbe` → `/readyz` | 启动完成（预热缓存、建连接池） | 成功前 liveness 不生效 | 不配 startupProbe 而把 liveness 的 `initialDelaySeconds` 调大，慢启动仍被误杀 |
| gRPC 探针 → `grpc.health.v1` | k8s 1.24+ 原生 `grpc` 探针 | 同上 | 探针 `service` 填了未 `SetServingStatus` 的服务名 → `NotFound` 判失败；空服务名默认 SERVING（grpc-go 源码） |

## 幂等

幂等键的存储与事务实现见 go-data-consistency；这里只定义接口与状态机（`State` 取值 `StateNone/StateProcessing/StateDone`；processing 记录必须带过期时间，执行中进程崩溃留下的 processing 过期后由 `Begin` 接管视同 none，因此 `fn` 必须可重入）。存储首选 DB 唯一键；Redis 主从切换会丢 key，只能做 DB 前面的加速层。

这个 `Store` 是**通用应用层幂等**：`fn` 的业务写入与 `Done` 是两次独立提交，两者之间有窗口——业务已落库而 `Done` 失败时记录停在 processing，靠过期接管重做，调用方拿到的错误不代表"未执行"。窗口只能消除、不能靠这个接口收窄：业务写入与幂等键在同一个库时，把 `INSERT idempotency_key` 放进业务事务本身，唯一键冲突即重复，此时不需要 processing 态、也不需要 `Done`（实现见 go-data-consistency）。跨库或写入在下游服务时才用本接口，并接受"可重入"这个前提。

```go
var ErrInProgress = errors.New("idempotent request in progress")

// Store 的实现见 go-data-consistency：首选 DB 唯一键；Redis 只做 DB 前面的加速层。
type Store interface {
	// Begin 原子地把 key 置为 processing；已存在时返回当前状态与缓存结果。
	Begin(ctx context.Context, key string) (State, []byte, error)
	// Done 写入结果并置为 done。它与业务写入是两次独立提交：业务已落库而 Done 失败时，
	// 记录留在 processing，等过期后被下一次 Begin 接管重做——所以 fn 必须可重入。
	Done(ctx context.Context, key string, result []byte) error
	// Fail 删除 processing 记录，允许调用方重试。只在业务确定失败时调用。
	Fail(ctx context.Context, key string) error
}

// Execute 是幂等执行的唯一入口：processing 返回 ErrInProgress（HTTP 409），done 返回缓存结果。
func Execute(ctx context.Context, st Store, key string, fn func(ctx context.Context) ([]byte, error)) ([]byte, error) {
	state, cached, err := st.Begin(ctx, key)
	if err != nil {
		return nil, err
	}
	switch state {
	case StateDone:
		return cached, nil // 重放：返回首次的响应，而不是再执行一次
	case StateProcessing:
		return nil, ErrInProgress // 绝不能 return nil：那是把"别人正在做"报告成"已成功"
	}
	result, err := fn(ctx)
	if err != nil {
		if ferr := st.Fail(context.WithoutCancel(ctx), key); ferr != nil {
			return nil, errors.Join(err, ferr)
		}
		return nil, err
	}
	// Done 同样用 WithoutCancel：fn 已产生副作用，客户端此刻断开不能让记录卡在 processing。
	if err := st.Done(context.WithoutCancel(ctx), key, result); err != nil {
		return nil, err
	}
	return result, nil
}
```

原实现 `SetNX(key, "processing")` 失败即 `return nil`，三个独立缺陷叠加成 P0：并发第二个请求在第一个仍在处理时被告知"成功"（实际可能失败）；进程在 SetNX 与 Del 之间崩溃，key 残留 10 分钟内所有重试都被当作已成功；没存结果，重放无法返回原响应，调用方只能拿到空成功。

## HTTP 客户端

```go
// New 进程内每个下游一个 Client 并复用：每次 &http.Client{} 都新建 Transport，
// 连接池失效、TIME_WAIT 与 TLS 握手数随 QPS 线性增长。
func New(perHostConns int) *http.Client {
	tr := &http.Transport{
		DialContext:           (&net.Dialer{Timeout: 3 * time.Second, KeepAlive: 30 * time.Second}).DialContext,
		MaxIdleConns:          perHostConns * 4,
		MaxIdleConnsPerHost:   perHostConns, // 默认 DefaultMaxIdleConnsPerHost = 2，高并发下几乎等于没有连接池
		IdleConnTimeout:       90 * time.Second,
		TLSHandshakeTimeout:   5 * time.Second,
		ResponseHeaderTimeout: 10 * time.Second, // 只管首字节；整体超时靠 ctx deadline
	}
	return &http.Client{
		// otelhttp 在出站请求注入 traceparent；需 main 里已装 TracerProvider + Propagator（见 go-observability）
		Transport: otelhttp.NewTransport(tr),
		// 不设 Client.Timeout：它会和 ctx deadline 竞争，且不区分"连接慢"与"读 body 慢"
	}
}

// GetJSON 演示出站请求的四个必做项：ctx、err 检查、Body 关闭、读尽 body 以复用连接。
func GetJSON[T any](ctx context.Context, c *http.Client, url string) (T, error) {
	var zero T
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil { // url 非法时在这里失败，忽略 err 会得到 nil req 并 panic
		return zero, fmt.Errorf("build request: %w", err)
	}
	resp, err := c.Do(req)
	if err != nil {
		return zero, err // 已含 url 与 method，不再包装
	}
	defer func() { // 未读尽的 body 无法归还连接池；LimitReader 防超大响应拖住 goroutine
		_, _ = io.Copy(io.Discard, io.LimitReader(resp.Body, 64<<10))
		_ = resp.Body.Close()
	}()
	if resp.StatusCode != http.StatusOK {
		return zero, &StatusError{Code: resp.StatusCode}
	}
	var out T
	if err := json.NewDecoder(io.LimitReader(resp.Body, 8<<20)).Decode(&out); err != nil {
		return zero, fmt.Errorf("decode response: %w", err)
	}
	return out, nil
}
```

`GetJSON` 的四个必做项：`http.NewRequestWithContext` 检查 err（url 非法时 req 为 nil，忽略 err 会 panic）；方法用 `http.MethodGet` 常量；`resp.Body` 必 Close；Close 前读尽（`io.Copy(io.Discard, io.LimitReader(...))`），未读尽的连接不能复用。状态码映射成实现 `Retryable()`/`Permanent()` 的 `StatusError`（只有 429/502/503/504 可重试，与 go-error-handling 一致），交给 go-stability-engineering 的重试与熔断判定。

## gRPC 基础

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

## 超时预算传播

```go
// Remaining 返回 ctx 剩余预算；无 deadline 时返回 fallback。
func Remaining(ctx context.Context, fallback time.Duration) time.Duration {
	dl, ok := ctx.Deadline()
	if !ok {
		return fallback
	}
	return time.Until(dl)
}

// ForHop 为一次下游调用派生 ctx：取 min(剩余预算 - reserve, hopMax)。
// reserve 是留给本服务在下游返回后继续工作（写 DB、序列化响应）的时间；
// 剩余不足时直接失败，不发起注定超时的调用。返回 err 时 ctx 与 cancel 都是 nil：
// 调用方必须先判 err 再 defer cancel()，写成 ctx, cancel, err := ...; defer cancel() 会 panic。
func ForHop(ctx context.Context, hopMax, reserve time.Duration, hop string) (context.Context, context.CancelFunc, error) {
	rem := Remaining(ctx, hopMax) - reserve
	if rem <= 0 {
		return nil, nil, ErrBudgetExhausted
	}
	timeout := min(rem, hopMax)
	cctx, cancel := context.WithTimeoutCause(ctx, timeout, errors.New("hop timeout: "+hop))
	return cctx, cancel, nil
}

// Inject 把当前 ctx 的 deadline 写入出站 HTTP 头。
func Inject(ctx context.Context, req *http.Request) {
	if dl, ok := ctx.Deadline(); ok {
		req.Header.Set(HeaderDeadline, strconv.FormatInt(dl.UnixMilli(), 10))
	}
}
```

传绝对时刻而不是剩余时长：网络与排队耗掉的时间不会被下游"重新计时"。`Extract` 只缩短不放大——上游给的截止晚于本地默认时以本地为准。超时值怎么定、每层留多少 reserve 见 go-stability-engineering。

## 服务发现与网格选型

| 方案 | 适用 | 代价 | 注意 |
|---|---|---|---|
| k8s Service DNS | 全部在 k8s 内，HTTP 或 gRPC | 零 SDK | gRPC 长连接只解析一次，扩容后不均衡：用 headless Service + `dns:///` 客户端 LB，或服务端 `MaxConnectionAge` |
| Nacos | 混合部署（VM + k8s）、需配置中心 | SDK 心跳、注册中心高可用运维 | 与 k8s DNS 二选一，双注册会有两套健康视图 |
| etcd（自建注册） | 已有 etcd、需要 lease/watch 语义 | 自己写注册与摘除 | lease TTL 过短 → 网络抖动即大面积摘除 |
| Consul | 多数据中心、需要 KV 与健康检查一体 | Agent 部署 | gRPC 健康检查用 `grpc.health.v1` 对接 |
| Istio sidecar | 多语言、需要 mTLS/流量镜像/金丝雀 | 每跳 +1~3ms、Envoy 内存 | **关闭 SDK 侧重试/熔断/超时**（重试相乘 3×3=9 倍）；`preStop` 时序要考虑 sidecar 先退出导致出站失败 |

## 服务通信审查清单

- [ ] `http.Server` 四个超时字段都设了；`Shutdown` 超时 + preStop < `terminationGracePeriodSeconds`
- [ ] 没有任何 goroutine 里的 `logger.Fatal` / `os.Exit`；`errors.Is(err, http.ErrServerClosed)` 而非 `==`
- [ ] SIGTERM 后第一步是 readiness 翻红；有 `preStop sleep`
- [ ] WebSocket/SSE 连接有独立关闭路径（`RegisterOnShutdown` + hub）
- [ ] `/livez` 无依赖检查；`/readyz` 每依赖独立超时，响应不含 `err.Error()`
- [ ] 幂等：processing 返回 409，done 返回缓存结果；存储用 DB 唯一键
- [ ] 每个下游一个复用的 `http.Client`；`MaxIdleConnsPerHost` 按并发设；Body 读尽再 Close
- [ ] `http.NewRequestWithContext` 的 err 被检查；方法与状态码用常量
- [ ] gRPC handler 出口统一 `ToStatus`；两端 keepalive 一起配；健康检查协议已注册
- [ ] 下游调用用 `ForHop` 派生 ctx；HTTP 出站 `Inject`、入站 `Extract`
- [ ] 有 mesh 时 SDK 侧重试/熔断/超时已关闭
