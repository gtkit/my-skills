---
name: go-database-patterns
description: Go 数据访问层：database/sql、pgx、sqlx、sqlc、GORM 选型与陷阱、DSN 与连接池参数、查询正确性、keyset 分页、索引、迁移与大表变更、读写分离。在 Go 里操作 MySQL/Postgres 时使用。
---

# Go 数据库访问模式

覆盖驱动、ORM、查询正确性、连接池、迁移、分页、索引、读写分离与数据库测试。并发正确性（隔离级别、锁、分布式事务）见 go-data-consistency。代码遵循 use-modern-go，日志一律 `github.com/gtkit/logger/v2`。

## 核心规则

1. Postgres 用 `jackc/pgx/v5`（`lib/pq` 处于维护模式）；MySQL 用 `go-sql-driver/mysql`，DSN 必带 `parseTime=true&loc=UTC`。
2. 连接池四个参数全部显式设置，且 `副本数 × MaxOpen ≤ DB max_connections × 0.8`，`ConnMaxLifetime` 小于 DB 与代理的空闲超时。
3. `rows.Next()` 循环结束后必查 `rows.Err()`，否则网络中断时拿到被截断的结果集却没有错误。
4. `err`/`result.Error` 先判，再看 `RowsAffected`：出错时 RowsAffected 也是 0，跳过判错会把死锁伪装成"记录不存在"。
5. 拼进 SQL 文本的标识符（列名、排序、表名）只能来自白名单 map；值只能走占位符。`fmt.Sprintf("ORDER BY %s", x)` 是注入。
6. 禁 `SELECT *`：列增删后 Scan 目标错位，轻则报错重则静默串列。
7. 软删除只有 `gorm.DeletedAt` 类型有自动语义；手写 SQL 必须自己加 `deleted_at IS NULL`。
8. 多条写包事务（`db.Transaction` / `BeginTx`），事务体内不做网络 IO、不发 MQ。
9. 金额用 `int64`（分）或 decimal，禁 `float64`：`0.1 + 0.2 != 0.3`，累加对不上账。
10. 每个查询带 ctx 超时，DB 侧 `statement_timeout`（PG）/ `max_execution_time`（MySQL，仅 SELECT）兜底。

## 选型

| 库 | 适合 | 不适合 |
|---|---|---|
| `database/sql` + `pgx/v5/stdlib` | Postgres 通用场景；需要 COPY、批量、LISTEN 时直接用 `pgxpool` | MySQL |
| `lib/pq` | 只做维护的旧项目 | 新项目：维护模式，无 pgx 的性能与类型支持 |
| `go-sql-driver/mysql` | MySQL 唯一选择 | — |
| `sqlx` | 手写 SQL + struct 扫描，团队会写 SQL 也愿意审 SQL | 想在编译期发现列名/类型错误 |
| `sqlc` + `pgx` | SQL 先行、编译期类型安全、CI 校验 schema；Postgres 支持最完整 | 可选条件很多的动态查询（生成代码不擅长可变 WHERE） |
| GORM | CRUD 密集、需要 hooks/关联/软删除、快速迭代 | 复杂报表、性能热点、要 SQL 审查的团队（生成的 SQL 不在代码里） |
| `ent` | 关系图复杂、schema 即代码、要 codegen 校验 | 小项目：codegen 与学习成本不划算 |
| `bun` | 想要 SQL-first 的轻 ORM，Postgres 优先 | 依赖成熟插件生态（社区小于 GORM） |

## DSN 与连接池

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

## Repository 参考实现（sqlx）

一套完整实现：`sql.Null[T]`、每方法 ctx 超时、排序白名单、keyset 分页、`rows.Err()`、先判错再看 RowsAffected。占位符经 `db.Rebind` 转成方言（MySQL `?`、Postgres `$1`）；`IN (?)` 用 `sqlx.In` 展开后再 Rebind。

