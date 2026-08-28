---
name: go-performance
description: Go 性能分析与优化。当用户涉及 pprof（CPU / heap / goroutine / mutex / block profile）、火焰图读法、go tool trace、FlightRecorder、GC 调优（GOMEMLIMIT / GOGC / SetMemoryLimit）、GOMAXPROCS 与容器 CPU limit、PGO、逃逸分析（-gcflags=-m）、分配优化（sync.Pool / strings.Builder / strconv.Append / unique / fieldalignment）、Benchmark 与 benchstat，或线上 CPU 打满、内存持续上涨、goroutine 暴涨、延迟毛刺排查时触发。关键词：pprof、flame graph、-diff_base、runtime/trace、GOMEMLIMIT、GOGC、PGO、default.pgo、escape analysis、moved to heap、b.Loop、benchstat、fieldalignment、ReadMemStats。分工：数据库查询与连接池性能见 go-database-patterns；CI 中的 PGO 采集流程与 lint 门禁见 go-engineering-governance；runtime 指标暴露到 Prometheus 见 go-observability。
allowed-tools: "Read, Write, Edit, Bash, Glob, Grep"
---

# Go 性能优化

先测再改：所有优化决策以 profile 与 benchstat 结果为依据。数据库层的 N+1、索引、连接池参数见 go-database-patterns。

## 核心规则

1. 没有 profile 不改代码；CPU profile 里占比 < 5% 的函数不优化，改了也测不出来。
2. pprof 走独立端口的 `http.Server` + 独立 mux；不 `import _ "net/http/pprof"` 到 `DefaultServeMux`，不监听 `0.0.0.0`。
3. 容器内先设 `GOMEMLIMIT`（约 0.9 × 内存 limit），`GOGC` 是次要手段。
4. 运行时指标用 `runtime/metrics`；`runtime.ReadMemStats` 会 stop-the-world，不进高频路径。
5. Benchmark 用 `for b.Loop()`；同包内 Benchmark 函数名不能重复（编译错误）。
6. `sync.Pool` Put 前检查 `Cap()`，超过上限的对象不放回。
7. PGO 默认开启：`default.pgo` 放进 main 包目录即生效，不需要改构建命令。
8. 优化提交必须附 `benchstat` 对比（`-count=10`），p 值不显著就不合入；可读性下降的改动需要 ≥ 10% 的收益才值得。

## pprof

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

## GC 与内存

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

## PGO

Go 1.21+ 的 profile-guided optimization：把线上 CPU profile 放到 main 包目录命名 `default.pgo`，`go build` 默认 `-pgo=auto` 自动读取并应用到 main 的全部传递依赖（`go help build`）。编译器据此做更激进的内联与 devirtualization，官方数据（go.dev/doc/pgo，Go 1.22 起）2%~14% 的 CPU 收益，热路径是接口调用与小函数的服务收益靠上限。profile 来源就是 `/debug/pprof/profile?seconds=30` 在高峰期采的样本，多个实例的 profile 用 `go tool pprof -proto a.pprof b.pprof > default.pgo` 合并。profile 过期（代码大改）不会出错，只是收益衰减；采集 → 提交 → 构建的 CI 流程见 go-engineering-governance。

## 逃逸分析

```bash
go build -gcflags='-m=2' ./pkg 2>&1 | grep -v inlin
```

`-m=2` 输出（Go 1.27 实测）里三种关键行：

- `moved to heap: u`——变量 u 本身被搬到堆，通常因为地址被返回或存进逃逸的结构。
- `leaking param: name`——参数内容随返回值 / 全局逃逸；`leaking param content` 是只有指向的内容逃逸。
- `300 escapes to heap`——值被装进接口（`any`）或 `...any` 参数，分配一份拷贝。

