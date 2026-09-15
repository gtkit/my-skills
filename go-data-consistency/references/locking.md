# 三种锁的选型与实现

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
