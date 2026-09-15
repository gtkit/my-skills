---
name: go-data-consistency
description: Go 数据一致性：隔离级别与幻读、死锁重试、悲观/乐观锁、幂等键状态机、Saga/TCC/Outbox、对账。设计事务边界、并发扣减、跨库或跨服务一致性时使用。
---

# Go 数据一致性模式

单库并发正确性（隔离级别、锁、死锁重试、幂等键）与跨库/跨服务一致性（Saga、TCC、Outbox、对账）。示例用 `database/sql` 写 MySQL 方言（Postgres 差异随行标注），日志一律 `github.com/gtkit/logger/v2`。

## 核心规则

1. 先合库再谈分布式事务：能放进一个数据库事务的写，不拆成两个服务。
2. 有界重试只针对 MySQL 1213/1205、Postgres 40001/40P01 这类"重跑一次可能成功"的错误；`Commit` 返回 `context.Canceled` 不在其中——DB 可能已提交。
3. 事务体内不做网络 IO（HTTP、MQ、Redis）：锁持有时间等于最慢的外部调用。
4. "检查再更新"改成一条条件 UPDATE（`WHERE stock >= ?`），用 `RowsAffected` 判定结果，而不是先 SELECT 再判断。
5. 幂等键落 DB 唯一键；Redis `SetNX` 只能做加速层，不能做正确性依据。
6. 跨服务的"消息一定发出"只有一种实现：消息与业务写同一事务落 outbox 表，由独立 relay 投递；消费端按消息 id 幂等。
7. Saga 的每个补偿动作必须幂等，且不因原请求 ctx 取消而中断（`context.WithoutCancel`）。
8. TCC 必须处理空回滚（Cancel 先于 Try 到达）与悬挂（Try 晚于 Cancel 到达），靠事务状态表的唯一键。
9. 任何最终一致方案都要配对账：没有对账的最终一致 = 不知道什么时候不一致。
10. 契约（幂等、有界、最多一次）没有反证测试就不写进注释。

## 按任务读取

以下内容按任务读取，只读本次需要的文件；核心规则与审查清单已覆盖其结论。

| 任务 | 读 |
|---|---|
| 处理 MySQL 1213 / Postgres 40001，写重试逻辑 | `references/deadlock-retry.md` |
| 悲观锁、乐观锁、原子条件更新的实现 | `references/locking.md` |
| 实现幂等键与状态机 | `references/idempotency.md` |
| 实现本地消息表 / Outbox | `references/outbox.md` |

## 隔离级别与现象

| | MySQL InnoDB | Postgres |
|---|---|---|
| 默认级别 | REPEATABLE READ | READ COMMITTED |
| RC | 每条语句新快照；无间隙锁（唯一键/外键检查除外），死锁最少；binlog 必须 ROW | 每条语句新快照；同一事务两次读可能不同 |
| RR | 快照读不出现幻读；**当前读**（`FOR UPDATE`/`UPDATE`）加 next-key lock（记录 + 间隙），阻止范围内插入——间隙锁是死锁高发源 | 快照隔离：两次读一致；并发更新同一行报 `40001 could not serialize access due to concurrent update` |
| Serializable | 所有普通 SELECT 隐式加共享锁，吞吐骤降 | SSI：检测依赖环后报 40001，业务必须重试 |
| 出错后事务状态 | 1213 死锁：整个事务已回滚；1205 锁等待超时（默认 50s）：只回滚当前语句，事务仍持锁，必须显式 `Rollback` | 任何错误都让事务进入 aborted（25P02），只能 `ROLLBACK` |

RR 下"先快照读再当前读"是经典写偏斜：SELECT 看到余额 100，UPDATE 时别人已把它改成 0——快照读的结果不能作为写的依据，写依据要来自 `FOR UPDATE` 读或条件 UPDATE。`sql.TxOptions{Isolation: sql.LevelSerializable, ReadOnly: true}` 由驱动翻译成 `SET TRANSACTION ISOLATION LEVEL ...`（mysql）/ `BEGIN ISOLATION LEVEL ... READ ONLY`（pgx）；大多数业务事务用默认级别 + 显式锁，只在报表/一致性快照场景改级别。

## 分布式事务选型

| 方案 | 一致性 | 适合 | 代价 / 陷阱 |
|---|---|---|---|
| 合库单事务 | 强 | 能合就合 | 无 |
| Transactional Outbox / 本地消息表 | 最终 | 一个服务写库 + 通知下游（订单→积分、库存、通知） | 消费端必须幂等；relay 是 at-least-once |
| Saga（编排） | 最终 | 多步跨服务流程、每步都有业务上可定义的补偿 | 补偿必须幂等；中间态对外可见；编排器状态要持久化 |
| Saga（协同/事件驱动） | 最终 | 步骤少（≤ 3）、参与方松耦合 | 流程散落各服务，排障困难；步骤多时改用编排 |
| TCC | 准实时 | 资源可"预留"（冻结额度、锁库存）、需要业务层隔离 | Try/Confirm/Cancel 三接口全要幂等；空回滚与悬挂 |
| 2PC / XA | 强 | 同组织内跨库、低 TPS、无法合库（账务批处理） | 阻塞协议、协调者单点、锁跨网络 RTT；在线高并发不用 |

