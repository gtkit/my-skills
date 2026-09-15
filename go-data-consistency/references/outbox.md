# Transactional Outbox

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
