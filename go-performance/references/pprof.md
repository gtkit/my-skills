# pprof

```go
// Start 在独立端口起 pprof：内网地址 + 独立 mux。不能 import _ "net/http/pprof" 让它注册到
// DefaultServeMux——业务若也用 DefaultServeMux，/debug/pprof 就跟业务端口一起暴露到公网。
func Start(ctx context.Context, addr string) {
	// 采样开销：mutex 每 5 次竞争事件记 1 次；block 每累计阻塞 1ms 记 1 个样本。rate=1 是"全记"，线上不要。
	runtime.SetMutexProfileFraction(5)
	runtime.SetBlockProfileRate(int(time.Millisecond))

	mux := http.NewServeMux()
	mux.HandleFunc("/debug/pprof/", pprof.Index) // heap/goroutine/mutex/block/allocs 都由 Index 按名字分发
	mux.HandleFunc("/debug/pprof/cmdline", pprof.Cmdline)
	mux.HandleFunc("/debug/pprof/profile", pprof.Profile)
	mux.HandleFunc("/debug/pprof/symbol", pprof.Symbol)
	mux.HandleFunc("/debug/pprof/trace", pprof.Trace)

	srv := &http.Server{
		Addr:              addr, // "127.0.0.1:6060" 或 Pod IP:6060；绝不 0.0.0.0 对公网
		Handler:           mux,
		ReadHeaderTimeout: 5 * time.Second,
		// 不设 WriteTimeout：profile?seconds=30 需要持续 30s 后才写回
	}
	go func() {
		if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			logger.Error("pprof server exited", zap.Error(err))
		}
	}()
	go func() {
		<-ctx.Done()
		shutdownCtx, cancel := context.WithTimeout(context.WithoutCancel(ctx), 2*time.Second)
		defer cancel()
		_ = srv.Shutdown(shutdownCtx)
	}()
}
```

mutex / block profile 默认关闭（fraction 0 / rate 0），不调 `SetMutexProfileFraction` / `SetBlockProfileRate` 抓到的就是空 profile。`SetBlockProfileRate(1)` 记录每次阻塞事件，高并发下自身开销可观。

```bash
go tool pprof -http=:8081 http://127.0.0.1:6060/debug/pprof/profile?seconds=30   # CPU，浏览器打开火焰图
go tool pprof -http=:8081 -sample_index=inuse_space http://127.0.0.1:6060/debug/pprof/heap   # 当前驻留
go tool pprof -http=:8081 -sample_index=alloc_space http://127.0.0.1:6060/debug/pprof/heap   # 累计分配（找分配热点）
curl -s 'http://127.0.0.1:6060/debug/pprof/goroutine?debug=2' | head -100   # 全部 goroutine 栈，直接看堆在哪
go tool pprof -http=:8081 http://127.0.0.1:6060/debug/pprof/mutex           # 锁竞争：谁持锁最久
go tool pprof -http=:8081 http://127.0.0.1:6060/debug/pprof/block           # 阻塞：chan / select / Cond 等在哪
go tool pprof -http=:8081 -diff_base old.pprof new.pprof                      # 优化前后差异，负值是变好
curl -o trace.out 'http://127.0.0.1:6060/debug/pprof/trace?seconds=5' && go tool trace trace.out
```

火焰图读法：宽度 = 采样占比，只看宽的；从上往下找"平顶"（自身耗时高、没有子调用），那是真正干活的函数；纵深多层窄条是调用链开销不是热点。`-focus=regex` 只看匹配子树，`-ignore=regex` 排除 runtime.mallocgc 之类噪音；heap profile 里 `inuse_space` 看泄漏、`alloc_space` 看 GC 压力，二者结论经常相反。

FlightRecorder（Go 1.25+）解决"毛刺过去了才想起开 trace"：

```go
// StartFlightRecorder（Go 1.25+）：runtime 持续保留最近一段执行 trace，出事时 WriteTo 落盘，
// 事后能看到毛刺发生之前的调度 / GC / 阻塞事件；trace.Start 只能"先开再等复现"。
// 同一时刻只允许一个 FlightRecorder 存活。
func StartFlightRecorder() (*trace.FlightRecorder, error) {
	fr := trace.NewFlightRecorder(trace.FlightRecorderConfig{
		MinAge:   10 * time.Second, // 窗口至少覆盖最近 10s
		MaxBytes: 32 << 20,         // 窗口上限 32MiB，优先级高于 MinAge
	})
	if err := fr.Start(); err != nil {
		return nil, fmt.Errorf("start flight recorder: %w", err)
	}
	return fr, nil
}
```

慢请求 / 超时告警的回调里调 `fr.WriteTo(file)` 落盘，`go tool trace` 打开看 Goroutine analysis 与 Scheduler latency。

### 线上排障路径

| 现象 | 先看 | 常见根因 | 验证 |
|---|---|---|---|
| goroutine 数持续上涨 | `goroutine?debug=2`，按栈聚合数量 | 无退出路径的 goroutine：chan 无人收、`http.Client` 无 Timeout、`time.After` 在 select 循环里 | 两次采样对比同一栈的数量差；单测加 `goleak` |
| RSS 持续上涨、GC 后不回落 | heap `inuse_space`，对比 5 分钟前 | 全局 map 只增不删、`sync.Pool` 放回超大对象、`[]byte` 子切片引用大底层数组、`time.Ticker` 未 Stop（1.23 前） | `-diff_base` 看增长集中在哪个分配点 |
| GC 频繁、CPU 里 `gcBgMarkWorker` 占比高 | heap `alloc_space` + `/gc/heap/goal:bytes` | 存活堆小但分配率极高（每请求 JSON 编解码、字符串拼接、`fmt.Sprintf`） | `benchmem` 看 allocs/op；先降分配率再谈 GOGC |
| CPU 打满 | CPU profile 30s | 正则每次编译、反射、锁竞争自旋、`GOMAXPROCS` 大于配额导致 throttling | 火焰图平顶；`kubectl top` 与 `container_cpu_cfs_throttled_seconds_total` |
| 延迟毛刺、P99 远高于 P50 | mutex / block profile + trace | 一把大锁、GC STW（堆接近 GOMEMLIMIT 时死亡螺旋）、同步落盘日志、DNS 解析 | trace 里看 STW 与 goroutine 等待；FlightRecorder 抓毛刺前 10s |