```go
// 参考实现按 MySQL 方言；Postgres 差异只有两处：Create 用 RETURNING id + QueryRowContext，占位符经 db.Rebind 变成 $1。
type User struct {
	ID        int64            `db:"id"`
	Email     string           `db:"email"`
	Name      string           `db:"name"`
	Phone     sql.Null[string] `db:"phone"` // 可空列用 sql.Null[T]（Go 1.22+），既不用指针也不用 NullString
	CreatedAt time.Time        `db:"created_at"`
}

// Page 是 keyset 游标：以 (created_at, id) 为单调键翻页。OFFSET n 要先扫掉前 n 行再丢弃，第 1000 页与第 1 页的扫描行数差三个量级。
// 首页：newest 传 AfterTime = 远未来哨兵（如 time.Now().Add(time.Hour)），oldest 传零值；零值配 newest 会得到空页。
type Page struct {
	AfterTime time.Time
	AfterID   int64
	Limit     int
	SortBy    string // 只接受 sortWhitelist 里的键
}

type UserRepo interface {
	Create(ctx context.Context, u *User) error
	GetByID(ctx context.Context, id int64) (*User, error)
	UpdateName(ctx context.Context, id int64, name string) error
	List(ctx context.Context, p Page) ([]User, error)
}

// 禁 SELECT *：列增删后 Scan 目标错位，轻则报错重则静默串列。
const userCols = "id, email, name, phone, created_at"

// 排序白名单：键是 API 暴露的名字，值是真实 ORDER BY 片段与 keyset 比较方向。
// 反例 fmt.Sprintf("ORDER BY %s", p.SortBy) 就是 SQL 注入，哪怕上游 DTO 做过 oneof 校验也不能省——repo 是公共层。
var sortWhitelist = map[string]struct{ order, cmp string }{
	"newest": {"created_at DESC, id DESC", "<"},
	"oldest": {"created_at ASC, id ASC", ">"},
}

func (r *sqlxUserRepo) UpdateName(ctx context.Context, id int64, name string) error {
	ctx, cancel := context.WithTimeout(ctx, r.timeout)
	defer cancel()
	q := r.db.Rebind("UPDATE users SET name = ? WHERE id = ? AND deleted_at IS NULL")
	res, err := r.db.ExecContext(ctx, q, name, id)
	if err != nil { // 先判 err：出错时 RowsAffected 也是 0，跳过这步会把死锁/网络错误伪装成"用户不存在"
		return fmt.Errorf("update user %d: %w", id, err)
	}
	n, err := res.RowsAffected()
	if err != nil {
		return fmt.Errorf("rows affected: %w", err)
	}
	if n == 0 {
		return ErrNotFound
	}
	return nil
}

func (r *sqlxUserRepo) List(ctx context.Context, p Page) ([]User, error) {
	s, ok := sortWhitelist[p.SortBy]
	if !ok {
		return nil, fmt.Errorf("invalid sort key %q", p.SortBy)
	}
	limit := min(max(p.Limit, 1), 200)
	ctx, cancel := context.WithTimeout(ctx, r.timeout)
	defer cancel()
	// 行值比较 (created_at, id) < (?, ?) 走 (created_at, id) 联合索引；若 EXPLAIN 不走索引，
	// 展开为 created_at < ? OR (created_at = ? AND id < ?)。
	q := r.db.Rebind("SELECT " + userCols + " FROM users WHERE deleted_at IS NULL AND (created_at, id) " +
		s.cmp + " (?, ?) ORDER BY " + s.order + " LIMIT ?")
	rows, err := r.db.QueryxContext(ctx, q, p.AfterTime, p.AfterID, limit)
	if err != nil {
		return nil, fmt.Errorf("list users: %w", err)
	}
	defer rows.Close()
	users := make([]User, 0, limit)
	for rows.Next() {
		var u User
		if err := rows.StructScan(&u); err != nil {
			return nil, fmt.Errorf("scan user: %w", err)
		}
		users = append(users, u)
	}
	if err := rows.Err(); err != nil { // 不查 rows.Err：网络中断/超时时静默返回被截断的结果集
		return nil, fmt.Errorf("iterate users: %w", err)
	}
	return users, nil
}
```

