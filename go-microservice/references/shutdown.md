# 优雅关闭

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
