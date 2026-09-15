# 消费幂等

```go
// processed_messages(msg_id PRIMARY KEY, consumed_at) 与业务写入在同一事务里：
// 要么"标记 + 业务"一起提交，要么一起回滚，不存在"业务成了标记没写"的窗口。
const insertMark = `INSERT INTO processed_messages (msg_id, consumed_at) VALUES ($1, NOW()) ON CONFLICT (msg_id) DO NOTHING`

// ConsumeOnce 以 msgID 为幂等键执行 apply；重复消息返回 ErrDuplicate，调用方按成功处理（提交位点）。
func ConsumeOnce(ctx context.Context, db *sql.DB, msgID string, apply func(ctx context.Context, tx *sql.Tx) error) error {
	tx, err := db.BeginTx(ctx, nil)
	if err != nil {
		return fmt.Errorf("begin: %w", err)
	}
	defer func() { _ = tx.Rollback() }() // Commit 成功后 Rollback 返回 ErrTxDone，忽略即可
	res, err := tx.ExecContext(ctx, insertMark, msgID)
	if err != nil {
		return fmt.Errorf("标记消息: %w", err)
	}
	n, err := res.RowsAffected()
	if err != nil {
		return fmt.Errorf("rows affected: %w", err)
	}
	if n == 0 {
		return ErrDuplicate
	}
	if err := apply(ctx, tx); err != nil {
		return err
	}
	return tx.Commit()
}
```

- 标记与业务写入同一事务，不存在"业务成了标记没写"或反过来的窗口。MySQL 用 `INSERT IGNORE`。
- `ErrDuplicate` 对消费者是成功：位点照常提交。标记表按 `consumed_at` 清理，保留期大于最长可能的重放跨度。