`Create`/`GetByID` 同样模式：`GetContext` 遇 `sql.ErrNoRows` 用 `errors.Is` 转成 `ErrNotFound`；MySQL 用 `LastInsertId()`，pgx/lib/pq 对它返回 error，Postgres 用 `RETURNING id`。`LIKE '%x%'` 前缀通配无法走 B-tree 索引，全表扫描；搜索需求走前缀 `LIKE 'x%'` 或全文索引/ES。

## GORM 专项陷阱

```go
	db, err := gorm.Open(mysql.Open(dsn), &gorm.Config{
		Logger:                 NewGormLogger(200 * time.Millisecond),
		TranslateError:         true,  // 唯一键冲突翻译成 gorm.ErrDuplicatedKey，业务层 errors.Is 判定，不解析驱动错误码
		SkipDefaultTransaction: true,  // 单条写不再自动包事务；多条写显式 db.Transaction
		PrepareStmt:            false, // pgbouncer transaction pooling / RDS Proxy 下 prepared statement 不跨连接；语句缓存按 SQL 文本键控（gorm v1.31.2 默认 TTL 24h、容量无上限）
	})
```

`NewGormLogger` 是 `gorm.io/gorm/logger.Interface` 的 gtkit 实现（默认级别 `Warn`，`Trace` 只在 `err != nil` 或 `elapsed > slow` 时才调用 `fc()` 取 SQL 文本），完整代码见 go-observability 慢查询章节。`logger.Default.LogMode(logger.Info)` 会把每条 SQL 连同参数值写进日志——同时是性能事故与 PII 泄露。

```go
type User struct {
	ID        int64
	Email     string `gorm:"size:255;not null"`
	Name      string `gorm:"size:100;not null"`
	Age       int
	DeletedAt gorm.DeletedAt `gorm:"index"` // 只有这个类型有软删除语义：Delete 变 UPDATE，查询自动追加 deleted_at IS NULL；sql.NullTime 没有
}

// 链式复用：Where 返回的 *gorm.DB 携带条件，Count 之后接着 Find 属于 GORM 文档标注的风险区。
// Session(&gorm.Session{}) 把当前链固化为可安全复用的起点。
func ListAndCount(ctx context.Context, db *gorm.DB, minAge, limit int) ([]User, int64, error) {
	base := db.WithContext(ctx).Model(&User{}).Where("age >= ?", minAge).Session(&gorm.Session{})
	var total int64
	if err := base.Count(&total).Error; err != nil { // Count 的 Error 不能丢
		return nil, 0, fmt.Errorf("count users: %w", err)
	}
	var users []User
	if err := base.Order("id").Limit(limit).Find(&users).Error; err != nil {
		return nil, 0, fmt.Errorf("list users: %w", err)
	}
	return users, total, nil
}

// Updates(struct) 跳过零值——Age: 0 不会写入；要写零值用 map 或 Select("age")。
// Save 是全字段 UPDATE（含零值），并发下会用旧快照覆盖别人刚写的字段；局部更新一律 Updates。
func ResetProfile(ctx context.Context, db *gorm.DB, id int64) error {
	res := db.WithContext(ctx).Model(&User{}).Where("id = ?", id).Updates(map[string]any{"age": 0, "name": ""})
	if res.Error != nil {
		return fmt.Errorf("reset profile %d: %w", id, res.Error)
	}
	if res.RowsAffected == 0 { // 只有 Error 为 nil 时 RowsAffected 才有意义
		return ErrNotFound
	}
	return nil
}
```

