---
name: go-testing
description: Go testing best practices including table-driven tests, mocks, benchmarks, integration tests, and test fixtures. Use this skill whenever the user mentions Go testing, writing tests in Go, test coverage, benchmarking Go code, mocking dependencies, testify usage, httptest, or any test-related development in Go. Also trigger when the user asks about TDD in Go, test organization, golden files, or test helper patterns.
---

# Go Testing Best Practices

Production patterns for testing Go applications including unit tests, integration tests, benchmarks, and mocking strategies.

## When to Use This Skill

- Writing unit and integration tests in Go
- Table-driven test patterns
- Mocking interfaces with testify or gomock
- HTTP handler testing with httptest
- Benchmark and performance testing
- Test fixtures and golden files
- Coverage analysis and improvement

## Core Patterns

### 1. Table-Driven Tests

```go
package calculator

import "testing"

func TestAdd(t *testing.T) {
    tests := []struct {
        name     string
        a, b     int
        expected int
    }{
        {"positive numbers", 2, 3, 5},
        {"negative numbers", -1, -2, -3},
        {"mixed", -1, 5, 4},
        {"zeros", 0, 0, 0},
        {"large numbers", 1000000, 2000000, 3000000},
    }

    for _, tt := range tests {
        t.Run(tt.name, func(t *testing.T) {
            result := Add(tt.a, tt.b)
            if result != tt.expected {
                t.Errorf("Add(%d, %d) = %d, want %d", tt.a, tt.b, result, tt.expected)
            }
        })
    }
}
```

### 2. Table-Driven Tests with Error Cases

```go
func TestParseConfig(t *testing.T) {
    tests := []struct {
        name    string
        input   string
        want    *Config
        wantErr bool
        errMsg  string
    }{
        {
            name:  "valid config",
            input: `{"host":"localhost","port":8080}`,
            want:  &Config{Host: "localhost", Port: 8080},
        },
        {
            name:    "invalid json",
            input:   `{invalid}`,
            wantErr: true,
            errMsg:  "invalid character",
        },
        {
            name:    "missing required field",
            input:   `{"host":"localhost"}`,
            wantErr: true,
            errMsg:  "port is required",
        },
        {
            name:  "empty input uses defaults",
            input: `{}`,
            want:  &Config{Host: "0.0.0.0", Port: 3000},
        },
    }

    for _, tt := range tests {
        t.Run(tt.name, func(t *testing.T) {
            got, err := ParseConfig([]byte(tt.input))

            if tt.wantErr {
                if err == nil {
                    t.Fatal("expected error, got nil")
                }
                if tt.errMsg != "" && !strings.Contains(err.Error(), tt.errMsg) {
                    t.Errorf("error = %q, want containing %q", err.Error(), tt.errMsg)
                }
                return
            }

            if err != nil {
                t.Fatalf("unexpected error: %v", err)
            }

            if !reflect.DeepEqual(got, tt.want) {
                t.Errorf("got %+v, want %+v", got, tt.want)
            }
        })
    }
}
```

### 3. Testify Assertions

```go
package service

import (
    "testing"
    "github.com/stretchr/testify/assert"
    "github.com/stretchr/testify/require"
)

func TestUserService_Create(t *testing.T) {
    svc := NewUserService(mockRepo)

    user, err := svc.Create(ctx, &CreateUserReq{
        Name:  "John",
        Email: "john@example.com",
    })

    // require stops test on failure (use for preconditions)
    require.NoError(t, err)
    require.NotNil(t, user)

    // assert continues test on failure (use for assertions)
    assert.Equal(t, "John", user.Name)
    assert.Equal(t, "john@example.com", user.Email)
    assert.NotZero(t, user.ID)
    assert.WithinDuration(t, time.Now(), user.CreatedAt, time.Second)
}
```

### 4. Mock with Testify Mock

```go
package service

import (
    "context"
    "testing"
    "github.com/stretchr/testify/mock"
    "github.com/stretchr/testify/assert"
)

// Mock definition
type MockUserRepo struct {
    mock.Mock
}

func (m *MockUserRepo) GetByID(ctx context.Context, id int64) (*model.User, error) {
    args := m.Called(ctx, id)
    if args.Get(0) == nil {
        return nil, args.Error(1)
    }
    return args.Get(0).(*model.User), args.Error(1)
}

func (m *MockUserRepo) Create(ctx context.Context, user *model.User) error {
    args := m.Called(ctx, user)
    return args.Error(0)
}

func (m *MockUserRepo) List(ctx context.Context, opts ListOptions) ([]*model.User, int64, error) {
    args := m.Called(ctx, opts)
    return args.Get(0).([]*model.User), args.Get(1).(int64), args.Error(2)
}

// Test using mock
func TestUserService_GetByID(t *testing.T) {
    mockRepo := new(MockUserRepo)
    svc := NewUserService(mockRepo)
    ctx := context.Background()

    t.Run("user found", func(t *testing.T) {
        expected := &model.User{ID: 1, Name: "John", Email: "john@test.com"}
        mockRepo.On("GetByID", ctx, int64(1)).Return(expected, nil).Once()

        user, err := svc.GetByID(ctx, 1)

        assert.NoError(t, err)
        assert.Equal(t, expected, user)
        mockRepo.AssertExpectations(t)
    })

    t.Run("user not found", func(t *testing.T) {
        mockRepo.On("GetByID", ctx, int64(999)).Return(nil, apperror.ErrNotFound).Once()

        user, err := svc.GetByID(ctx, 999)

        assert.ErrorIs(t, err, apperror.ErrNotFound)
        assert.Nil(t, user)
        mockRepo.AssertExpectations(t)
    })
}
```

