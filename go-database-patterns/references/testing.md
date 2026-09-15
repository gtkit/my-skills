# 数据库测试

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
