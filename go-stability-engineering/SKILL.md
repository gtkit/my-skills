---
name: go-stability-engineering
description: Go 服务稳定性：超时预算、重试退避、熔断、限流、隔仓与背压、负载卸载、降级预案、灰度与回滚、SLO 与 burn-rate 告警、容量评估与压测。设定这些参数或设计故障兜底时使用。
---

# Go 稳定性工程

一个请求穿过"超时 → 重试 → 熔断 → 限流 → 隔仓 → 降级"六层时，每层怎么设、怎么叠加、什么时候不该加。实现放这里；错误分类（`Retryable`/`Permanent`）见 go-error-handling，打点见 go-observability。

## 核心规则

1. 超时从入口开始逐跳递减：下游 ctx 的 deadline 只能比上游早；本跳超时 = min(剩余预算 − reserve, 本跳上限)。
2. 重试只在一层做：客户端、网关、服务各重试 3 次 = 27 倍放大；重试流量 ≤ 正常流量 10%（预算），熔断打开时不重试。
3. 重试判定与 go-error-handling 的 `IsRetryable` 同序：`context.Canceled` 永不重试；显式 `Retryable()` 标记优先；网络超时（含单跳 `DeadlineExceeded`）算可重试，但每次尝试前先查调用方 `ctx.Err()`，总预算已尽就停。
4. 熔断器必设 `IsSuccessful`（4xx 语义算成功）与 `IsExcluded`（调用方取消不计），`ReadyToTrip` 先判样本数再算比率，且分母要减掉排除数。
5. 按 key 限流的容器必须有上限与淘汰（带 TTL 的 LRU），否则限流器本身是内存 DoS 面。
6. 每个下游一个并发上限（`semaphore.Weighted`）+ 有界等待队列；队列满立即拒绝，不无界排队。
7. 降级结果在响应里可辨认（`degraded=true`），兜底路径和主路径一样要有超时。
8. 告警按错误预算消耗速率（burn rate）多窗口触发，不按单点错误率。
9. 低 QPS（统计窗口内样本 < 20）不上熔断；单实例、单下游的内部服务不上限流——先量再加。

## 按任务读取

以下内容按任务读取，只读本次需要的文件；核心规则与审查清单已覆盖其结论。

| 任务 | 读 |
|---|---|
| 设定超时预算与逐跳递减 | `references/timeout.md` |
| 实现重试：退避、抖动、预算、单层重试 | `references/retry.md` |
| 接入熔断（sony/gobreaker） | `references/breaker.md` |
| 选型与实现限流器（令牌桶、滑动窗口、分布式） | `references/ratelimit.md` |
| 做隔仓、背压与负载卸载 | `references/bulkhead.md` |
| 设计降级开关与预案 | `references/degrade.md` |

## 发布

k8s 时序（默认 `terminationGracePeriodSeconds: 30`，倒计时含 preStop）：readiness 翻红 → `preStop sleep 5` 等 endpoint 摘除 → SIGTERM → `Shutdown(20s)` 排空 → 关依赖（余量 5s）→ 30s 到 SIGKILL。进程内实现见 go-microservice。

| 项 | 规则 |
|---|---|
| 灰度 | 先 1 个 Pod / 1% 流量，按用户分组（内部 → 白名单 → 百分比），每级观察 ≥ 1 个完整业务周期 |
| 金丝雀指标 | 与基线对比：5xx 率、P99、下游错误率、业务指标（下单成功率）；任一恶化超阈值即回滚 |
| 自动回滚 | `progressDeadlineSeconds` 兜底；Argo Rollouts/Flagger 按 Prometheus 查询判定 |
| `maxSurge`/`maxUnavailable` | 默认 25%/25%；连接池预热慢的服务用 `maxUnavailable: 0`，避免容量瞬时缩 25% |
| 连接池预热 | 新 Pod 在 `startupProbe` 通过前建好 DB/Redis/gRPC 连接，否则第一波流量全在建连 |
| 回滚 | 镜像回滚 + 配置回滚 + 数据迁移前向兼容（新版本能读旧数据，旧版本能读新数据） |

## SLO 与告警

| 项 | 规则 |
|---|---|
| SLI | 从用户视角选：可用性 = 非 5xx 请求 / 总请求；延迟 = P99 < 阈值的请求占比；不用 CPU、内存做 SLI |
| SLO | 99.9%/30 天 → 错误预算 43.2 分钟；99.95% → 21.6 分钟 |
| RED | 每个服务：Rate（QPS）、Errors、Duration（直方图）；USE 用于资源：Utilization、Saturation、Errors |

多窗口 burn-rate 告警（SLO 99.9%，错误率阈值 = burn rate × 0.1%）：