### 5. HTTP Handler Testing

```go
package handler

import (
    "bytes"
    "encoding/json"
    "net/http"
    "net/http/httptest"
    "testing"

    "github.com/gin-gonic/gin"
    "github.com/stretchr/testify/assert"
    "github.com/stretchr/testify/require"
)

func setupRouter(h *UserHandler) *gin.Engine {
    gin.SetMode(gin.TestMode)
    r := gin.New()
    r.GET("/users/:id", h.GetByID)
    r.POST("/users", h.Create)
    r.GET("/users", h.List)
    return r
}

func TestUserHandler_Create(t *testing.T) {
    mockSvc := new(MockUserService)
    h := NewUserHandler(mockSvc)
    router := setupRouter(h)

    t.Run("success", func(t *testing.T) {
        reqBody := dto.CreateUserReq{
            Name:     "John",
            Email:    "john@test.com",
            Password: "password123",
            Role:     "user",
        }
        body, _ := json.Marshal(reqBody)

        mockSvc.On("Create", mock.Anything, &reqBody).
            Return(&model.User{ID: 1, Name: "John", Email: "john@test.com"}, nil).Once()

        w := httptest.NewRecorder()
        req := httptest.NewRequest("POST", "/users", bytes.NewReader(body))
        req.Header.Set("Content-Type", "application/json")
        router.ServeHTTP(w, req)

        assert.Equal(t, http.StatusCreated, w.Code)

        var resp response.Response
        err := json.Unmarshal(w.Body.Bytes(), &resp)
        require.NoError(t, err)
        assert.Equal(t, 0, resp.Code)
    })

    t.Run("validation error", func(t *testing.T) {
        body := `{"name":"","email":"invalid"}`
        w := httptest.NewRecorder()
        req := httptest.NewRequest("POST", "/users", bytes.NewReader([]byte(body)))
        req.Header.Set("Content-Type", "application/json")
        router.ServeHTTP(w, req)

        assert.Equal(t, http.StatusBadRequest, w.Code)
    })
}

// Helper for authenticated requests
func authenticatedRequest(method, path string, body []byte, token string) *http.Request {
    req := httptest.NewRequest(method, path, bytes.NewReader(body))
    req.Header.Set("Content-Type", "application/json")
    req.Header.Set("Authorization", "Bearer "+token)
    return req
}
```

### 6. Test Fixtures & Helpers

```go
package testutil

import (
    "database/sql"
    "os"
    "path/filepath"
    "testing"
    "time"
)

// Test helper for creating test users
func NewTestUser(t *testing.T, overrides ...func(*model.User)) *model.User {
    t.Helper()
    user := &model.User{
        Name:      "Test User",
        Email:     fmt.Sprintf("test-%d@example.com", time.Now().UnixNano()),
        Password:  "hashed_password",
        Role:      "user",
        CreatedAt: time.Now(),
    }
    for _, fn := range overrides {
        fn(user)
    }
    return user
}

// Golden file testing
func Golden(t *testing.T, name string, actual []byte) {
    t.Helper()
    golden := filepath.Join("testdata", name+".golden")

    if os.Getenv("UPDATE_GOLDEN") != "" {
        os.MkdirAll(filepath.Dir(golden), 0755)
        os.WriteFile(golden, actual, 0644)
        return
    }

    expected, err := os.ReadFile(golden)
    if err != nil {
        t.Fatalf("failed to read golden file: %v", err)
    }

    if !bytes.Equal(actual, expected) {
        t.Errorf("output does not match golden file.\nGot:\n%s\nWant:\n%s\nRun with UPDATE_GOLDEN=1 to update.",
            actual, expected)
    }
}

// Test database setup
func SetupTestDB(t *testing.T) *sql.DB {
    t.Helper()
    dsn := os.Getenv("TEST_DATABASE_URL")
    if dsn == "" {
        t.Skip("TEST_DATABASE_URL not set")
    }

    db, err := sql.Open("postgres", dsn)
    if err != nil {
        t.Fatalf("connecting to test db: %v", err)
    }

    t.Cleanup(func() {
        // Clean up test data
        db.Exec("DELETE FROM users WHERE email LIKE 'test-%'")
        db.Close()
    })

    return db
}

// Temporary directory helper
func TempDir(t *testing.T) string {
    t.Helper()
    dir := t.TempDir() // Auto-cleaned up
    return dir
}
```

### 7. Integration Tests

