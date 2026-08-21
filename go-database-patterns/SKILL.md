---
name: go-database-patterns
description: Go database development patterns including GORM, sqlx, go-jet, go-sqlbuilder, migrations, connection pooling, and transactions. Use this skill whenever the user mentions Go database operations, SQL queries in Go, ORM usage, database migrations, query builders, connection pool tuning, transaction management, or any data access layer design in Go. Also trigger for repository pattern implementation, database testing, and schema management.
---

# Go Database Patterns

Production patterns for database operations in Go, covering ORMs, query builders, raw SQL, migrations, and connection management.

## When to Use This Skill

- Database operations with GORM, sqlx, or query builders
- Choosing between go-jet, go-sqlbuilder, GORM, and sqlx
- Connection pool configuration and tuning
- Transaction management patterns
- Database migration strategies
- Repository pattern implementation
- Database testing with mocks and fixtures

## Library Comparison

| Feature | GORM | sqlx | go-jet | go-sqlbuilder |
|---------|------|------|--------|---------------|
| Type Safety | Medium | Low | High | Medium |
| Performance | Good | Excellent | Excellent | Excellent |
| Learning Curve | Low | Medium | Medium | Low |
| Code Gen | No | No | Yes | No |
| Raw SQL | Supported | Native | Generated | Builder |
| Migrations | Built-in | No | No | No |
| Best For | Rapid dev | Full control | Type-safe queries | Flexible building |

## Core Patterns

### 1. Database Connection & Pool

```go
package database

import (
    "context"
    "database/sql"
    "fmt"
    "time"

    _ "github.com/go-sql-driver/mysql"
    _ "github.com/lib/pq"
)

type Config struct {
    Driver          string
    DSN             string
    MaxOpenConns    int
    MaxIdleConns    int
    ConnMaxLifetime time.Duration
    ConnMaxIdleTime time.Duration
}

func DefaultConfig() Config {
    return Config{
        MaxOpenConns:    25,
        MaxIdleConns:    10,
        ConnMaxLifetime: 5 * time.Minute,
        ConnMaxIdleTime: 1 * time.Minute,
    }
}

func NewDB(cfg Config) (*sql.DB, error) {
    db, err := sql.Open(cfg.Driver, cfg.DSN)
    if err != nil {
        return nil, fmt.Errorf("opening database: %w", err)
    }

    db.SetMaxOpenConns(cfg.MaxOpenConns)
    db.SetMaxIdleConns(cfg.MaxIdleConns)
    db.SetConnMaxLifetime(cfg.ConnMaxLifetime)
    db.SetConnMaxIdleTime(cfg.ConnMaxIdleTime)

    ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
    defer cancel()

    if err := db.PingContext(ctx); err != nil {
        return nil, fmt.Errorf("pinging database: %w", err)
    }

    return db, nil
}

// GORM setup
func NewGormDB(cfg Config) (*gorm.DB, error) {
    var dialector gorm.Dialector
    switch cfg.Driver {
    case "mysql":
        dialector = mysql.Open(cfg.DSN)
    case "postgres":
        dialector = postgres.Open(cfg.DSN)
    }

    db, err := gorm.Open(dialector, &gorm.Config{
        Logger:                 logger.Default.LogMode(logger.Info),
        SkipDefaultTransaction: true,  // Better performance
        PrepareStmt:            true,  // Cache prepared statements
    })
    if err != nil {
        return nil, err
    }

    sqlDB, _ := db.DB()
    sqlDB.SetMaxOpenConns(cfg.MaxOpenConns)
    sqlDB.SetMaxIdleConns(cfg.MaxIdleConns)
    sqlDB.SetConnMaxLifetime(cfg.ConnMaxLifetime)

    return db, nil
}
```

### 2. Repository Pattern

