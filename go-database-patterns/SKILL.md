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

## 按任务读取

以下内容按任务读取，只读本次需要的文件；核心规则与审查清单已覆盖其结论。

| 任务 | 读 |
|---|---|
| 配 DSN 参数与连接池、监控 db.Stats | `references/pool.md` |
| 写 Repository：查询正确性、rows.Err、列名白名单、keyset 分页 | `references/repository.md` |
| 用 GORM，或排查 Session 复用、Updates 零值、Preload 等陷阱 | `references/gorm.md` |
| 写迁移、做大表变更、定建表规范 | `references/migration.md` |
| 用 sqlmock 或 testcontainers 测数据访问层 | `references/testing.md` |

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

## 索引与执行计划

- 最左前缀：`(a, b, c)` 服务 `a`、`a,b`、`a,b,c`，跳过 `a` 直接查 `b` 不走索引；范围条件（`>`、`BETWEEN`、`LIKE 'x%'`）之后的列不再用于索引查找。
- 覆盖索引：查询列全在索引里时 `EXPLAIN` 的 `Extra` 出现 `Using index`，免回表；`SELECT *` 天然放弃覆盖。
- `EXPLAIN` 三看：`type` 为 `ALL` 是全表扫描、`index` 是全索引扫描（都是问题）；`rows` 与实际行数差一个量级说明统计信息过期，`ANALYZE TABLE`；`Extra` 里 `Using filesort`/`Using temporary` 说明排序/分组没被索引覆盖。
- 函数包裹索引列（`WHERE DATE(created_at) = ?`）、隐式类型转换（字符串列传数字）、`OR` 连接非索引列，三者都让索引失效。

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
