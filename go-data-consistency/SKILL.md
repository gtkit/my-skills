---
name: go-data-consistency
description: Go 服务的数据一致性与并发正确性模式。当用户讨论事务隔离级别（RC/RR/Serializable）、幻读、间隙锁、死锁（MySQL 1213 / Postgres 40001）与重试、悲观锁 SELECT FOR UPDATE（SKIP LOCKED/NOWAIT）、乐观锁 version 列、原子条件更新、幂等键状态机、Redis SetNX 幂等的缺陷、分布式事务（Saga、TCC、2PC/XA）、本地消息表 / Transactional Outbox、最终一致性、T+1 对账与差异修复时触发。分工：驱动/ORM/连接池/迁移等 DB 客户端用法见 go-database-patterns，缓存与 DB 一致性见 go-cache-consistency，MQ 消费侧幂等/顺序/重试见 go-mq-patterns。
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

## 隔离级别与现象

| | MySQL InnoDB | Postgres |
|---|---|---|
| 默认级别 | REPEATABLE READ | READ COMMITTED |
| RC | 每条语句新快照；无间隙锁（唯一键/外键检查除外），死锁最少；binlog 必须 ROW | 每条语句新快照；同一事务两次读可能不同 |
| RR | 快照读不出现幻读；**当前读**（`FOR UPDATE`/`UPDATE`）加 next-key lock（记录 + 间隙），阻止范围内插入——间隙锁是死锁高发源 | 快照隔离：两次读一致；并发更新同一行报 `40001 could not serialize access due to concurrent update` |
| Serializable | 所有普通 SELECT 隐式加共享锁，吞吐骤降 | SSI：检测依赖环后报 40001，业务必须重试 |
| 出错后事务状态 | 1213 死锁：整个事务已回滚；1205 锁等待超时（默认 50s）：只回滚当前语句，事务仍持锁，必须显式 `Rollback` | 任何错误都让事务进入 aborted（25P02），只能 `ROLLBACK` |

RR 下"先快照读再当前读"是经典写偏斜：SELECT 看到余额 100，UPDATE 时别人已把它改成 0——快照读的结果不能作为写的依据，写依据要来自 `FOR UPDATE` 读或条件 UPDATE。`sql.TxOptions{Isolation: sql.LevelSerializable, ReadOnly: true}` 由驱动翻译成 `SET TRANSACTION ISOLATION LEVEL ...`（mysql）/ `BEGIN ISOLATION LEVEL ... READ ONLY`（pgx）；大多数业务事务用默认级别 + 显式锁，只在报表/一致性快照场景改级别。

## 死锁与序列化失败重试

```go
// IsRetryableTxErr 识别"整个事务重跑一次就可能成功"的错误：
// MySQL 1213 死锁（InnoDB 已回滚整个事务）、1205 锁等待超时（默认只回滚当前语句，事务仍持锁，必须显式 Rollback）；
// Postgres 40001 serialization_failure、40P01 deadlock_detected（事务已 aborted，只能 ROLLBACK）。
func IsRetryableTxErr(err error) bool {
	if me, ok := errors.AsType[*mysql.MySQLError](err); ok {
		return me.Number == 1213 || me.Number == 1205
	}
	if pe, ok := errors.AsType[*pgconn.PgError](err); ok {
		return pe.Code == "40001" || pe.Code == "40P01"
	}
	return false
}

// RunTx：有界重试 + 抖动退避。fn 必须可无副作用地重跑——不在 fn 里发 MQ、调外部接口、改内存状态。
func RunTx(ctx context.Context, db *sql.DB, opts *sql.TxOptions, maxAttempts int, fn func(tx *sql.Tx) error) error {
	maxAttempts = max(maxAttempts, 1) // 0 或负数不能退化成"什么都不做却返回 nil"
	var lastErr error
	for attempt := range maxAttempts {
		err := runOnce(ctx, db, opts, fn)
		if err == nil {
			return nil
		}
		lastErr = err
		if !IsRetryableTxErr(err) || attempt == maxAttempts-1 {
			break
		}
		backoff := time.Duration(attempt+1)*20*time.Millisecond + rand.N(20*time.Millisecond) // 抖动错开多个竞争者
		logger.WarnCtx(ctx, "tx retry", zap.Int("attempt", attempt+1), zap.Duration("backoff", backoff), zap.Error(err))
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(backoff):
		}
	}
	return lastErr
}

func runOnce(ctx context.Context, db *sql.DB, opts *sql.TxOptions, fn func(tx *sql.Tx) error) (err error) {
	tx, err := db.BeginTx(ctx, opts) // opts 例：&sql.TxOptions{Isolation: sql.LevelSerializable}
	if err != nil {
		return fmt.Errorf("begin tx: %w", err)
	}
	defer func() {
		if p := recover(); p != nil {
			_ = tx.Rollback()
			panic(p)
		}
		if err != nil {
			if rbErr := tx.Rollback(); rbErr != nil && !errors.Is(rbErr, sql.ErrTxDone) {
				err = errors.Join(err, rbErr)
			}
		}
	}()
	if err = fn(tx); err != nil {
		return err
	}
	if err = tx.Commit(); err != nil {
		// Commit 返回 context.Canceled / 网络错误时 DB 可能已经提交：这里不能重试也判定不了，靠幂等键或对账兜底。
		return fmt.Errorf("commit: %w", err)
	}
	return nil
}
```