```go
package repository

import (
    "context"
    "database/sql"
    "errors"
    "fmt"
    "yourapp/internal/model"
    "yourapp/pkg/apperror"
)

type UserRepository interface {
    Create(ctx context.Context, user *model.User) error
    GetByID(ctx context.Context, id int64) (*model.User, error)
    Update(ctx context.Context, user *model.User) error
    Delete(ctx context.Context, id int64) error
    List(ctx context.Context, opts ListOptions) ([]*model.User, int64, error)
}

type ListOptions struct {
    Page    int
    PerPage int
    Sort    string
    Order   string
    Search  string
    Filters map[string]interface{}
}

// --- sqlx implementation ---

type sqlxUserRepo struct {
    db *sqlx.DB
}

func NewSqlxUserRepo(db *sqlx.DB) UserRepository {
    return &sqlxUserRepo{db: db}
}

func (r *sqlxUserRepo) GetByID(ctx context.Context, id int64) (*model.User, error) {
    var user model.User
    err := r.db.GetContext(ctx, &user, "SELECT * FROM users WHERE id = ? AND deleted_at IS NULL", id)
    if errors.Is(err, sql.ErrNoRows) {
        return nil, apperror.ErrNotFound
    }
    if err != nil {
        return nil, fmt.Errorf("get user by id: %w", err)
    }
    return &user, nil
}

func (r *sqlxUserRepo) List(ctx context.Context, opts ListOptions) ([]*model.User, int64, error) {
    var total int64
    countQuery := "SELECT COUNT(*) FROM users WHERE deleted_at IS NULL"
    args := []interface{}{}

    if opts.Search != "" {
        countQuery += " AND (name LIKE ? OR email LIKE ?)"
        searchTerm := "%" + opts.Search + "%"
        args = append(args, searchTerm, searchTerm)
    }

    err := r.db.GetContext(ctx, &total, countQuery, args...)
    if err != nil {
        return nil, 0, fmt.Errorf("count users: %w", err)
    }

    query := "SELECT * FROM users WHERE deleted_at IS NULL"
    if opts.Search != "" {
        query += " AND (name LIKE ? OR email LIKE ?)"
    }
    query += fmt.Sprintf(" ORDER BY %s %s LIMIT ? OFFSET ?", opts.Sort, opts.Order)
    args = append(args, opts.PerPage, (opts.Page-1)*opts.PerPage)

    var users []*model.User
    err = r.db.SelectContext(ctx, &users, query, args...)
    if err != nil {
        return nil, 0, fmt.Errorf("list users: %w", err)
    }

    return users, total, nil
}

// --- GORM implementation ---

type gormUserRepo struct {
    db *gorm.DB
}

func NewGormUserRepo(db *gorm.DB) UserRepository {
    return &gormUserRepo{db: db}
}

func (r *gormUserRepo) GetByID(ctx context.Context, id int64) (*model.User, error) {
    var user model.User
    result := r.db.WithContext(ctx).First(&user, id)
    if errors.Is(result.Error, gorm.ErrRecordNotFound) {
        return nil, apperror.ErrNotFound
    }
    return &user, result.Error
}

func (r *gormUserRepo) List(ctx context.Context, opts ListOptions) ([]*model.User, int64, error) {
    var users []*model.User
    var total int64

    query := r.db.WithContext(ctx).Model(&model.User{})

    if opts.Search != "" {
        query = query.Where("name LIKE ? OR email LIKE ?",
            "%"+opts.Search+"%", "%"+opts.Search+"%")
    }

    for key, val := range opts.Filters {
        query = query.Where(key+" = ?", val)
    }

    query.Count(&total)
    err := query.
        Order(fmt.Sprintf("%s %s", opts.Sort, opts.Order)).
        Offset((opts.Page - 1) * opts.PerPage).
        Limit(opts.PerPage).
        Find(&users).Error

    return users, total, err
}
```

### 3. Transaction Management

