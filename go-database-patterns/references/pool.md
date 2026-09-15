# DSN 与连接池

推导而不是抄表：`MaxOpen` 由 `DB max_connections × 0.8 / 副本数` 反推，再用 `db.Stats().WaitCount` 是否持续增长校正；`MaxIdle` 取 `MaxOpen` 的 1/2～1（超过 MaxOpen 会被截断）；`ConnMaxLifetime` 必须小于 MySQL `wait_timeout`（默认 28800s）与 LB/代理空闲超时（云 LB 常见 60～350s），否则拿到对端已关闭的连接，首个请求报 `broken pipe`/`invalid connection`；`ConnMaxIdleTime` 让低峰期回收连接。

```go
// OpenMySQL 的 dsn 形如：
// app:pw@tcp(10.0.0.1:3306)/shop?parseTime=true&loc=UTC&charset=utf8mb4&clientFoundRows=true&timeout=3s&readTimeout=30s&writeTimeout=30s
// parseTime=true 让 DATETIME 扫进 time.Time（否则只能扫进 []byte/string）；loc=UTC 固定解析时区，避免跟着 DB 会话时区漂移；
// clientFoundRows=true 让 RowsAffected 返回匹配行数而非变更行数——否则 UPDATE 把 name 改成同样的值时返回 0，会被误判成"记录不存在"。
func OpenMySQL(ctx context.Context, dsn string, p PoolConfig, reg prometheus.Registerer) (*sql.DB, error) {
	db, err := sql.Open("mysql", dsn)
	if err != nil {
		return nil, fmt.Errorf("open mysql: %w", err)
	}
	db.SetMaxOpenConns(p.MaxOpen)
	db.SetMaxIdleConns(p.MaxIdle) // 取 MaxOpen 的 1/2～1；过小会在流量抖动时反复建连
	db.SetConnMaxLifetime(p.MaxLifetime)
	db.SetConnMaxIdleTime(p.MaxIdleTime)
	pingCtx, cancel := context.WithTimeout(ctx, 3*time.Second)
	defer cancel()
	if err := db.PingContext(pingCtx); err != nil {
		_ = db.Close()
		return nil, fmt.Errorf("ping mysql: %w", err)
	}
	// 导出 go_sql_{open,in_use,idle}_connections、go_sql_wait_count_total、go_sql_wait_duration_seconds_total、
	// go_sql_max_lifetime_closed_total 等；wait_count 持续增长 = 池打满，先查慢 SQL 再考虑加 MaxOpen。
	if err := reg.Register(collectors.NewDBStatsCollector(db, "shop")); err != nil {
		_ = db.Close()
		return nil, fmt.Errorf("register db stats: %w", err)
	}
	return db, nil
}
```

Postgres 用 `pgxpool.ParseConfig(dsn)` 配 `MaxConns/MinConns/MaxConnLifetime/MaxConnLifetimeJitter/MaxConnIdleTime`（Jitter 取 Lifetime 的 1/10，错开过期时刻避免整池同时重连），`cfg.ConnConfig.RuntimeParams["statement_timeout"] = "30000"` 做 DB 侧兜底；`pgxpool.NewWithConfig` 建池后用 `stdlib.OpenDBFromPool(pool)` 把同一个池暴露成 `*sql.DB` 给 sqlx/GORM——返回的 `*sql.DB` 的 MaxIdle 被 pgx 置 0（idle 由 pgxpool 管），不要再对它调 `SetMaxOpenConns`。