```go
//go:build integration

package integration

import (
    "context"
    "testing"
    "yourapp/internal/repository"
    "yourapp/internal/testutil"
)

func TestUserRepository_Integration(t *testing.T) {
    db := testutil.SetupTestDB(t)
    repo := repository.NewSqlxUserRepo(db)
    ctx := context.Background()

    t.Run("CRUD lifecycle", func(t *testing.T) {
        // Create
        user := testutil.NewTestUser(t)
        err := repo.Create(ctx, user)
        require.NoError(t, err)
        assert.NotZero(t, user.ID)

        // Read
        found, err := repo.GetByID(ctx, user.ID)
        require.NoError(t, err)
        assert.Equal(t, user.Name, found.Name)

        // Update
        user.Name = "Updated Name"
        err = repo.Update(ctx, user)
        require.NoError(t, err)

        found, _ = repo.GetByID(ctx, user.ID)
        assert.Equal(t, "Updated Name", found.Name)

        // Delete
        err = repo.Delete(ctx, user.ID)
        require.NoError(t, err)

        _, err = repo.GetByID(ctx, user.ID)
        assert.ErrorIs(t, err, apperror.ErrNotFound)
    })
}
```

### 8. Benchmarks

```go
package parser

import "testing"

func BenchmarkParseJSON(b *testing.B) {
    data := []byte(`{"name":"John","age":30,"email":"john@test.com"}`)

    b.ResetTimer()
    for i := 0; i < b.N; i++ {
        ParseJSON(data)
    }
}

func BenchmarkParseJSON_Large(b *testing.B) {
    data := generateLargeJSON(1000)

    b.ResetTimer()
    b.ReportAllocs()
    for i := 0; i < b.N; i++ {
        ParseJSON(data)
    }
}

// Sub-benchmarks for comparison
func BenchmarkParse(b *testing.B) {
    sizes := []struct {
        name string
        size int
    }{
        {"Small", 10},
        {"Medium", 100},
        {"Large", 1000},
        {"XLarge", 10000},
    }

    for _, s := range sizes {
        data := generateLargeJSON(s.size)
        b.Run(s.name, func(b *testing.B) {
            b.ReportAllocs()
            for i := 0; i < b.N; i++ {
                ParseJSON(data)
            }
        })
    }
}

// Parallel benchmark
func BenchmarkConcurrentAccess(b *testing.B) {
    cache := NewCache()
    // Pre-populate
    for i := 0; i < 1000; i++ {
        cache.Set(fmt.Sprintf("key-%d", i), i)
    }

    b.RunParallel(func(pb *testing.PB) {
        i := 0
        for pb.Next() {
            cache.Get(fmt.Sprintf("key-%d", i%1000))
            i++
        }
    })
}
```

### 9. Test Main & Shared Setup

```go
package mypackage

import (
    "os"
    "testing"
)

var testDB *sql.DB

func TestMain(m *testing.M) {
    // Setup
    var err error
    testDB, err = setupTestDatabase()
    if err != nil {
        log.Fatalf("setting up test db: %v", err)
    }

    // Run tests
    code := m.Run()

    // Teardown
    testDB.Close()

    os.Exit(code)
}
```

### 10. Testing with Context and Timeouts

```go
func TestSlowOperation(t *testing.T) {
    ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
    defer cancel()

    result, err := SlowOperation(ctx)
    require.NoError(t, err)
    assert.NotEmpty(t, result)
}

func TestOperationCancellation(t *testing.T) {
    ctx, cancel := context.WithCancel(context.Background())
    cancel() // Cancel immediately

    _, err := SlowOperation(ctx)
    assert.ErrorIs(t, err, context.Canceled)
}
```

## Running Tests

```bash
# Run all tests
go test ./...

# Run with verbose output
go test -v ./...

# Run specific test
go test -run TestUserService_Create ./internal/service/

# Run with coverage
go test -cover ./...
go test -coverprofile=coverage.out ./...
go tool cover -html=coverage.out

# Run benchmarks
go test -bench=. -benchmem ./...
go test -bench=BenchmarkParse -count=5 ./...

# Run integration tests
go test -tags=integration ./...

# Run with race detector
go test -race ./...

# Update golden files
UPDATE_GOLDEN=1 go test ./...

# Run with timeout
go test -timeout 30s ./...
```

## Best Practices

### Do's
- **Use `t.Helper()`** in test helpers for better error reporting
- **Use `t.Parallel()`** for independent tests to speed up test suite
- **Use `require` for preconditions**, `assert` for verification
- **Use build tags** (`//go:build integration`) to separate test types
- **Use `t.Cleanup()`** instead of manual defer for resource cleanup
- **Name tests descriptively** with the pattern `TestFunc_Scenario`

### Don'ts
- **Don't test private functions** directly — test through public API
- **Don't share state** between parallel tests
- **Don't use `time.Sleep`** for synchronization — use channels or conditions
- **Don't ignore `_test.go` coverage** — strive for meaningful tests, not 100%
- **Don't mock everything** — use real implementations when practical