```go
package database

import (
    "context"
    "database/sql"
    "fmt"
)

// Generic transaction helper for database/sql
func WithTx(ctx context.Context, db *sql.DB, fn func(tx *sql.Tx) error) error {
    tx, err := db.BeginTx(ctx, nil)
    if err != nil {
        return fmt.Errorf("begin tx: %w", err)
    }

    defer func() {
        if p := recover(); p != nil {
            tx.Rollback()
            panic(p)
        }
    }()

    if err := fn(tx); err != nil {
        if rbErr := tx.Rollback(); rbErr != nil {
            return fmt.Errorf("tx error: %w, rollback error: %v", err, rbErr)
        }
        return err
    }

    return tx.Commit()
}

// GORM transaction helper
func WithGormTx(ctx context.Context, db *gorm.DB, fn func(tx *gorm.DB) error) error {
    tx := db.WithContext(ctx).Begin()
    if tx.Error != nil {
        return tx.Error
    }

    defer func() {
        if p := recover(); p != nil {
            tx.Rollback()
            panic(p)
        }
    }()

    if err := fn(tx); err != nil {
        tx.Rollback()
        return err
    }

    return tx.Commit().Error
}

// Nested transaction support (savepoints)
type TxManager struct {
    db *gorm.DB
}

func (m *TxManager) RunInTx(ctx context.Context, fn func(tx *gorm.DB) error) error {
    return m.db.WithContext(ctx).Transaction(fn) // GORM handles savepoints automatically
}

// Usage example
func (s *OrderService) CreateOrder(ctx context.Context, req *CreateOrderReq) error {
    return WithGormTx(ctx, s.db, func(tx *gorm.DB) error {
        // Create order
        order := &model.Order{UserID: req.UserID, Status: "pending"}
        if err := tx.Create(order).Error; err != nil {
            return err
        }

        // Create order items and update inventory
        for _, item := range req.Items {
            orderItem := &model.OrderItem{
                OrderID:   order.ID,
                ProductID: item.ProductID,
                Quantity:  item.Quantity,
            }
            if err := tx.Create(orderItem).Error; err != nil {
                return err
            }

            // Decrement inventory
            result := tx.Model(&model.Product{}).
                Where("id = ? AND stock >= ?", item.ProductID, item.Quantity).
                Update("stock", gorm.Expr("stock - ?", item.Quantity))
            if result.RowsAffected == 0 {
                return fmt.Errorf("insufficient stock for product %d", item.ProductID)
            }
        }

        return nil
    })
}
```

### 4. go-sqlbuilder Patterns

```go
package repository

import (
    "context"
    "database/sql"
    "github.com/huandu/go-sqlbuilder"
)

var userStruct = sqlbuilder.NewStruct(new(model.User))

func (r *repo) ListUsers(ctx context.Context, opts ListOptions) ([]*model.User, error) {
    sb := userStruct.SelectFrom("users")
    sb.Where(sb.IsNull("deleted_at"))

    if opts.Search != "" {
        sb.Where(sb.Or(
            sb.Like("name", "%"+opts.Search+"%"),
            sb.Like("email", "%"+opts.Search+"%"),
        ))
    }

    for key, val := range opts.Filters {
        sb.Where(sb.Equal(key, val))
    }

    sb.OrderBy(opts.Sort)
    if opts.Order == "desc" {
        sb.Desc()
    }
    sb.Limit(opts.PerPage).Offset((opts.Page - 1) * opts.PerPage)

    query, args := sb.Build()
    rows, err := r.db.QueryContext(ctx, query, args...)
    if err != nil {
        return nil, err
    }
    defer rows.Close()

    var users []*model.User
    for rows.Next() {
        var u model.User
        if err := rows.Scan(userStruct.Addr(&u)...); err != nil {
            return nil, err
        }
        users = append(users, &u)
    }
    return users, nil
}

// Insert with go-sqlbuilder
func (r *repo) CreateUser(ctx context.Context, user *model.User) error {
    ib := userStruct.InsertInto("users", user)
    query, args := ib.Build()
    result, err := r.db.ExecContext(ctx, query, args...)
    if err != nil {
        return err
    }
    id, _ := result.LastInsertId()
    user.ID = id
    return nil
}

// Conditional update
func (r *repo) UpdateUser(ctx context.Context, id int64, updates map[string]interface{}) error {
    ub := sqlbuilder.Update("users")
    for key, val := range updates {
        ub.Set(ub.Assign(key, val))
    }
    ub.Where(ub.Equal("id", id))

    query, args := ub.Build()
    _, err := r.db.ExecContext(ctx, query, args...)
    return err
}
```

### 5. Database Migrations (golang-migrate)

