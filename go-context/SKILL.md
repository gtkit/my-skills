---
name: go-context
description: Go context 生命周期与取消契约：请求传播、deadline、取消原因、value、后台任务和有界收尾。实现或审查超时、取消与请求脱离时使用；并发调度和重试预算走对应专项。
---

# Go Context：传播、取消与收尾边界

## 前置必读：拒绝猜测与改动边界

- 每次使用本 skill、恢复任务及执行任何改动前，先实际读取本节、当前运行环境已配置的全局规则，以及目标项目已有的协作规则和错误记录。按已明确的配置入口定位，不猜路径、不硬编码本机目录，不以记忆或摘要替代；必需规则无法读取时停止改动并说明。
- 需求、接口、字段、权限、默认值、路径、工具能力、依赖与兼容结论必须有用户指令、已读取源码/配置、已核实官方资料或真实执行证据。未知保持未确认，先核实；仍不明确就停止依赖该信息的步骤，不凭猜测补全，不重复询问已经明确的要求。
- 修改代码前先完成并落盘方案和逐步计划，写清范围、文件、兼容约束、风险、回滚和验收；只执行获准范围及阶段。计划、候选原因和未执行步骤标为待验证，不能当作事实或已完成结果。
- 只有真实执行并回读后才能报告完成或通过，区分失败、未执行、未验证和不适用；模拟与静态证据不冒充真实链路。纯文档、注释、规则或 skill 说明任务只编辑指定内容并回读，不因本 skill 的流程扩展为测试、构建、同步、打包或 OpenSpec 操作。

本 skill 统一 context 的生命周期规则。并发调度见 `go-concurrency`，超时数值与重试预算见 `go-stability-engineering`，HTTP/RPC 的传播实现见 `go-microservice`；不重复这些实现。

## 核心规则

1. ctx 显式作为需要它的函数的首个参数传递，不传 nil，不用新建 `Background()` 隐藏已有请求的取消与 deadline。业务方法不把请求 ctx 存入长期复用的 struct。
2. 创建派生 ctx 的代码负责在所有退出路径调用 cancel。取消只发出停止信号，不等待任务结束；任务退出仍由启动者等待，具体模式见 `go-concurrency`。
3. 普通请求工作沿用父 ctx；下游上限不得放大父 deadline。没有父 deadline 时，使用项目已确认的调用上限，不能臆定超时值。
4. 是否脱离请求取消由业务契约决定。普通数据库写入不一律使用 `WithoutCancel`；已产生副作用后的记账、释放或补偿，要单独说明继续执行的理由、截止条件和失败恢复方式。
5. `WithoutCancel`（Go 1.21）保留父 context 的 value，但不继承 deadline、取消和取消原因，`Done()` 为 nil。脱离请求的外部 I/O 必须重新设置已确认的独立上限；进程内后台任务还要有所有者、关停与等待路径。
6. 脱离请求取消不保证进程退出后任务仍会完成。要求可靠交付时，按 `go-data-consistency` / `async-job-contracts` 设计持久化任务、Outbox、重试和对账；不把本地 goroutine 当成交付保证。
7. `WithValue` 只传递跨 API 的请求级元数据，key 使用包内自定义类型；不把它当作业务必填参数、依赖容器或可选参数集合。
8. 需要区分取消原因时使用项目版本支持的 `WithCancelCause` / `WithTimeoutCause` 与 `Cause`，最低版本见 `use-modern-go`。区分客户端取消、业务主动取消、本服务预算耗尽和下游超时，再按项目错误契约与 SLO 决定响应、日志和告警。

## 先确定生命周期

| 工作 | ctx 归属 | 必须核对 |
|---|---|---|
| 请求内查询、写入、并行下游调用 | 请求 ctx 的派生链 | 上游取消可传播；调用上限与事务结果语义明确 |
| 已产生副作用后的必要收尾 | 经契约允许脱离请求的短生命周期 ctx | 独立正超时；存储实现遵守取消；失败可记录、恢复或对账 |
| 非关键旁路任务 | 服务管理的后台生命周期 | 是否允许丢失、是否需要保留请求 value、并发上限与关停等待 |
| 必须可靠完成的异步任务 | 持久化任务与消费者生命周期 | 业务提交与投递的一致性、消费幂等、重试与恢复 |
| 长连接会话、进程关停 | 会话或进程的生命周期 | 显式退出与等待；I/O/心跳/排空上限按对应协议确定 |

`WithTimeout` 只能把预算传给下游，不能强制中断一个忽略 ctx 的实现。审查时沿调用链确认实际 I/O 接受并遵守该 ctx，不能仅因存在 timeout 就宣称无阻塞或无泄漏。

## 按任务读取

| 任务 | 读 |
|---|---|
| goroutine 退出、errgroup、AfterFunc 与关停等待 | [go-concurrency 生命周期参考](../go-concurrency/references/lifecycle.md) |
| HTTP/RPC deadline 传播、服务排空 | [deadline 传播](../go-microservice/references/deadline.md) / [关停](../go-microservice/references/shutdown.md) |
| 数据库取消、事务与提交结果不明 | `go-database-patterns` / `go-data-consistency` |
| 幂等收尾与有界清理 | [go-microservice 幂等参考](../go-microservice/references/idempotency.md) |
| 错误分类、HTTP/gRPC 映射与告警 | `go-error-handling` / `go-observability` |
| 当前已授权代码任务的取消与时间测试 | `go-testing` 的并发参考；纯说明请求不启动测试 |

## 审查要点

- [ ] 每个 ctx 能指出父级、所有者、截止条件与 cancel 的执行位置。
- [ ] 每次 `WithoutCancel` 都有业务依据；外部 I/O 有独立上限，后台任务可关停并等待。
- [ ] 未把取消、超时或收尾失败直接等同于“业务没有发生”。
- [ ] 没有用 ctx value 隐藏业务参数或替换项目的依赖装配方式。
- [ ] 只报告实际观察到的取消传播、失败恢复与退出证据；未运行的场景保持未验证。

依据：[context 官方文档](https://pkg.go.dev/context)，其中 `CancelFunc`、`WithoutCancel` 与 `WithValue` 的语义是本 skill 的 API 依据。
