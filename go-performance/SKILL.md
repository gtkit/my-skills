---
name: go-performance
description: Go 性能分析与优化：pprof 与火焰图读法、go tool trace、GC 调优（GOMEMLIMIT/GOGC）、GOMAXPROCS、PGO、逃逸分析、分配优化、Benchmark 与 benchstat。排查 CPU/内存/延迟问题或做优化前后对比时使用。
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

## 按任务读取

以下内容按任务读取，只读本次需要的文件；核心规则与审查清单已覆盖其结论。

| 任务 | 读 |
|---|---|
| 采集与阅读 pprof（CPU / heap / goroutine / mutex / block）、线上排障 | `references/pprof.md` |
| 调 GOMEMLIMIT / GOGC、GOMAXPROCS 与容器 CPU limit | `references/gc.md` |
| 读逃逸分析输出 | `references/escape.md` |
| 做分配优化：sync.Pool、strings.Builder、fieldalignment 等 | `references/alloc.md` |
| 写 Benchmark 与 benchstat 对比 | `references/benchmark.md` |

## PGO

Go 1.21+ 的 profile-guided optimization：把线上 CPU profile 放到 main 包目录命名 `default.pgo`，`go build` 默认 `-pgo=auto` 自动读取并应用到 main 的全部传递依赖（`go help build`）。编译器据此做更激进的内联与 devirtualization，官方数据（go.dev/doc/pgo，Go 1.22 起）2%~14% 的 CPU 收益，热路径是接口调用与小函数的服务收益靠上限。profile 来源就是 `/debug/pprof/profile?seconds=30` 在高峰期采的样本，多个实例的 profile 用 `go tool pprof -proto a.pprof b.pprof > default.pgo` 合并。profile 过期（代码大改）不会出错，只是收益衰减；采集 → 提交 → 构建的 CI 流程见 go-engineering-governance。

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