```go
// cmd/migrate/main.go
package main

import (
    "flag"
    "fmt"
    "log"
    "os"

    "github.com/golang-migrate/migrate/v4"
    _ "github.com/golang-migrate/migrate/v4/database/mysql"
    _ "github.com/golang-migrate/migrate/v4/database/postgres"
    _ "github.com/golang-migrate/migrate/v4/source/file"
)

func main() {
    var (
        dir     = flag.String("dir", "migrations", "migrations directory")
        dsn     = flag.String("dsn", "", "database DSN")
        command = flag.String("cmd", "up", "migrate command: up, down, steps, version, force")
        steps   = flag.Int("steps", 1, "number of steps for 'steps' command")
        version = flag.Int("version", 0, "version for 'force' command")
    )
    flag.Parse()

    m, err := migrate.New("file://"+*dir, *dsn)
    if err != nil {
        log.Fatal(err)
    }
    defer m.Close()

    switch *command {
    case "up":
        err = m.Up()
    case "down":
        err = m.Down()
    case "steps":
        err = m.Steps(*steps)
    case "version":
        v, dirty, verr := m.Version()
        if verr != nil {
            log.Fatal(verr)
        }
        fmt.Printf("Version: %d, Dirty: %v\n", v, dirty)
        return
    case "force":
        err = m.Force(*version)
    case "create":
        // Create new migration files
        name := flag.Arg(0)
        if name == "" {
            log.Fatal("migration name required")
        }
        createMigration(*dir, name)
        return
    }

    if err != nil && err != migrate.ErrNoChange {
        log.Fatal(err)
    }
    fmt.Println("Migration completed successfully")
}
```

```sql
-- migrations/000001_create_users.up.sql
CREATE TABLE users (
    id         BIGINT AUTO_INCREMENT PRIMARY KEY,
    name       VARCHAR(100) NOT NULL,
    email      VARCHAR(255) NOT NULL UNIQUE,
    password   VARCHAR(255) NOT NULL,
    role       VARCHAR(20)  NOT NULL DEFAULT 'user',
    created_at TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    deleted_at TIMESTAMP    NULL,
    INDEX idx_email (email),
    INDEX idx_deleted_at (deleted_at)
);

-- migrations/000001_create_users.down.sql
DROP TABLE IF EXISTS users;
```

### 6. Model Definition

```go
package model

import (
    "database/sql"
    "time"
)

type User struct {
    ID        int64        `db:"id" gorm:"primaryKey" json:"id"`
    Name      string       `db:"name" gorm:"size:100;not null" json:"name"`
    Email     string       `db:"email" gorm:"size:255;uniqueIndex;not null" json:"email"`
    Password  string       `db:"password" gorm:"size:255;not null" json:"-"`
    Role      string       `db:"role" gorm:"size:20;default:user" json:"role"`
    CreatedAt time.Time    `db:"created_at" gorm:"autoCreateTime" json:"created_at"`
    UpdatedAt time.Time    `db:"updated_at" gorm:"autoUpdateTime" json:"updated_at"`
    DeletedAt sql.NullTime `db:"deleted_at" gorm:"index" json:"-"`
}

func (User) TableName() string { return "users" }

// Soft delete scope for sqlx
const UserActiveScope = " AND deleted_at IS NULL"
```

### 7. Connection Health Check

```go
package database

import (
    "context"
    "database/sql"
    "time"
)

type HealthChecker struct {
    db       *sql.DB
    interval time.Duration
}

func NewHealthChecker(db *sql.DB, interval time.Duration) *HealthChecker {
    return &HealthChecker{db: db, interval: interval}
}

func (h *HealthChecker) Check(ctx context.Context) error {
    ctx, cancel := context.WithTimeout(ctx, 3*time.Second)
    defer cancel()
    return h.db.PingContext(ctx)
}

func (h *HealthChecker) Stats() sql.DBStats {
    return h.db.Stats()
}
```

## Pool Tuning Guidelines

| Workload | MaxOpen | MaxIdle | MaxLifetime | MaxIdleTime |
|----------|---------|---------|-------------|-------------|
| Low traffic API | 10 | 5 | 10m | 5m |
| Medium API | 25 | 10 | 5m | 1m |
| High traffic API | 50-100 | 25 | 5m | 30s |
| Background jobs | 5-10 | 2 | 30m | 10m |
| Mixed workload | 30 | 15 | 5m | 1m |

## Best Practices

### Do's
- **Use context** in all database operations for timeout/cancellation
- **Use transactions** for multi-step writes
- **Use prepared statements** for repeated queries
- **Monitor pool stats** with `db.Stats()`
- **Use soft deletes** for important data
- **Index your WHERE clauses** and JOIN columns

### Don'ts
- **Don't use ORM for complex reporting** — write raw SQL
- **Don't ignore `sql.ErrNoRows`** — handle it explicitly
- **Don't hold transactions open** for long periods
- **Don't use `SELECT *`** in production — specify columns
- **Don't skip connection pool tuning** — defaults are rarely optimal
