# GORM 专项陷阱

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
