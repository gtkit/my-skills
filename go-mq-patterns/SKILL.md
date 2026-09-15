---
name: go-mq-patterns
description: Go 消息队列：Kafka/RocketMQ/NATS/RabbitMQ 客户端选型、投递语义、消费幂等、顺序、重试与死信、位点提交、事务消息、延迟消息、积压。编写或审查 MQ 生产者、消费者代码时使用。
---

# Go 消息队列模式

MQ 客户端选型、投递语义与消费端实现（幂等、顺序、重试、死信、位点、积压）。Outbox 与 DB 事务见 go-data-consistency，限流熔断见 go-stability-engineering。
标「go doc」的结论来自客户端库文档，标「源码」的来自客户端源码；版本为核实时各库的最新发布。

## 核心规则

1. 所有主流 MQ 给消费端的保证都是 at-least-once；"exactly-once"只能靠消费端幂等实现，不是靠 broker 配置。
2. 位点在业务处理完成后提交。自动提交提交的是"已拉取"而不是"已处理"，崩溃即丢消息。
3. 顺序只在一个分区/队列内成立；重试会破坏顺序，需要顺序就原地重试，不投回队尾。
4. 重试必须有界、带退避、区分可重试与不可重试；超限与不可重试的消息进死信，不能无限重投阻塞分区。
5. handler 的 panic 必须在 handler 边界 recover；一条毒丸不能带走整个消费者进程。
6. Kafka 分区数只能增不能减，增分区会改变 key→分区映射；消费者数 ≤ 分区数，多出来的空转。
7. 死信写入失败时不能提交位点：宁可让消费者退出重启，不能让消息消失。
8. 生产端 acks=all + 幂等生产 + 有界缓冲 + 投递超时；kafka-go 的 `Writer.RequiredAcks` 默认 `RequireNone`（go doc），写丢不报错。
9. 消息头固定携带 message-id、traceparent、schema-version；正文超 1 MB 走对象存储 + 引用。
10. 需要同步结果、强一致读、或日消息量在万级以内且已有 DB 的场景，不引入 MQ。

## 按任务读取

以下内容按任务读取，只读本次需要的文件；核心规则与审查清单已覆盖其结论。

| 任务 | 读 |
|---|---|
| 写消费者：franz-go 骨架、位点提交、优雅关闭 | `references/consumer.md` |
| 重试、死信与毒丸处理 | `references/retry-dlq.md` |
| 消费幂等（`ConsumeOnce`） | `references/idempotency.md` |
| 事务消息与 Outbox | `references/outbox.md` |
| 写生产者与 trace 传递 | `references/producer.md` |

## 选型

| 系统 / 客户端 | 版本（发布） | 适合 | 不适合 / 陷阱 |
|---|---|---|---|
| Kafka + `twmb/franz-go`（`pkg/kgo`） | v1.21.6（2026-08） | 高吞吐事件流；需要精细位点控制、事务、管理 API（`pkg/kadm` 查 lag、加分区） | 默认幂等生产、acks=all、cooperative-sticky 均衡器（go doc）；API 面大，用前读 go doc |
| Kafka + `IBM/sarama` | v1.60.2（2026-08） | 存量项目；SASL/Kerberos 生态最全 | `ConsumerGroupHandler` 回调式 API 冗长；默认均衡策略仍是 range（go doc）；幂等生产要求 `Net.MaxOpenRequests=1` + `WaitForAll`（go doc） |
| Kafka + `segmentio/kafka-go` | v0.4.51（2026-04） | 小项目，API 最简 | `Writer.RequiredAcks` 默认 `RequireNone`；`Reader.CommitInterval` 为 0 才是同步提交（go doc） |
| RocketMQ 4.x + `apache/rocketmq-client-go/v2` | v2.1.2（2023-08，之后无发布） | 阿里系存量集群；事务消息、18 级延迟、顺序消息、Tag 过滤是原生能力 | remoting 协议直连 NameServer；依赖 logrus 等旧库；三年无发布 |
| RocketMQ 5.x + `apache/rocketmq-clients/golang/v5` | v5.1.4（2026-06） | 新建 RocketMQ 5 集群；任意时间戳延迟 `SetDelayTimestamp`、`SetMessageGroup` 顺序 | 走 gRPC Proxy，连不上 4.x 集群 |
| NATS JetStream `nats-io/nats.go/jetstream` | v1.53.1（2026-08） | 云原生轻量事件、请求-响应与持久化混合 | 单条 `Ack/Nak/Term`、`MaxDeliver` + `BackOff`、`Nats-Msg-Id` 去重窗口默认 2 分钟（go doc）；不做长期留存与全量回放 |
| RabbitMQ `rabbitmq/amqp091-go` | v1.14.0（2026-08） | 任务队列、复杂路由（exchange/binding）、单条确认 | 无分区概念，顺序只在单队列单消费者成立；DLX 靠队列参数 `x-dead-letter-exchange`；吞吐量级低于 Kafka |

## 投递语义

