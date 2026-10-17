---
name: async-job-contracts
description: Use when defining Laravel Queue, Go MQ, or cross-language event contracts for delivery, idempotency, retries, DLQ, ordering, replay, or compensation.
---

# 异步任务与事件契约

## 适用场景

用于 Laravel Queue job、Go MQ consumer/producer，以及 Go/PHP/Node 等跨语言事件的契约设计、升级、消费治理、失败处理、回放和补偿。它先定义生产者与消费者可共同验证的边界，再把具体 broker、事务和框架实现路由给现有 skill。

契约结论必须来自需求、事件 schema、broker/框架文档、现有消费者代码或运行证据。没有来源的状态转换、业务补偿、重试次数或保留时长只能标为假设，不能写成事实。

## 输入与前置事实

开始前收集：

- 事件/任务名称、所有生产者和消费者、负责人、schema registry 或版本文件、部署顺序和兼容窗口。
- broker/queue 类型、分区或队列键、ack/offset 语义、可见性超时、保留时长、最大消息大小和消费并发配置。
- 业务副作用、幂等键来源与持久化位置、重试分类、DLQ、告警、回放权限和脱敏要求。
- 顺序范围、允许乱序的条件、跨服务事务边界、Outbox/Saga/TCC 需求和补偿责任人。
- 目标吞吐、延迟、积压阈值、数据保留和恢复目标；未确认的 broker 语义写“待核实”。

## 按顺序执行

### 1. 建立来源表和消费者矩阵

列出每个字段、状态和副作用的来源：需求、schema、代码、broker 文档、测试或运行观测。矩阵至少包含生产版本、消费版本、是否能读旧事件、是否能写新事件、失败处置、回滚路径和验证状态。没有消费者清单时先阻断破坏性变更。

### 2. 定义事件 envelope 与演进规则

在项目约定允许时，统一记录 `event_id`、`event_type`、`schema_version`、`occurred_at`、`producer`、`correlation_id`、`idempotency_key` 和 `payload`；字段是否必需、格式、时区、大小和隐私等级由契约确认。明确兼容策略：新增可选字段、默认值、弃用窗口、删除条件、未知字段处理和 schema 校验命令。不要把某个序列化库的默认行为当成跨语言契约。

### 3. 写清投递与确认语义

1. 从 broker 和客户端文档确认 at-most-once、at-least-once 或其他实际语义，并记录 ack/offset 提交时机、断线、超时和重投行为。
2. 把“处理成功”定义为副作用和状态已持久化后再确认；如果框架不能做到，记录重复或丢失窗口。
3. 不声称 broker 单独提供 exactly-once。若需求需要一次效果，必须证明持久化幂等状态、唯一约束或等价机制覆盖重试、崩溃和多实例。

具体 Go 客户端、位点、分区顺序、重试和死信实现路由 `go-mq-patterns`；Laravel worker 运行时细节路由 `senior-php-engineer`。

### 4. 设计幂等、重试和 DLQ

- 幂等键应能跨进程、重启和重投保持；定义同键同 payload、同键不同 payload、处理中重试、完成后重放和过期键的结果。状态与响应需要持久化的位置由项目契约决定。
- 将错误分类为可重试、永久失败、需人工处理或未知；为每类记录退避、总时间预算、最大尝试或由负责人确认的无限重试条件。不得凭经验填数字。
- DLQ 保留原事件、失败原因、attempt、首次/最近时间、消费者版本和 trace 关联；重放前验证 schema、权限、幂等和副作用窗口，重放结果可对账。

### 5. 约束顺序、并发与回放

明确顺序只在哪个 partition/key/业务实体内成立，以及重试、扩容、跨队列和 DLQ 是否会破坏它。需要顺序时定义乱序检测和停止策略，不把“单线程”当成跨实例保证。回放需支持 dry run、范围过滤、速率限制、去重、审计和停止；缺少这些控制时将回放标为阻断。

### 6. 处理事务、补偿和上线

若事件必须与数据库写入原子关联，先确认需求和存储边界，再路由 `go-data-consistency` 选择 Outbox、Saga 或其他方案；本 skill 不复制事务实现。补偿动作要有业务批准的不变量、幂等条件、失败记录和人工接管路径。

上线按兼容窗口执行：先部署能同时读取旧/新版本的消费者，再发布生产者或 schema；清理旧字段前确认矩阵中的消费者、回放数据和 DLQ 已处理。若需 dual-publish、dual-read 或 feature flag，写出停止条件和关闭顺序。

### 7. 验证和收口

运行 schema compatibility、序列化跨语言、重复/乱序、断线重投、消费者崩溃、DLQ 重放、回放限速、补偿和权限测试。记录真实 broker/worker 结果；仅 mock、静态推演或缺少生产数据时标记证据等级和未验证原因。

## 失败、暂停与回滚

- schema 不兼容或未知消费者：暂停生产者/发布，恢复上一 schema 或兼容代码；已发出的事件按保留策略处理，不直接删除。
- poison message、重试风暴或积压失控：暂停相关消费者或转入 DLQ，保留事件和上下文，先修复分类/代码再小范围重放；观察到的阈值来自项目 SLO。
- 幂等冲突（同键不同 payload）：停止自动重试，保留两份 payload 和审计记录，由业务规则决定修复或补偿。
- 补偿或回放失败：不得吞错；记录未完成副作用、负责人和下一步。数据库事务/Outbox 回滚按 `go-data-consistency` 已验证方案执行。
- 回滚消费者版本前检查它能读当前事件并处理已存在的幂等记录；若不能，保持兼容版本或先完成数据修复。

## 证据记录

保留来源表、消费者矩阵、schema diff、兼容检查输出、broker/worker 配置、ack/offset 日志、重复与崩溃测试、DLQ 样本、回放命令与范围、幂等状态、补偿结果、积压和延迟指标、发布/回滚时间线及未验证项。每条结论写证据等级：文档、代码审查、自动化测试、受控运行或生产观测。

## 完成条件

- schema、投递、幂等、重试、DLQ、顺序、回放和补偿都有来源、负责人和可执行验证。
- 生产者与消费者版本矩阵通过兼容检查，失败和回滚路径能在目标窗口内停止或恢复。
- 关键副作用可对账，未知 broker 语义、未覆盖消费者和未演练恢复均明确标为未验证或阻断。

## 不触发与路由

- 只实现 Go Kafka/RocketMQ/NATS/RabbitMQ 客户端、位点、分区、消费并发或积压处理：路由 `go-mq-patterns`。
- 需要数据库事务、Outbox、Saga、TCC、幂等状态表或对账实现：路由 `go-data-consistency`。
- 只做 Laravel/PHP runtime、worker 常驻内存或框架锁：路由 `senior-php-engineer`；只做 Go 语言写法：路由 `use-modern-go`。
- 跨栈发布顺序和流量回滚：叠加 `polyglot-release-engineering`；业务生产准入和不变量审计：叠加 `backend-acceptance`。
- 只修改一个任务的业务代码而没有契约、重试、回放或跨消费者影响：使用对应语言/框架 skill，不触发本 skill。

