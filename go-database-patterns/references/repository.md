# Repository 参考实现（sqlx）

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
