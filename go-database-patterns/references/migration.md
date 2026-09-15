# 迁移、大表变更与建表规范

## 迁移与大表变更

```go
// Up 的 dsn 形如 mysql://app:pw@tcp(10.0.0.1:3306)/shop?parseTime=true&loc=UTC
// 用 URL 打开时 migrate 的 MySQL 驱动自动开启 MultiStatements；改用 mysql.WithInstance 传入已有 *sql.DB 时，
// 那个 DSN 必须带 multiStatements=true，否则含多条语句的迁移文件报 syntax error。
// 互锁：MySQL 驱动 GET_LOCK(name, 10) 等 10 秒拿不到返回 ErrLocked；Postgres 驱动 pg_advisory_lock 阻塞等待。
// 多副本同时启动跑迁移会互相等锁、拖长发布——迁移放独立 Job / initContainer 只跑一次。
func Up(dir, dsn string) error {
	m, err := migrate.New("file://"+dir, dsn)
	if err != nil {
		return fmt.Errorf("init migrate: %w", err)
	}
	m.Log = migrateLogger{}
	defer func() {
		if srcErr, dbErr := m.Close(); srcErr != nil || dbErr != nil {
			logger.Warn("close migrate", zap.NamedError("source", srcErr), zap.NamedError("database", dbErr))
		}
	}()
	if err := m.Up(); err != nil && !errors.Is(err, migrate.ErrNoChange) {
		return fmt.Errorf("migrate up: %w", err)
	}
	return nil
}
```

`migrateLogger` 实现 `migrate.Logger`（`Printf` 转 `logger.Infof`，`Verbose()` 返回 false）。大表（千万行以上）改结构的规则：

- MySQL 8.0 加列/改默认值走 `ALGORITHM=INSTANT`（元数据操作，毫秒级）；其他 DDL 用 `gh-ost` 或 `pt-online-schema-change`，禁止裸 `ALTER TABLE`——它会持有元数据锁，后续所有查询排队。
- 改列类型、重命名列走 expand-contract：加新列 → 双写 → 回填 → 切读 → 停写旧列 → 删旧列，每步独立发布，可随时停在中间。
- 迁移文件只加不改：已应用的版本文件一旦修改，其他环境的 `schema_migrations` 校验不出差异。
- GORM `AutoMigrate` 只在本地/测试用：它不删列、不改类型缩窄、不可回滚、没有版本记录，生产 schema 变更必须走版本化迁移。

## 建表规范（MySQL）

```sql
CREATE TABLE users (
    id         BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
    email      VARCHAR(255)    NOT NULL,
    name       VARCHAR(100)    NOT NULL,
    phone      VARCHAR(32)     NULL,
    created_at DATETIME(6)     NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    updated_at DATETIME(6)     NOT NULL DEFAULT CURRENT_TIMESTAMP(6) ON UPDATE CURRENT_TIMESTAMP(6),
    deleted_at DATETIME(6)     NULL,
    UNIQUE KEY uk_email (email),
    KEY idx_created_id (created_at, id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;
```

- `DATETIME(6)` 而非 `TIMESTAMP`：TIMESTAMP 上限 2038-01-19，且随会话时区转换；应用侧统一 UTC。
- 索引：`UNIQUE KEY uk_email` 已是索引，再建 `KEY idx_email` 是冗余；`(a, b)` 联合索引已覆盖 `(a)` 前缀，单独 `(a)` 也冗余。
- 软删除与唯一键冲突：删过的 email 无法再注册。两种解法——去掉 `UNIQUE`，改应用层校验 + 定期清理；或唯一键改为 `(email, deleted_at)` 且 `deleted_at` 用非空哨兵值（`'1970-01-01'`，因为 `NULL != NULL` 不触发唯一约束）。
- 金额列 `BIGINT`（分）或 `DECIMAL(20,4)`，禁 `FLOAT/DOUBLE`。