Upsert 用 `Clauses(clause.OnConflict{Columns: []clause.Column{{Name: "email"}}, DoUpdates: clause.AssignmentColumns([]string{"name", "age"})})` 只更新列出的列，配 `CreateInBatches(users, 500)` 分批，避免单条巨型 INSERT 撑爆 `max_allowed_packet`。事务用 `db.WithContext(ctx).Transaction(func(tx *gorm.DB) error {...})`：panic 回滚与嵌套 SavePoint 都已处理，手写 Begin/Commit 一旦漏掉 defer Rollback 就是连接泄漏；事务内的扣减写成 `Where("id = ? AND balance_cents >= ?", id, cents).Update("balance_cents", gorm.Expr("balance_cents - ?", cents))`，先判 `res.Error` 再用 `RowsAffected == 0` 表示余额不足。

`Preload("User")` 发 2 条 SQL（主查询 + `IN` 列表），`Joins("User")` 发 1 条 LEFT JOIN 但只适用 belongs_to/has_one——has_many 用 Joins 会让主表行数随子表膨胀，分页与 Count 全错。`First(&u, id)` 找不到返回 `gorm.ErrRecordNotFound`，`Find` 不返回；`Delete` 没带条件时报 `ErrMissingWhereClause`，这是保护不是 bug。

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

## 读写分离

```go
	err := db.Use(dbresolver.Register(dbresolver.Config{
		Replicas: replicas,
		Policy:   dbresolver.RandomPolicy{},
	}).SetMaxOpenConns(30).SetMaxIdleConns(15).SetConnMaxLifetime(30 * time.Minute))
```

写与事务自动走主库，普通读走从库。写后立即读必须 `db.Clauses(dbresolver.Write)` 显式回主库——复制延迟下从库还没有这行；更稳的策略是"该用户写后 N 秒内的读全部走主库"，用 ctx 或会话标记携带。复制延迟要监控 `Seconds_Behind_Source`（8.0.22 前叫 `Seconds_Behind_Master`）/ `pg_last_xact_replay_timestamp()`，超阈值自动摘除从库。

## ctx 超时传播

- ctx 取消时 `go-sql-driver/mysql` 关闭底层连接（`watchCancel` → `cleanup`），pgx 默认 `DeadlineContextWatcherHandler` 把 net.Conn deadline 置为当前时刻，连接同样报废。批量取消（客户端超时、上游熔断）会让池瞬间重建大量连接，MySQL 侧表现为 `Aborted_clients` 飙升。超时值要比 P99 有余量，不要贴着均值设。
- `tx.Commit()` 返回 `context.Canceled`/`DeadlineExceeded` 时 DB 可能已提交：取消发生在 COMMIT 报文发出后。这类错误不能当"未提交"处理，靠幂等键或对账兜底（见 go-data-consistency）。
- 写操作的 ctx 用 `context.WithoutCancel(reqCtx)` 加独立短超时：请求方断开不应让一半完成的写被打断。
- DB 侧兜底：Postgres `statement_timeout`（会话/连接参数），MySQL `max_execution_time`（毫秒，仅 SELECT）；两者是最后一道防线，不替代 ctx。

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

## 索引与执行计划

- 最左前缀：`(a, b, c)` 服务 `a`、`a,b`、`a,b,c`，跳过 `a` 直接查 `b` 不走索引；范围条件（`>`、`BETWEEN`、`LIKE 'x%'`）之后的列不再用于索引查找。
- 覆盖索引：查询列全在索引里时 `EXPLAIN` 的 `Extra` 出现 `Using index`，免回表；`SELECT *` 天然放弃覆盖。
- `EXPLAIN` 三看：`type` 为 `ALL` 是全表扫描、`index` 是全索引扫描（都是问题）；`rows` 与实际行数差一个量级说明统计信息过期，`ANALYZE TABLE`；`Extra` 里 `Using filesort`/`Using temporary` 说明排序/分组没被索引覆盖。
- 函数包裹索引列（`WHERE DATE(created_at) = ?`）、隐式类型转换（字符串列传数字）、`OR` 连接非索引列，三者都让索引失效。