| 长窗口 | 短窗口 | burn rate | 错误率阈值 | 消耗预算 | 级别 |
|---|---|---|---|---|---|
| 1h | 5m | 14.4 | 1.44% | 1h 烧掉 2% | 电话 |
| 6h | 30m | 6 | 0.6% | 6h 烧掉 5% | 电话 |
| 3d | 6h | 1 | 0.1% | 3d 烧掉 10% | 工单 |

长窗口判"确实在烧"，短窗口判"还在烧"（恢复后短窗口先回落，告警自动消退）；两个窗口同时超阈值才触发。单点错误率告警在低流量时段几个请求就能触发，是噪音的主要来源。

## 容量评估

| 项 | 方法 |
|---|---|
| 峰值 QPS | 日均 QPS = 日请求量 / 86400；峰值 = 日均 × 峰值系数（用历史 P99 分钟 QPS / 日均实测，常见 3~8；无数据取 5） |
| 单机容量 | 阶梯压测：并发逐级加，记录 P99 与错误率，取 P99 不劣化、CPU ≤ 70% 的最大 QPS；机器数 = 峰值 / 单机容量 × 1.5（N+1 与冗余） |
| 连接数 | 每 Pod 连接 = 下游数 × 每下游池大小；反过来 DB 侧 max_connections ≥ Pod 数 × 池大小 × 1.2 |
| 文件句柄 | 每连接 1 个 fd；`ulimit -n` 与容器 `nofile` 要 ≥ 2 × 峰值连接数 |
| goroutine | 每在途请求 ≈ 1~3 个；初始栈 2KB 起（Go 1.19 起按历史平均动态调整）；10 万 goroutine ≈ 数百 MB 起步 |
| `GOMAXPROCS` | go.mod 语言版本 ≥ 1.25 时自动感知 cgroup CPU 配额并周期性更新（go doc；≤ 1.24 默认 `containermaxprocs=0`），不再需要 automaxprocs |
| `GOMEMLIMIT` | 软上限，不自动读 cgroup；设为容器 limit 的 80~90%，为非 Go 内存（cgo、内核 socket 缓冲）留余量；到限后 GC 频繁而非 OOM |

## 故障演练

最小方法：用 toxiproxy/`tc netem` 或 Istio fault injection 对**单个**下游注入延迟（P99 × 3）、错误（50% 5xx）、不可用（拒连），每次只改一个变量，在预发或 1% 流量做。

演练脚本里制造 CPU/负载的部分必须自带有界寿命：看门狗 + `ulimit -t` 两道独立保险叠加，不依赖清理代码被执行（写法见 shell-scripting）。演练留下的负载进程比被演练的故障更难排查。

检查项：本服务 P99 是否被 ctx 超时钳住（而不是跟着下游涨）；重试次数是否在预算内；熔断是否在样本数够时打开、下游恢复后是否合上；降级路径是否触发且响应带 `degraded`；readiness 是否保持 up（依赖抖动不该让 Pod 被摘掉）；告警是否按 burn rate 触发而非风暴。

## 何时不该做

| 场景 | 不做什么 | 理由 |
|---|---|---|
| 单实例 + 单下游的内部工具 | 熔断、限流 | 加一层状态机与阈值调参，故障面积不变；超时 + 降级足够 |
| 下游 QPS < 1 | 熔断 | 窗口内凑不齐样本，比率判定是随机的 |
| 已上 Istio | SDK 侧重试/熔断/超时 | 两层叠加：重试次数相乘，超时互相覆盖 |
| 无幂等键的写 | 重试 | 双写事故比失败一次严重 |
| 没有基线指标 | 自适应限流 | 阈值无从校准，误限比不限更糟 |

## 稳定性审查清单

- [ ] 每个下游调用的 ctx 由预算派生（`ForHop`），deadline 只减不增；有 reserve
- [ ] 重试只在一层；重试判定与 go-error-handling `IsRetryable` 同序（`Canceled` 先于标记）；`MaxDelay` > 0；有全进程共享的重试预算
- [ ] `Retry-After` 被尊重；熔断打开/半开拒绝不重试
- [ ] 熔断器每下游一个；`IsSuccessful` 与 `IsExcluded` 都设了；`ReadyToTrip` 先判样本数，分母减 `TotalExclusions`
- [ ] 按 key 限流用带 TTL 的 LRU；反向代理后 IP 取自可信 `X-Forwarded-For`；429 带 `Retry-After`
- [ ] 每个下游有 `Bulkhead`，`maxQueue` 有界；构造期校验非法参数（fail-closed，同 `retry.Policy`）；过载优先级在入口已定
- [ ] 降级响应可辨认；兜底路径有超时；开关可热更新且有审计
- [ ] 预案表四列齐全且近一季度演练过
- [ ] 发布有 `preStop sleep`、`startupProbe`、金丝雀指标与自动回滚条件
- [ ] SLO 已定义；告警是多窗口 burn-rate；每个服务有 RED 三指标
- [ ] 峰值 QPS、单机容量、连接数/fd/goroutine 预算有数字；`GOMEMLIMIT` 已设
