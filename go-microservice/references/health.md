# 健康检查

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
