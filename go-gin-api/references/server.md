# 服务骨架：main、健康检查、Recovery

## main：服务器、超时、优雅关闭

```go
const shutdownTimeout = 20 * time.Second // preStop 5s + 排空 20s + 关依赖余量 5s = terminationGracePeriodSeconds 默认 30s（时序见 go-microservice）

func main() {
	logger.SetDefault(logger.MustNew(logger.WithLevel("info"), logger.WithOutJSON(true), logger.WithConsole(true),
		logger.WithRedactKeys("password", "token", "authorization")))
	defer logger.Sync()

	if err := dto.SetupValidator(); err != nil {
		logger.Fatal("setup validator", zap.Error(err))
	}
	gin.SetMode(gin.ReleaseMode)
	r := gin.New() // gin.Default() 的 Logger/Recovery 写 stdout 且不带 request_id，不用
	if err := r.SetTrustedProxies([]string{"10.0.0.0/8"}); err != nil { // 默认信任 0.0.0.0/0：任何人可伪造 X-Forwarded-For
		logger.Fatal("trusted proxies", zap.Error(err))
	}
	r.MaxMultipartMemory = 8 << 20
	// 顺序即包裹顺序：Recovery 最外层；request_id/日志/metrics 中间件见 go-observability；限流见 go-stability-engineering。
	r.Use(middleware.Recovery(), ginmw.Errors(), middleware.BodyLimit(1<<20), middleware.CORS([]string{"https://app.example.com"}))
	health.Register(r, map[string]health.Checker{})
	api := r.Group("/api/v1", middleware.JWT([]byte(os.Getenv("JWT_SECRET"))), middleware.RouteTimeout(5*time.Second))
	api.GET("/ping", func(c *gin.Context) { c.String(http.StatusOK, "pong") })

	srv := &http.Server{
		Addr:              ":8080",
		Handler:           r,
		ReadHeaderTimeout: 5 * time.Second, // 缺它 = slowloris 直接打穿
		ReadTimeout:       15 * time.Second,
		WriteTimeout:      30 * time.Second, // SSE/长轮询路由需单独用 ResponseController.SetWriteDeadline
		IdleTimeout:       120 * time.Second,
		MaxHeaderBytes:    1 << 20,
	}
	go serveAdmin() // pprof/metrics 只监听本机端口，绝不挂到业务端口

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	go func() {
		if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			logger.Error("listen", zap.Error(err))
			stop()
		}
	}()
	<-ctx.Done()
	// SIGTERM 后 readiness 需先变为失败并等 endpoint 摘除（sleep 数秒），再 Shutdown，否则仍有新连接被路由进来。
	shutdownCtx, cancel := context.WithTimeout(context.Background(), shutdownTimeout)
	defer cancel()
	if err := srv.Shutdown(shutdownCtx); err != nil {
		logger.Error("shutdown", zap.Error(err)) // 超时后仍有活跃连接会被强制断开
	}
}
```

`serveAdmin` 用独立 `http.Server{Addr: "127.0.0.1:6060", ReadHeaderTimeout: 5s}` + 独立 `http.NewServeMux()`，把 `pprof.Index`/`pprof.Profile` 显式注册上去。**不能 `import _ "net/http/pprof"`**：它的 init 把 handler 注册进 `DefaultServeMux`，业务 server 只要用了 `DefaultServeMux`（或任何最终回落到它的 `http.Handle`），`/debug/pprof` 就跟业务一起暴露在业务端口上（同 go-performance）。`Shutdown` 不等待 SSE/WebSocket 这类被 Hijack 或长写的连接，需业务自行关闭（见 go-websocket-sse）。

## 健康检查

```go
// Register：/livez 只证明进程活着——挂上依赖检查后，DB 抖动会让 k8s 重启所有副本，形成重启风暴。
// /readyz 才检查依赖，失败只是摘流量。每个依赖独立 2s 超时并行检查，总耗时受最慢者约束而非求和：
// 串行时 5 个依赖最坏 10s，远超 kubelet 默认 timeoutSeconds=1（与 go-microservice 的 net/http 版实现相同）。
func Register(r gin.IRouter, deps map[string]Checker) {
	r.GET("/livez", func(c *gin.Context) { c.String(http.StatusOK, "ok") })
	r.GET("/readyz", func(c *gin.Context) {
		var mu sync.Mutex
		var wg sync.WaitGroup
		failed := map[string]string{} // 只暴露依赖名：err.Error() 常含 DSN/主机名，进日志不进响应
		for name, check := range deps {
			wg.Go(func() {
				ctx, cancel := context.WithTimeout(c.Request.Context(), perCheckTimeout)
				defer cancel()
				if err := check(ctx); err != nil {
					logger.WarnCtx(ctx, "readiness check failed", zap.String("dep", name), zap.Error(err))
					mu.Lock()
					failed[name] = "down"
					mu.Unlock()
				}
			})
		}
		wg.Wait()
		status := http.StatusOK
		if len(failed) > 0 {
			status = http.StatusServiceUnavailable
		}
		c.JSON(status, gin.H{"failed": failed})
	})
}
```

## Recovery

不记 `zap.Stack` 时线上 panic 只剩一行 `runtime error: index out of range`；不判 `Written()` 时对已发头的响应再写 JSON 触发 `superfluous response.WriteHeader`。

```go
// Recovery 只覆盖 handler 链所在的 goroutine；handler 里自起的 goroutine panic 仍会杀进程（见 go-error-handling）。
func Recovery() gin.HandlerFunc {
	return func(c *gin.Context) {
		defer func() {
			r := recover()
			if r == nil {
				return
			}
			ctx := c.Request.Context()
			if err, ok := r.(error); ok && (errors.Is(err, syscall.EPIPE) || errors.Is(err, syscall.ECONNRESET) || errors.Is(err, http.ErrAbortHandler)) {
				logger.WarnCtx(ctx, "client connection broken", zap.Error(err)) // 对端已断，写响应没有意义
				c.Abort()
				return
			}
			logger.ErrorCtx(ctx, "panic recovered", zap.Any("panic", r), zap.String("path", c.FullPath()), zap.Stack("stack"))
			if c.Writer.Written() {
				c.Abort() // 头已发出，只能中断链
				return
			}
			c.AbortWithStatusJSON(http.StatusInternalServerError, ginmw.ErrorBody{
				Code: apperror.CodeInternal, Message: apperror.ErrInternal.Message, RequestID: logger.RequestIDFromContext(ctx),
			})
		}()
		c.Next()
	}
}
```
