# 死锁与序列化失败重试

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
