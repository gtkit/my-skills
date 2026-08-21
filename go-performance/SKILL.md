---
name: go-performance
description: Go performance optimization patterns. Covers pprof profiling, memory escape analysis, GC tuning, benchmark writing, allocation reduction, and hot path optimization.
allowed-tools: "Read, Write, Edit, Bash, Glob, Grep"
---

# Go Performance Optimization

## Profiling with pprof

### CPU Profiling
```go
import _ "net/http/pprof"

// In main() or init()
go func() {
    log.Println(http.ListenAndServe("localhost:6060", nil))
}()
```

```bash
# Collect 30s CPU profile
go tool pprof http://localhost:6060/debug/pprof/profile?seconds=30

# Top consumers
(pprof) top 20
# Call graph
(pprof) web
# Source annotation
(pprof) list FunctionName
```

### Memory Profiling
```bash
go tool pprof http://localhost:6060/debug/pprof/heap
# Show allocations
(pprof) top -cum
# Inuse vs alloc
go tool pprof -alloc_space http://localhost:6060/debug/pprof/heap
```

### Goroutine Profiling
```bash
go tool pprof http://localhost:6060/debug/pprof/goroutine
# Identify goroutine leaks by checking goroutine count over time
```

## Escape Analysis

```bash
go build -gcflags="-m -m" ./path/to/package 2>&1 | grep "escapes to heap"
```

### Common Escape Causes
- Returning pointer to local variable
- Interface conversion (value -> interface{})
- Slice/map growing beyond initial capacity
- Closures capturing local variables
- fmt.Sprintf and similar varargs functions

### Reducing Escapes
```go
// BAD: escapes to heap
func newUser(name string) *User {
    u := User{Name: name} // allocated on heap because pointer returned
    return &u
}

// GOOD: caller controls allocation
func initUser(u *User, name string) {
    u.Name = name
}

// BAD: interface causes escape
func log(v interface{}) { ... }
log(myInt) // myInt escapes

// GOOD: typed function avoids escape
func logInt(v int) { ... }
```

## Allocation Reduction

### Preallocate Slices
```go
// BAD: grows multiple times
var results []Item
for _, v := range input {
    results = append(results, transform(v))
}

// GOOD: preallocate
results := make([]Item, 0, len(input))
for _, v := range input {
    results = append(results, transform(v))
}
```

### strings.Builder for Concatenation
```go
// BAD: O(n^2) allocation
s := ""
for _, v := range items {
    s += v.String()
}

// GOOD: O(n) single allocation
var b strings.Builder
b.Grow(estimatedSize)
for _, v := range items {
    b.WriteString(v.String())
}
result := b.String()
```

### Reuse Buffers with sync.Pool
```go
var jsonBufPool = sync.Pool{
    New: func() any {
        return bytes.NewBuffer(make([]byte, 0, 4096))
    },
}

func encodeJSON(v any) ([]byte, error) {
    buf := jsonBufPool.Get().(*bytes.Buffer)
    defer func() {
        buf.Reset()
        jsonBufPool.Put(buf)
    }()
    if err := json.NewEncoder(buf).Encode(v); err != nil {
        return nil, err
    }
    return bytes.Clone(buf.Bytes()), nil
}
```

### Avoid Unnecessary Copies
```go
// BAD: copies entire struct on each iteration
for _, item := range largeStructSlice {
    process(item)
}

// GOOD: use index to avoid copy
for i := range largeStructSlice {
    process(&largeStructSlice[i])
}
```

## Benchmark Writing

```go
func BenchmarkProcess(b *testing.B) {
    input := setupTestData()
    b.ResetTimer()
    b.ReportAllocs()

    for i := 0; i < b.N; i++ {
        result = process(input) // assign to package-level var to prevent optimization
    }
}

// Sub-benchmarks for different sizes
func BenchmarkProcess(b *testing.B) {
    for _, size := range []int{10, 100, 1000, 10000} {
        b.Run(fmt.Sprintf("size=%d", size), func(b *testing.B) {
            input := make([]Item, size)
            b.ResetTimer()
            for i := 0; i < b.N; i++ {
                process(input)
            }
        })
    }
}
```

```bash
# Run benchmarks
go test -bench=. -benchmem -count=5 ./...

# Compare before/after
go test -bench=. -benchmem -count=10 > old.txt
# ... make changes ...
go test -bench=. -benchmem -count=10 > new.txt
benchstat old.txt new.txt
```

## Database Performance

### N+1 Query Prevention
```go
// BAD: N+1 queries
for _, order := range orders {
    user, _ := db.GetUser(order.UserID)
}

// GOOD: batch query
userIDs := make([]int64, len(orders))
for i, o := range orders {
    userIDs[i] = o.UserID
}
users, _ := db.GetUsersByIDs(userIDs)
userMap := make(map[int64]*User, len(users))
for _, u := range users {
    userMap[u.ID] = u
}
```

### Connection Pool Tuning
```go
db.SetMaxOpenConns(25)              // match expected concurrency
db.SetMaxIdleConns(10)              // keep warm connections
db.SetConnMaxLifetime(5 * time.Minute)  // recycle stale connections
db.SetConnMaxIdleTime(1 * time.Minute)
```

### Query Optimization
- Use EXPLAIN ANALYZE on slow queries
- Index columns used in WHERE, JOIN, ORDER BY
- Use SELECT specific columns, not SELECT *
- Use LIMIT for pagination, cursor-based for large datasets
- Use prepared statements for repeated queries

## HTTP Performance

```go
// Reuse HTTP client - never create per request
var httpClient = &http.Client{
    Timeout: 10 * time.Second,
    Transport: &http.Transport{
        MaxIdleConns:        100,
        MaxIdleConnsPerHost: 10,
        IdleConnTimeout:     90 * time.Second,
    },
}
```

## GC Tuning

```bash
# Monitor GC
GODEBUG=gctrace=1 ./myapp

# Adjust GC target (default GOGC=100)
GOGC=200 ./myapp  # less frequent GC, more memory
```

- Reduce allocation rate > tune GC parameters
- Use `runtime.ReadMemStats()` for programmatic monitoring
- For latency-sensitive: consider GOMEMLIMIT (Go 1.19+)

## Quick Performance Checklist

- [ ] No allocation in per-request hot path that can be pooled
- [ ] Slices preallocated with known capacity
- [ ] No string concatenation in loops
- [ ] HTTP/DB clients are reused, not created per request
- [ ] No N+1 queries
- [ ] Large structs passed by pointer
- [ ] Benchmark exists for critical paths
- [ ] Profile data backs optimization decisions (don't guess)