```go
// NewUser 返回局部变量地址，u 必然逃逸——这是"值得"的逃逸：对象本来就要跨调用存活，不用修。
func NewUser(name string) *User {
	u := User{Name: name}
	return &u
}

// Describe 把值装进 any 要分配一次（Go 1.27 实测：运行期 int 300 / string / 24 字节 struct 各 1 次；
// 0~255 的整数走 runtime 静态表，0 次）。热路径上优先写具体类型的重载，不走 any。
func Describe(v any) string { return fmt.Sprint(v) }
```

不值得修的逃逸：构造函数返回指针；对象生命周期本来就跨请求；每请求只发生一次的分配（一次 32 字节分配在一次 HTTP 请求里可忽略）。值得修的：每次循环迭代都发生的装箱、闭包捕获、`fmt.Sprintf` 拼 key。

## 分配优化

```go
// strings.Builder + Grow：一次分配；s += x 每次都新建字符串并拷贝全部旧内容，O(n²)。
func JoinNames(items []Item) string {
	var b strings.Builder
	b.Grow(len(items) * 16)
	for i := range items {
		if i > 0 {
			b.WriteByte(',')
		}
		b.WriteString(items[i].Name)
	}
	return b.String()
}

// strconv.Append* 直接写进已有 []byte；fmt.Sprintf 走反射 + 参数装箱，每次调用多次分配。
func FormatKey(buf []byte, userID int64, shard int) []byte {
	buf = append(buf, "user:"...)
	buf = strconv.AppendInt(buf, userID, 10)
	buf = append(buf, ':')
	return strconv.AppendInt(buf, int64(shard), 10)
}

// map 查找时 m[string(b)] 不分配（编译器特例）；先 s := string(b) 再 m[s] 就会拷贝一次。
func Lookup(m map[string]int, key []byte) (int, bool) {
	v, ok := m[string(key)]
	return v, ok
}

// unique.Make（Go 1.23+）驻留重复字符串：百万条记录里的几十个 service 名只存一份，相等比较退化为指针比较。
type Service struct{ Name unique.Handle[string] }

func NewService(name string) Service { return Service{Name: unique.Make(name)} }
```

预分配：长度已知时 `make([]T, 0, n)`，append 扩容是"翻倍 / 1.25 倍 + 整体拷贝"。`unsafe.String` / `unsafe.Slice` 做零拷贝转换只在能证明底层数组此后不再被修改时用，否则是字符串被改写的静默 bug。

`sync.Pool` 必须限制放回对象的大小：

```go
const maxPooledBuf = 64 << 10 // 64KiB

var bufPool = sync.Pool{
	New: func() any { return bytes.NewBuffer(make([]byte, 0, 4<<10)) },
}

// EncodeJSON 复用缓冲。Put 前必须检查 Cap：一次 10MB 的响应会让大缓冲永久驻留池里，
// 之后每次 Get 都可能拿到它，进程 RSS 只涨不跌。
func EncodeJSON(v any) ([]byte, error) {
	buf := bufPool.Get().(*bytes.Buffer)
	defer func() {
		if buf.Cap() > maxPooledBuf {
			return // 交给 GC，不放回
		}
		buf.Reset()
		bufPool.Put(buf)
	}()
	if err := json.NewEncoder(buf).Encode(v); err != nil {
		return nil, err
	}
	return bytes.Clone(buf.Bytes()), nil // 必须拷贝：buf 归还后会被别的 goroutine 复用
}
```

结构体字段对齐：

```go
// 字段按大小降序排列消除填充（Go 1.27 amd64 实测 unsafe.Sizeof：Padded=32，Packed=16）。检查工具：
// go run golang.org/x/tools/go/analysis/passes/fieldalignment/cmd/fieldalignment@latest ./...
type Padded struct {
	A bool  // 1 + 7 填充
	B int64 // 8
	C bool  // 1 + 3 填充
	D int32 // 4
	E bool  // 1 + 7 填充
}

type Packed struct {
	B int64 // 8
	D int32 // 4
	A bool  // 1
	C bool  // 1
	E bool  // 1 + 1 填充
}
```