- at-most-once：先提交后处理，崩溃丢消息。只用于可丢的指标/日志。
- at-least-once：处理完再提交，崩溃重复。所有业务消息的默认。
- exactly-once：Kafka 事务（`kgo.TransactionalID` + `GroupTransactSession`）只覆盖"消费 Kafka → 写 Kafka"闭环；处理逻辑一旦写 DB / 调 HTTP，事务覆盖不到，重复照样出现。对外部副作用，**幂等消费是唯一可靠的 exactly-once**。
- 幂等键：优先生产端生成的业务消息 ID（订单号 + 事件类型）写进消息头；`topic-partition-offset` 只在同一 topic 内唯一，重放到新 topic 后失效。
- 幂等落点：与业务同一 DB 事务的唯一约束（`references/idempotency.md` 的 `ConsumeOnce`）优于 Redis `SET NX`——进程在 SETNX 之后、业务提交之前崩溃，键留下了业务没做，要再补"处理完置成功态"的第二阶段（见 go-data-consistency）。

## 位点提交与 rebalance

- franz-go 自动提交间隔默认 5s（go doc），提交的是已拉取位点：拉了 500 条处理到第 10 条时提交，崩溃后 490 条丢失。所以 `DisableAutoCommit()`，处理完一批再 `CommitUncommittedOffsets`。
- rebalance 默认与消费完全独立（go doc）：处理到一半分区被收走，提交会落到不再拥有的分区，甚至把别人已提交的位点倒回去。`BlockRebalanceOnPoll()` 让 rebalance 等你 `AllowRebalance()`；代价是处理超过 `RebalanceTimeout`（默认 60s，go doc）会被踢出组，所以必须用 `PollRecords(ctx, n)` 限批。
- 关停时提交不能用已取消的 ctx（最后一批白处理），用 `context.WithoutCancel(ctx)` + 独立短超时。
- 一批只提交一次，中途崩溃重放 ≤ 批大小：这是吞吐与重复量的取舍，靠幂等兜底，不靠逐条提交。

## 延迟消息

- RocketMQ 4.x `WithDelayTimeLevel(1..18)`：1s 5s 10s 30s 1m 2m … 10m 20m 30m 1h 2h 固定等级（go doc），不能任意时刻；5.x `SetDelayTimestamp` 任意时刻。
- Kafka 原生无延迟：按档位建 `delay-5m`、`delay-1h` 等 topic，专用消费者读到未到期消息就 `PauseFetchPartitions` 等待再转投目标 topic（同档位 topic 内先进先到期，队头未到期后面必未到期）；任意时刻延迟用 DB / Redis ZSET 做时间轮再投 Kafka。
- NATS `NakWithDelay` 是重投延迟不是业务延迟；RabbitMQ 用 `x-delayed-message` 插件或 TTL + DLX。

## 积压处理

- lag 两处测：消费者进程内按批算 `HighWatermark - offset`（进程死了就没数据）；broker 侧 `kadm.Client.Lag(ctx, groups...)` 返回 `DescribedGroupLags`（按组名索引的 map），逐组先查 `Error()`（描述组失败 / 拉位点失败）再用 `Lag.Sorted()` / `Lag.Total()` 上报——消费者全挂也能报警。告警按"lag 持续增长 N 分钟"，不按绝对值。
- 扩容顺序：先看处理耗时（慢在下游 DB / HTTP 时加消费者只会压垮下游）→ 消费者数加到等于分区数 → 再考虑加分区。加分区不可逆且打乱 key 映射，需要顺序的 topic 改为建新 topic 双写迁移。
- 旁路消费：积压的是可丢或可延迟的消息时，临时消费者只做"落盘 + 跳过"，让主流量先恢复。

## 消息设计

- schema 用 protobuf / Avro：只加字段、不删不改类型、字段号不复用；消费端忽略未知字段。
- 消息头固定：`message-id`（幂等键）、`traceparent`、`schema-version`、`produced-at`；正文只放业务数据。
- key 是顺序与幂等的锚：订单事件 key = 订单号，用户事件 key = 用户 ID；随机 key 等于放弃顺序。

## 何时不该用 MQ

| 场景 | 选择 | 理由 |
|---|---|---|
| 调用方要同步结果（下单立刻要库存扣减结果） | RPC / HTTP | MQ 拿不到返回值，凑请求-响应要两条队列 + 关联 ID |
| 强一致读（扣完钱立刻查余额） | 同一 DB 事务 | MQ 是最终一致，读到旧值是设计内行为 |
| 日消息量万级、已有 DB | DB 表 + `FOR UPDATE SKIP LOCKED` 轮询 | 少一个基础设施、可用 SQL 排障 |

## 审查清单

- [ ] 关闭自动提交，处理完再提交；关停时提交用 `WithoutCancel` + 独立超时
- [ ] 开了 `BlockRebalanceOnPoll` 就配 `PollRecords` 限批、批后 `AllowRebalance`、关闭用 `CloseAllowingRebalance`
- [ ] `OnPartitionsRevoked` 里提交位点
- [ ] handler 有单条超时与边界 recover；panic 不杀进程
- [ ] 重试有界、有退避、区分 Permanent；超限进死信；死信写失败不提交位点
- [ ] 幂等键来自业务 / 消息 ID，落在与业务同事务的唯一约束
- [ ] 顺序消息 key 选对；分区内串行；重试原地不投队尾
- [ ] 生产端 acks=all、幂等开、设了 `RecordDeliveryTimeout` 与 `MaxBufferedRecords`；kafka-go 显式设 `RequiredAcks`
- [ ] 消息头带 message-id / traceparent / schema-version；大消息外置
- [ ] broker 侧 lag 监控与"持续增长"告警；消费者数 ≤ 分区数
- [ ] RocketMQ 事务：回查未知返回 `UnknowState`；本地事务落了业务键
- [ ] 评估过不用 MQ：同步结果 / 强一致 / 小量场景没有硬上
