# 集成测试隔离：testcontainers + 每测试事务回滚

```go
var pool *pgxpool.Pool

// 一个包一个容器（TestMain 起），一个测试一个事务（结束回滚）：用例之间零残留、可并行。
// Docker 不可用时 postgres.Run 直接报错 -> 测试失败，而不是 t.Skip 造成 CI 假绿。
func TestMain(m *testing.M) {
	ctx := context.Background()
	ctr, err := postgres.Run(ctx, "postgres:16-alpine",
		postgres.WithDatabase("app"), postgres.WithUsername("app"), postgres.WithPassword("secret"),
		postgres.BasicWaitStrategies())
	if err != nil {
		logger.Fatal("start postgres container", zap.Error(err))
	}
	dsn, err := ctr.ConnectionString(ctx, "sslmode=disable")
	if err != nil {
		logger.Fatal("connection string", zap.Error(err))
	}
	if pool, err = pgxpool.New(ctx, dsn); err != nil {
		logger.Fatal("open pool", zap.Error(err))
	}
	code := m.Run()
	pool.Close()
	logger.LogIf(testcontainers.TerminateContainer(ctr))
	os.Exit(code)
}

// txForTest 返回测试专用事务；t.Context() 在 Cleanup 前已被取消，回滚要用 WithoutCancel。
func txForTest(t *testing.T) pgx.Tx {
	t.Helper()
	tx, err := pool.Begin(t.Context())
	require.NoError(t, err)
	t.Cleanup(func() { _ = tx.Rollback(context.WithoutCancel(t.Context())) })
	return tx
}
```

`TestMain` 没有 `t`，是唯一允许 `context.Background()` 的地方。运行：`go test -tags integration -race ./integration/`。事务回滚测不到跨事务可见性与 `COMMIT` 触发的延迟约束/触发器，这类用例改用每测试独立 schema（`CREATE SCHEMA t_<name>` + `search_path`）。

| 方案 | 选择场景 | 代价 |
|---|---|---|
| testcontainers-go 模块（postgres/mysql/redis） | 主流；`Run` 内置就绪等待，`ConnectionString` 直接给 DSN | 依赖 Docker；首次拉镜像慢，CI 要缓存镜像层 |
| ory/dockertest | 已有存量、不想引入 testcontainers 的重依赖 | 就绪等待要自己写 retry；API 偏底层 |
| 共享外部库 + `TEST_DATABASE_URL` | 团队有常驻测试库、无 Docker 的环境 | 必须每测试独立 schema，否则并行互相污染 |
