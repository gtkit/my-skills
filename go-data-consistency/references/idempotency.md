# 幂等键状态机

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
