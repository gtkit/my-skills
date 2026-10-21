---
name: go-performance
description: Go 性能分析与优化：pprof 与火焰图读法、go tool trace、GC 调优（GOMEMLIMIT/GOGC）、GOMAXPROCS、PGO、逃逸分析、分配优化、Benchmark 与 benchstat。排查 CPU/内存/延迟问题或做优化前后对比时使用。
allowed-tools: "Read, Write, Edit, Bash, Glob, Grep"
---

# Go 性能优化

## 前置必读：拒绝猜测与改动边界

- 每次使用本 skill、恢复任务及执行任何改动前，先实际读取本节、当前运行环境已配置的全局规则，以及目标项目已有的协作规则和错误记录。按已明确的配置入口定位，不猜路径、不硬编码本机目录，不以记忆或摘要替代；必需规则无法读取时停止改动并说明。
- 需求、接口、字段、权限、默认值、路径、工具能力、依赖与兼容结论必须有用户指令、已读取源码/配置、已核实官方资料或真实执行证据。未知保持未确认，先核实；仍不明确就停止依赖该信息的步骤，不凭猜测补全，不重复询问已经明确的要求。
- 修改代码前先完成并落盘方案和逐步计划，写清范围、文件、兼容约束、风险、回滚和验收；只执行获准范围及阶段。计划、候选原因和未执行步骤标为待验证，不能当作事实或已完成结果。
- 只有真实执行并回读后才能报告完成或通过，区分失败、未执行、未验证和不适用；模拟与静态证据不冒充真实链路。纯文档、注释、规则或 skill 说明任务只编辑指定内容并回读，不因本 skill 的流程扩展为测试、构建、同步、打包或 OpenSpec 操作。

先测再改：依据优化目标选择基线、profile 与对比方法；基准测量使用 benchstat，端到端延迟仍需对应链路证据。数据库层的 N+1、索引、连接池参数见 go-database-patterns。

## 核心规则

1. 修改前先有与目标匹配的测量依据：CPU、分配、锁等待、阻塞或端到端延迟。CPU profile 占比低不代表没有延迟或内存影响；不能用统一的 5% 阈值判定不可测或不值得优化。
2. pprof 走独立端口的 `http.Server` + 独立 mux；不 `import _ "net/http/pprof"` 到 `DefaultServeMux`，不监听 `0.0.0.0`。
3. 容器内先设 `GOMEMLIMIT`（约 0.9 × 内存 limit），`GOGC` 是次要手段。
4. 运行时指标用 `runtime/metrics`；`runtime.ReadMemStats` 会 stop-the-world，不进高频路径。
5. Benchmark 用 `for b.Loop()`；同包内 Benchmark 函数名不能重复（编译错误）。
6. `sync.Pool` Put 前检查 `Cap()`，超过上限的对象不放回。
7. PGO 默认开启：`default.pgo` 放进 main 包目录即生效，不需要改构建命令。
8. 基准优化附相同条件下的 `benchstat` 对比，默认从每组 10 次采样开始，按输出警告和波动补充样本；记录实际效应、统计不确定性与目标指标。可读性成本和最低收益门槛由项目确认，10% 等经验值不能写成普遍规律。

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

## 优化优先级与取舍

| 情况 | 做法 |
|---|---|
| CPU profile 中该函数占比低 | 先按目标指标估算收益，并检查是否影响分配、锁或尾延迟；不据占比直接否定 |
| 没有对应测量证据 | 先建立基线，再决定是否改代码；不以微基准代替端到端结果 |
| 优化引入 `unsafe`、手写内存布局或削弱检查 | 先满足安全、正确性与授权边界；收益不能抵消这些要求，最低收益门槛另按项目确认 |
| 每请求一次的小分配 | 根据请求量、累计分配和 GC 证据决定，不能仅凭次数忽略 |
| 瓶颈在下游（DB、RPC 等待） | 优先核对连接池、批量和下游链路，再验证 Go 侧改动是否影响目标（go-database-patterns / go-redis-patterns） |
| GC 的 CPU 占比较低 | 先看分配与暂停/延迟证据，再决定是否调 GOGC |

比例估算采用明确输入，不能冒充实测：简化串行模型中，原耗时为 1、某部分占比为 `f`、该部分提速 `s` 倍，则新耗时为 `(1-f)+f/s`。取 `f=0.04`、`s=10` 得 `0.964`，即耗时下降 3.6%；CPU 采样占比不能直接当作端到端耗时占比，也不能据此声称实际延迟已改善。

## 审查清单

- [ ] pprof 在独立 `http.Server` + 独立 mux，监听内网地址；业务代码没有 `import _ "net/http/pprof"`
- [ ] 目标指标有前后基线；微基准附 `benchstat old new`、实际采样次数与警告，端到端收益有独立证据
- [ ] Benchmark 用 `for b.Loop()`，函数名无重复，`b.ReportAllocs()` 已开
- [ ] 容器部署设置了 `GOMEMLIMIT`（或代码里 `debug.SetMemoryLimit`），值 ≈ 0.9 × limit；1.25+ 未引入 automaxprocs、未设 `GOMAXPROCS` 环境变量
- [ ] 监控采集用 `runtime/metrics` 或 `collectors.NewGoCollector`，没有周期性 `runtime.ReadMemStats`
- [ ] `sync.Pool` 的 Put 前有 `Cap()` 上限检查；Get 到的对象归还前已 `Reset`
- [ ] 热路径无 `fmt.Sprintf` 拼 key、无循环内 `s += x`、无每次调用 `regexp.MustCompile`
- [ ] 逃逸修复只针对循环 / 每请求多次发生的分配；构造函数返回指针的逃逸未被"修复"成难读代码
- [ ] main 包目录有 `default.pgo` 且来自近期高峰 CPU profile
- [ ] mutex / block profile 采样率有设置（否则 profile 为空），且不是 rate=1