- Saga 编排骨架：顺序执行，某步失败逆序补偿。补偿失败不能吞——记日志、汇总返回、进对账。生产实现每步状态落 `saga_instances` 表，编排器崩溃后从表恢复。需要框架时看 `dtm-labs/dtm`（Saga/TCC/XA/二阶段消息）。

```go
// Run 是编排式 Saga 的最小骨架：顺序执行，某步失败则逆序补偿已成功的步骤。
// 生产实现必须把每步状态持久化（saga_instances 表），否则编排器崩溃后既不知道该补偿谁也无法恢复。
func Run(ctx context.Context, steps []Step) error {
	done := make([]Step, 0, len(steps))
	for _, s := range steps {
		if err := s.Do(ctx); err != nil {
			return compensate(context.WithoutCancel(ctx), done, fmt.Errorf("step %s: %w", s.Name, err))
		}
		done = append(done, s)
	}
	return nil
}

// 补偿不能因为原请求的 ctx 取消而中断（所以用 WithoutCancel）；补偿失败不能吞——记日志并汇总返回，交给对账/人工。
func compensate(ctx context.Context, done []Step, cause error) error {
	errs := []error{cause}
	for _, s := range slices.Backward(done) {
		if cerr := s.Compensate(ctx); cerr != nil {
			logger.ErrorCtx(ctx, "saga compensate failed", zap.String("step", s.Name), zap.Error(cerr))
			errs = append(errs, fmt.Errorf("compensate %s: %w", s.Name, cerr))
		}
	}
	return errors.Join(errs...)
}
```

- TCC 的两个必修陷阱：**空回滚**——Try 超时未执行但 Cancel 已到达，Cancel 必须识别"没有 Try 过"并直接成功，同时插入 `(xid, branch, status=cancelled)` 记录；**悬挂**——迟到的 Try 在 Cancel 之后到达，若执行就把资源永久冻结，所以 Try 先查该记录、存在即拒绝。两者都靠事务状态表的 `(xid, branch)` 唯一键实现。

## 对账与修复

- T+1 对账：按自然日拉取双方账（本地订单/流水 vs 渠道对账文件），以业务单号做全外连接，差异分三类——本地有对方无（长款/未落账）、对方有本地无（短款/漏单）、两边都有但金额或状态不一致。
- 近实时校验：对 outbox/Saga 这类最终一致链路，每 N 分钟核对最近窗口（如 10 分钟前到 5 分钟前）的上下游状态，比 T+1 早一天发现问题。
- 修复任务幂等：每条差异生成唯一 `diff_id`，修复动作是条件 UPDATE（`WHERE status = 'pending'`）或带 `diff_id` 幂等键的接口调用；修复前重新读取实时状态——对账文件是滞后快照，可能已被正常流程补齐。
- 自动修复只做"补状态/补记录"，涉及资金方向的差异（多付、少收）只生成工单，人工确认后执行。

## 何时不该用分布式事务

| 场景 | 选择 | 理由 |
|---|---|---|
| 两个表在同一个库 | 单事务 | 拆微服务不等于拆数据库 |
| 下游只需要"知道发生了什么" | Outbox + 事件 | 通知不需要回滚 |
| 下游失败可以晚点再试 | Outbox / 异步任务 | 异步重试比同步补偿简单一个量级 |
| 步骤 ≤ 3 且都可补偿 | Saga | TCC 三接口的开发量是 Saga 的两倍 |
| 需要"预留-确认"语义（冻结额度） | TCC | Saga 的中间态会被别人看到并消费 |
| 在线高并发 | 除 XA 外任何方案 | XA 锁跨 RTT，吞吐上限太低 |

## 审查清单

- [ ] 事务体内没有 HTTP/MQ/Redis 调用；事务持续时间有上限（ctx 超时）
- [ ] 重试只针对 1213/1205/40001/40P01，有次数上限与抖动；`Commit` 的 ctx 错误没有被当作"未提交"
- [ ] 1205 之后显式 `Rollback`；Postgres 事务出错后没有继续发语句
- [ ] 写依据来自 `FOR UPDATE` 读或条件 UPDATE，不是普通 SELECT 的快照
- [ ] 每处 `RowsAffected` 判定前先判 `err`；MySQL DSN 带 `clientFoundRows=true` 或语句保证值一定变化
- [ ] 悲观锁的范围条件评估过间隙锁；任务抢占用 `SKIP LOCKED`；不想等锁用 `NOWAIT`
- [ ] 幂等键落 DB 唯一键，有 processing 过期接管；业务写与 key 同事务（或外部调用带同一 key）
- [ ] Outbox 写入与业务写同一事务；relay 多副本用 `SKIP LOCKED`；消费端按消息 id 幂等；有积压告警与归档
- [ ] Saga 每步状态持久化；补偿幂等、用 `WithoutCancel`、失败不吞
- [ ] TCC 有事务状态表，空回滚与悬挂各有一个测试
- [ ] 最终一致链路配了对账（近实时 + T+1），修复任务幂等，资金类差异走人工确认
- [ ] 幂等/有界/最多一次等契约各有一个"为假则失败"的测试
