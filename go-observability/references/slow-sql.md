# 慢 SQL

```go
// Trace 由 GORM 在每条 SQL 结束后调用；fc 惰性生成 SQL 文本，只在真要记日志时才调用。
func (l *GormLogger) Trace(ctx context.Context, begin time.Time, fc func() (string, int64), err error) {
	if l.level <= gormlogger.Silent {
		return
	}
	elapsed := time.Since(begin)
	switch {
	case err != nil && !errors.Is(err, gorm.ErrRecordNotFound) && l.level >= gormlogger.Error:
		sql, rows := fc()
		logger.ErrorCtx(ctx, "sql error", zap.Error(err), zap.String("sql", sql),
			zap.Int64("rows", rows), zap.Duration("elapsed", elapsed))
	case l.slow > 0 && elapsed > l.slow && l.level >= gormlogger.Warn:
		sql, rows := fc()
		logger.WarnCtx(ctx, "slow sql", zap.String("sql", sql), zap.Int64("rows", rows),
			zap.Duration("elapsed", elapsed), zap.Duration("threshold", l.slow))
	}
}

// ParamsFilter 实现 gorm.ParamsFilter：丢弃参数值，fc 返回的 SQL 只含 ? 占位符——
// 参数里的手机号、身份证不落日志（与 GORM 自带 logger 的 ParameterizedQueries 机制相同）。
func (l *GormLogger) ParamsFilter(_ context.Context, sql string, _ ...any) (string, []any) {
	return sql, nil
}
```

`GormLogger` 其余方法（`LogMode` 拷贝自身改级别；`Info/Warn/Error` 按级别转 `logger.InfoCtx` 等）见 build 文件；接入 `gorm.Open(mysql.Open(dsn), &gorm.Config{Logger: slowsql.New(200 * time.Millisecond)})`。`Trace` 收到的 ctx 就是业务传给 `db.WithContext(ctx)` 的 ctx，所以慢 SQL 日志天然带 trace_id。

要做 DB 耗时 histogram 时用 Before / After 回调配对：`db.Callback().Query().Before("gorm:query").Register(name, fn)` 里 `db.InstanceSet(key, time.Now())`，After 回调 `v, ok := db.InstanceGet(key)` 再 `start, isTime := v.(time.Time)` 带 ok 断言，label 只用 `db.Statement.Table`（空串映射 `raw`）。`Statement.Context.Value(key)` 拿不到 Before 里设的值（没人往 ctx 里写过），对 nil 裸断言 `.(time.Duration)` 直接 panic——这是此前版本的错误。
