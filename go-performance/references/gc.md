# GC 与内存

`GOMEMLIMIT` 是软上限：接近它时 GC 变频繁并更积极归还内存。容器里的标准组合是 `GOMEMLIMIT=<0.9 × 内存 limit>` + `GOGC=off`——堆在上限以下随便涨、GC 次数最少；接近上限才收。留 10% 是因为 limit 只算 runtime 管理的内存，不含 CGO、内核 socket 缓冲、二进制映射。

死亡螺旋：存活堆本身就接近上限时，GC 每轮只能回收一点点，于是持续 GC、CPU 全给 GC、吞吐归零但进程不死（runtime 有 GC CPU 上限约 50% 的限制器，`/gc/limiter/last-enabled:gc-cycle` 能看到它触发）。此时正确动作是加内存或降存活堆，不是调 GOGC。

```go
// ApplyMemoryLimit 兜底：容器没设 GOMEMLIMIT 环境变量时，按 cgroup 限额的 90% 设软上限。
// 留 10% 给 Go 堆之外的内存（goroutine 栈之外的 mmap、CGO、内核 socket 缓冲、二进制本身）——
// GOMEMLIMIT 只约束 runtime 自己管理的内存。
func ApplyMemoryLimit(containerLimitBytes int64) {
	if os.Getenv("GOMEMLIMIT") != "" || containerLimitBytes <= 0 {
		return
	}
	debug.SetMemoryLimit(containerLimitBytes / 10 * 9)
}
```

`GOGC` 作为次要手段：分配率高、存活堆小的服务可 `GOGC=200~400` 换更少 GC 次数；有了 GOMEMLIMIT 兜底，调大 GOGC 不再有 OOM 风险。运行时指标读取：

```go
// RuntimeSnapshot 用 runtime/metrics 读运行时指标：不 stop-the-world，可以每秒采。
// runtime.ReadMemStats 会 STW，高频调用自己就是延迟毛刺的来源。
type RuntimeSnapshot struct {
	HeapLive   uint64 // 上次 GC 结束时的存活堆；首次 GC 前为 0
	TotalBytes uint64 // runtime 映射的全部内存（含已归还但仍映射的部分）；GOMEMLIMIT 约束的是它减 /memory/classes/heap/released:bytes
	Goroutines uint64
	GCCPUFrac  float64 // 进程启动以来 GC 占 CPU 的比例；看趋势需两次采样求差
}

var sampleNames = []string{
	"/gc/heap/live:bytes",
	"/memory/classes/total:bytes",
	"/sched/goroutines:goroutines",
	"/cpu/classes/gc/total:cpu-seconds",
	"/cpu/classes/total:cpu-seconds",
}

func Snapshot() RuntimeSnapshot {
	samples := make([]metrics.Sample, len(sampleNames))
	for i, n := range sampleNames {
		samples[i].Name = n
	}
	metrics.Read(samples)
	snap := RuntimeSnapshot{
		HeapLive:   samples[0].Value.Uint64(),
		TotalBytes: samples[1].Value.Uint64(),
		Goroutines: samples[2].Value.Uint64(),
	}
	if total := samples[4].Value.Float64(); total > 0 {
		snap.GCCPUFrac = samples[3].Value.Float64() / total
	}
	return snap
}
```

暴露到 Prometheus 直接用 `collectors.NewGoCollector` 的 runtime/metrics 模式，见 go-observability。

GOMAXPROCS 与容器 CPU limit：Go 1.25 起 runtime 在 Linux 上按 cgroup CPU 配额自动设置 GOMAXPROCS 并周期性更新（`go doc runtime.GOMAXPROCS`）；1.24 及以前默认等于宿主机核数，2 核配额的 Pod 跑 64 个 P 会被 CFS 持续 throttle，必须 `import _ "go.uber.org/automaxprocs"`。1.25+ 项目删掉 automaxprocs，且不要再设 `GOMAXPROCS` 环境变量（设了就关闭自动更新）。