只对"数量巨大"的结构体值得做（百万级切片元素、缓存条目）；几十个实例的配置结构体重排只降低可读性。

## Benchmark

```go
func BenchmarkProcess(b *testing.B) {
	items := makeItems(1000) // setup 不计时：b.Loop 首次调用时才重置计时器
	b.ReportAllocs()
	for b.Loop() { // 循环体内的调用结果被编译器保活，不需要"赋给包级变量防优化"的老技巧
		Process(items)
	}
}

// 子基准的函数名必须与上面不同：同包重复声明 BenchmarkProcess 是编译错误。
func BenchmarkProcessSizes(b *testing.B) {
	for _, size := range []int{10, 1_000, 100_000} {
		b.Run(strconv.Itoa(size), func(b *testing.B) {
			items := makeItems(size)
			b.ReportAllocs()
			for b.Loop() {
				Process(items)
			}
		})
	}
}
```

`for b.Loop()`（Go 1.24+）：首次调用重置计时器、返回 false 时停表，setup / cleanup 都不计入；循环体内的函数参数与返回值被 `runtime.KeepAlive` 保活，编译器不会把整个循环体优化掉。`for i := 0; i < b.N; i++` 的写法两点都做不到。

```bash
go test -run='^$' -bench=. -benchmem -count=10 ./... > old.txt
# 改代码
go test -run='^$' -bench=. -benchmem -count=10 ./... > new.txt
go run golang.org/x/perf/cmd/benchstat@latest old.txt new.txt   # 看 delta 与 p 值，"~" 表示无显著差异
```

`-count=10` 不是可选项：单次结果受 CPU 频率、邻居进程影响，benchstat 需要样本算显著性。跑基准的机器上要关掉 IDE 索引、接电源、固定 `GOMAXPROCS`。

## 何时不该优化

| 情况 | 做法 |
|---|---|
| CPU profile 中该函数占比 < 5% | 不动；即使快 10 倍整体也只快 0.5% |
| 没有 benchmark 或 profile | 先写 benchmark 拿到基线，再改 |
| 优化引入 `unsafe`、手写内存布局、放弃错误检查 | 收益 < 30% 不合入；合入必须附反证测试与注释说明 why |
| 每请求只发生一次的小分配 | 忽略；一次请求本身就有几十次分配在 net/http 里 |
| 瓶颈在下游（DB、RPC 等待） | Go 侧优化无效，看连接池、批量、缓存（go-database-patterns / go-redis-patterns） |
| GC 占 CPU < 10% | 不调 GOGC；先看分配热点 |

## 审查清单

- [ ] pprof 在独立 `http.Server` + 独立 mux，监听内网地址；业务代码没有 `import _ "net/http/pprof"`
- [ ] 每个优化 PR 附 `benchstat old new`（`-count>=10`）输出，且 CPU profile 证明该函数在热路径
- [ ] Benchmark 用 `for b.Loop()`，函数名无重复，`b.ReportAllocs()` 已开
- [ ] 容器部署设置了 `GOMEMLIMIT`（或代码里 `debug.SetMemoryLimit`），值 ≈ 0.9 × limit；1.25+ 未引入 automaxprocs、未设 `GOMAXPROCS` 环境变量
- [ ] 监控采集用 `runtime/metrics` 或 `collectors.NewGoCollector`，没有周期性 `runtime.ReadMemStats`
- [ ] `sync.Pool` 的 Put 前有 `Cap()` 上限检查；Get 到的对象归还前已 `Reset`
- [ ] 热路径无 `fmt.Sprintf` 拼 key、无循环内 `s += x`、无每次调用 `regexp.MustCompile`
- [ ] 逃逸修复只针对循环 / 每请求多次发生的分配；构造函数返回指针的逃逸未被"修复"成难读代码
- [ ] main 包目录有 `default.pgo` 且来自近期高峰 CPU profile
- [ ] mutex / block profile 采样率有设置（否则 profile 为空），且不是 rate=1