## 数据库测试

```go
// sqlmock 只能断言"发出了什么 SQL、传了什么参数"，测不出 SQL 语义错误（写错列名照样绿）。
// 适合 service 层隔离 repo；repo 本身的 SQL 正确性用 testcontainers-go 起真实 MySQL/Postgres 跑。
func TestUpdateName_SQLMock(t *testing.T) {
	db, mock, err := sqlmock.New(sqlmock.QueryMatcherOption(sqlmock.QueryMatcherEqual))
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	mock.ExpectExec("UPDATE users SET name = ? WHERE id = ?").
		WithArgs("bob", int64(7)).WillReturnResult(sqlmock.NewResult(0, 1))
	if _, err := db.ExecContext(t.Context(), "UPDATE users SET name = ? WHERE id = ?", "bob", int64(7)); err != nil {
		t.Fatal(err)
	}
	if err := mock.ExpectationsWereMet(); err != nil {
		t.Error(err)
	}
}
```

真库隔离用"每个测试一个事务、结束回滚"：比 TRUNCATE 快、互不可见、可 `t.Parallel()`；被测代码内部自己开事务时改用独立 schema。testcontainers-go 起库与 `TestMain` 组织见 go-testing。

## 何时不该用

| 场景 | 选择 | 理由 |
|---|---|---|
| 复杂报表、多表聚合、窗口函数 | 手写 SQL（sqlx/sqlc） | ORM 生成的 SQL 难以审查与调优 |
| 生产 schema 变更 | 版本化迁移 | AutoMigrate 不可回滚、不删列、无版本记录 |
| 深分页（页码 > 100） | keyset 分页 | OFFSET 线性扫描 |
| 模糊搜索 `LIKE '%x%'` | 全文索引 / ES | 前缀通配无法走 B-tree |
| 高并发计数/库存 | 原子条件 UPDATE | 读改写三步有竞态（见 go-data-consistency） |
| 多个 `IN` 长度不同的查询 + PrepareStmt | 关掉 PrepareStmt 或固定 IN 长度 | 语句缓存按 SQL 文本膨胀 |

## 审查清单

- [ ] DSN 含 `parseTime=true&loc=UTC`（MySQL）；Postgres 走 pgx，没有 `lib/pq`
- [ ] 四个池参数显式设置，`副本数 × MaxOpen` 与 `max_connections` 核对过，`ConnMaxLifetime` 小于 DB/代理空闲超时
- [ ] `db.Stats()` 已导出（`NewDBStatsCollector`），`wait_count` 有告警
- [ ] 每个 `rows.Next()` 循环后有 `rows.Err()`
- [ ] 每处 `RowsAffected` 前面先判了 `err`/`result.Error`
- [ ] 没有 `fmt.Sprintf`/字符串拼接把外部输入放进 SQL 文本；排序/列名走白名单 map
- [ ] 没有 `SELECT *`；分页用 keyset，无 `COUNT(*)` 每页重算
- [ ] GORM：`DeletedAt` 是 `gorm.DeletedAt`；复用查询链前 `Session(&gorm.Session{})`；`Count` 检查了 Error；局部更新用 `Updates` 不用 `Save`；生产日志级别 `Warn` + `SlowThreshold`
- [ ] 事务用 `db.Transaction`/`BeginTx` + defer Rollback；事务体内无网络 IO
- [ ] 每个查询有 ctx 超时；DB 侧 `statement_timeout`/`max_execution_time` 已配置
- [ ] 建表：`DATETIME(6)`、`utf8mb4`、无冗余索引、软删除表的唯一键冲突有解法、金额非浮点
- [ ] 迁移在独立 Job 里跑；大表 DDL 用 gh-ost/pt-osc/`ALGORITHM=INSTANT`
- [ ] 读写分离：写后读显式回主库；复制延迟有监控