死锁预防比重试更便宜：所有事务按同一顺序拿锁（按主键升序更新）、缩短事务、用 RC 减少间隙锁、批量更新按主键排序后分批。MySQL `SHOW ENGINE INNODB STATUS` 的 `LATEST DETECTED DEADLOCK` 段给出两个事务各自持有与等待的锁，先看这个再改代码。

## 三种锁的选型

| 方案 | 适合 | 不适合 | 判定方式 |
|---|---|---|---|
| 悲观锁 `SELECT ... FOR UPDATE` | 冲突率高、后续逻辑复杂依赖读到的值、任务抢占（配 `SKIP LOCKED`） | 长事务、锁范围大（RR 下范围条件加间隙锁） | 读到即持有，事务结束释放 |
| 乐观锁 version 列 | 读多写少、冲突率低、跨请求的"读-改-写"（前端表单） | 冲突率高（重试风暴）、写热点 | `UPDATE ... WHERE version = ?` 的 RowsAffected |
| 原子条件更新 | 库存/余额/配额等数值扣减、状态机单步流转 | 需要读取旧值做复杂计算 | `UPDATE ... WHERE stock >= ?` 的 RowsAffected |

```go
// 悲观锁：FOR UPDATE 锁行直到事务结束。SKIP LOCKED 跳过被别人锁住的行（任务抢占的标准写法，MySQL 8.0+/Postgres 9.5+）；
// NOWAIT 拿不到锁立即报错（MySQL 3572 / Postgres 55P03），而不是等满 innodb_lock_wait_timeout（默认 50s）拖垮线程池。
func ClaimTask(ctx context.Context, tx *sql.Tx) (int64, error) {
	var id int64
	err := tx.QueryRowContext(ctx,
		`SELECT id FROM tasks WHERE status = 'pending' ORDER BY id LIMIT 1 FOR UPDATE SKIP LOCKED`).Scan(&id)
	if errors.Is(err, sql.ErrNoRows) {
		return 0, ErrNoTask
	}
	if err != nil {
		return 0, fmt.Errorf("claim task: %w", err)
	}
	if _, err := tx.ExecContext(ctx, `UPDATE tasks SET status = 'running' WHERE id = ?`, id); err != nil {
		return 0, fmt.Errorf("mark running: %w", err)
	}
	return id, nil
}

// 乐观锁：读时带出 version，写时 WHERE version = 旧值；RowsAffected == 0 说明有人先改了，调用方重读后重试或直接报冲突。
// 适合读多写少、冲突率低；冲突率高时重试风暴比悲观锁更糟。version = version + 1 保证行一定变化，RowsAffected 不受"值未变"影响。
func UpdateProfile(ctx context.Context, db *sql.DB, id int64, name string, version int64) error {
	res, err := db.ExecContext(ctx,
		`UPDATE profiles SET name = ?, version = version + 1 WHERE id = ? AND version = ?`, name, id, version)
	if err != nil {
		return fmt.Errorf("update profile: %w", err)
	}
	n, err := res.RowsAffected()
	if err != nil {
		return fmt.Errorf("rows affected: %w", err)
	}
	if n == 0 {
		return ErrConflict
	}
	return nil
}

// 原子条件更新：一条 UPDATE 把"检查 + 扣减"交给行锁完成，没有 check-then-act 窗口，也少一次往返。
// 库存、余额、配额这类"数值不能为负"的场景首选。qty <= 0 时 UPDATE 不改值，MySQL 默认 RowsAffected 报 0，会误判缺货，所以先拦。
func DeductStock(ctx context.Context, db *sql.DB, skuID int64, qty int) error {
	if qty <= 0 {
		return fmt.Errorf("invalid qty %d", qty)
	}
	res, err := db.ExecContext(ctx,
		`UPDATE stocks SET available = available - ? WHERE sku_id = ? AND available >= ?`, qty, skuID, qty)
	if err != nil {
		return fmt.Errorf("deduct stock: %w", err)
	}
	n, err := res.RowsAffected()
	if err != nil {
		return fmt.Errorf("rows affected: %w", err)
	}
	if n == 0 {
		return ErrOutOfStock
	}
	return nil
}
```

