# 超时

| 决策 | 规则 | 为什么 |
|---|---|---|
| 单跳超时值 | 下游 P99 × 1.5~2，且 ≤ 下游 SLA 承诺 | 按 P50 定会把正常长尾全打成超时；按 max 定等于没设 |
| 入口总预算 | 客户端/网关愿意等的时长 − 网络往返 | 客户端 3s 放弃，服务端设 5s 只是在给已经没人等的请求耗资源 |
| reserve | 本跳返回后还要做的事（写 DB、序列化）的 P99 | 下游用完全部预算，本服务自己超时，等于白调 |
| DB/Redis | 单语句 ≤ 1s / ≤ 200ms，用 ctx 而非驱动全局超时 | 全局超时不随预算递减 |

```go
// WithDeadlineOnly 只给 ctx 加 deadline：超时后 handler 继续跑、客户端继续等，响应码由 handler 决定。
// 它的价值在于下游调用（DB/HTTP/gRPC）会因 ctx 超时提前返回，handler 应据此返回 504。
func WithDeadlineOnly(next http.Handler, d time.Duration) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		ctx, cancel := context.WithTimeout(r.Context(), d)
		defer cancel()
		next.ServeHTTP(w, r.WithContext(ctx))
	})
}

// Hard 用 http.TimeoutHandler：超时立即向客户端回 503（不是 504，Go 1.27 实测）并结束响应，
// handler 在后台继续跑但写响应会得到 http.ErrHandlerTimeout。不支持 Hijacker/Flusher：
// WebSocket、SSE 路由不能包在里面。
func Hard(next http.Handler, d time.Duration) http.Handler {
	return http.TimeoutHandler(next, d, `{"error":"timeout"}`)
}
```

Gin 场景用 `gin-contrib/timeout`（见 go-gin-api）同样要注意 handler 与超时分支并发写响应的问题。预算传播代码（`ForHop`/`Inject`/`Extract`）见 go-microservice。