单行热点（秒杀同一 SKU）三种锁都会在行锁上排队；解法是拆分（库存分桶到 N 行）、前置 Redis 预扣 + DB 异步落账、或排队削峰，不是换锁。

## 幂等键状态机

状态只有三个：不存在 → processing → done。DB 实现靠主键/唯一键做原子抢占，`FOR UPDATE` 串行化并发重复请求；下面的 `DBStore` 实现 go-microservice 定义的 `idem.Store`（`Begin/Done/Fail`）。

```go
// Begin 原子抢占：返回 StateNone 表示本次拿到执行权。
// INSERT 单独自动提交，不放进下面的事务：Postgres 里任何报错（含 23505）都让事务进入 aborted，后续 SELECT 直接失败。
func (s *DBStore) Begin(ctx context.Context, key string) (State, []byte, error) {
	now := time.Now()
	ttl := max(s.TTL, time.Minute) // TTL 为零意味着任何并发重复请求都能立刻接管
	_, err := s.DB.ExecContext(ctx, `INSERT INTO idempotency_keys (idem_key, state, expires_at) VALUES (?, ?, ?)`,
		key, StateProcessing, now.Add(ttl))
	switch {
	case err == nil:
		return StateNone, nil, nil
	case !isDuplicate(err):
		return StateNone, nil, fmt.Errorf("insert idempotency key: %w", err)
	}
	tx, err := s.DB.BeginTx(ctx, nil)
	if err != nil {
		return StateNone, nil, fmt.Errorf("begin: %w", err)
	}
	defer func() { _ = tx.Rollback() }() // Commit 成功后返回 ErrTxDone，无害
	var (
		state   State
		result  []byte
		expires time.Time
	)
	err = tx.QueryRowContext(ctx, // FOR UPDATE 把并发重复请求串行化：同一时刻只有一个能接管过期记录
		`SELECT state, result, expires_at FROM idempotency_keys WHERE idem_key = ? FOR UPDATE`, key).
		Scan(&state, &result, &expires)
	if err != nil {
		return StateNone, nil, fmt.Errorf("load idempotency key: %w", err)
	}
	if state == StateDone {
		return StateDone, result, nil
	}
	if now.Before(expires) {
		return StateProcessing, nil, nil
	}
	if _, err := tx.ExecContext(ctx, `UPDATE idempotency_keys SET expires_at = ? WHERE idem_key = ?`, now.Add(ttl), key); err != nil {
		return StateNone, nil, fmt.Errorf("take over idempotency key: %w", err)
	}
	return StateNone, nil, tx.Commit()
}
```

- `isDuplicate` 用 `errors.AsType` 识别 MySQL 1062 / Postgres 23505。`Done` 用 `WHERE state = processing` 条件更新写结果，`Fail` 只在业务确定无副作用时删记录。
- processing 过期接管意味着业务会被重做：业务写全在本库时，直接把 INSERT key 与业务写放同一事务，唯一键冲突即重复，不需要 processing 态；涉及外部调用时，外部调用必须携带同一 key 让下游去重。
- Redis `SetNX` 做幂等的失败模式：① 并发假成功——第二个请求看到 key 存在就返回成功，但没有结果可回放，客户端拿到 200 却没有订单号；② 崩溃残留——SetNX 后进程挂掉，key 直到 TTL 才消失，期间重试全被拒；③ 主从切换丢 key——异步复制下主库写入后立刻宕机，新主没有这个 key，重复请求放行。三条里任何一条都足以否决"只用 Redis"，它只能挡在 DB 唯一键前面减轻压力。

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

## Transactional Outbox

```go
// Enqueue 必须在业务事务内调用。
func Enqueue(ctx context.Context, tx *sql.Tx, topic string, payload []byte) error {
	if _, err := tx.ExecContext(ctx,
		`INSERT INTO outbox (topic, payload, status, attempts, next_at) VALUES (?, ?, 0, 0, ?)`,
		topic, payload, time.Now()); err != nil {
		return fmt.Errorf("enqueue outbox: %w", err)
	}
	return nil
}

func (r *Relay) relayBatch(ctx context.Context) (int, error) {
	tx, err := r.DB.BeginTx(ctx, nil)
	if err != nil {
		return 0, fmt.Errorf("begin: %w", err)
	}
	defer func() { _ = tx.Rollback() }()
	msgs, err := lockPending(ctx, tx, r.Batch)
	if err != nil {
		return 0, err
	}
	for _, m := range msgs {
		if err := r.Pub.Publish(ctx, m.Topic, strconv.FormatInt(m.ID, 10), m.Payload); err != nil {
			// 失败：attempts+1 并指数退避推迟；attempts 超阈值的行由告警/人工处理，不无限重试
			backoff := time.Duration(1<<min(m.Attempts, 8)) * time.Second
			logger.WarnCtx(ctx, "outbox publish failed", zap.Int64("id", m.ID), zap.Int("attempts", m.Attempts+1), zap.Error(err))
			if _, uerr := tx.ExecContext(ctx, `UPDATE outbox SET attempts = attempts + 1, next_at = ? WHERE id = ?`,
				time.Now().Add(backoff), m.ID); uerr != nil {
				return 0, fmt.Errorf("defer outbox %d: %w", m.ID, uerr)
			}
			continue
		}
		if _, err := tx.ExecContext(ctx, `UPDATE outbox SET status = 1 WHERE id = ?`, m.ID); err != nil {
			return 0, fmt.Errorf("mark sent %d: %w", m.ID, err)
		}
	}
	if err := tx.Commit(); err != nil {
		return 0, fmt.Errorf("commit: %w", err)
	}
	return len(msgs), nil
}
```

- `lockPending` 是 `SELECT id, topic, payload, attempts FROM outbox WHERE status = 0 AND next_at <= ? ORDER BY id LIMIT ? FOR UPDATE SKIP LOCKED`，多副本 relay 各自抢到不同的行；`Run` 循环在批满时立即继续，空闲时按 ticker 轮询。
- 语义是 at-least-once：Publish 成功但 Commit 前崩溃会重投，消费端按 `outbox.id`（作为消息 key）幂等，见 go-mq-patterns。
- 持锁期间做网络 IO，所以 Batch 小（≤ 100）、Publish 带 ≤ 2s 超时；表上建 `(status, next_at)` 索引，已发送的行定期归档，否则表只增不减拖慢 `SKIP LOCKED` 扫描。
- 轮询延迟不可接受时改 CDC（Debezium/Canal 读 binlog 投递 outbox 表变更），语义不变。

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
