---
name: go-concurrency
description: Go concurrency patterns and best practices. Covers goroutine lifecycle, channel patterns, sync primitives, context propagation, worker pools, errgroup, and leak prevention.
allowed-tools: "Read, Write, Edit, Bash, Glob, Grep"
---

# Go Concurrency Patterns

## Goroutine Lifecycle Management

### Rule: Every goroutine must have a clear exit path
- Always pass `context.Context` to goroutines for cancellation
- Never launch fire-and-forget goroutines without cleanup mechanism
- Use `sync.WaitGroup` or `errgroup.Group` to wait for goroutine completion

```go
// GOOD: goroutine with clear exit
func (s *Service) StartWorker(ctx context.Context) {
    go func() {
        for {
            select {
            case <-ctx.Done():
                return
            case task := <-s.taskCh:
                s.process(ctx, task)
            }
        }
    }()
}

// BAD: goroutine leak
func (s *Service) StartWorker() {
    go func() {
        for task := range s.taskCh { // never closes = goroutine leak
            s.process(task)
        }
    }()
}
```

### Goroutine Leak Detection Checklist
- [ ] Every `go func()` has a matching cancellation or completion signal
- [ ] Channels used in goroutines will eventually close or context will cancel
- [ ] HTTP request goroutines respect `req.Context()`
- [ ] Timer/ticker goroutines call `Stop()` on cleanup
- [ ] Test with `goleak.VerifyNone(t)` from `go.uber.org/goleak`

## Channel Patterns

### Buffered vs Unbuffered
- Unbuffered: use for synchronization (handshake between goroutines)
- Buffered: use for decoupling producer/consumer speed
- Rule: buffer size should be justified, not arbitrary

### Fan-out / Fan-in
```go
func fanOut(ctx context.Context, input <-chan Task, workers int) <-chan Result {
    results := make(chan Result, workers)
    var wg sync.WaitGroup
    for i := 0; i < workers; i++ {
        wg.Add(1)
        go func() {
            defer wg.Done()
            for task := range input {
                select {
                case <-ctx.Done():
                    return
                case results <- process(task):
                }
            }
        }()
    }
    go func() {
        wg.Wait()
        close(results)
    }()
    return results
}
```

### Pipeline Pattern
```go
func pipeline(ctx context.Context, input <-chan int) <-chan int {
    out := make(chan int)
    go func() {
        defer close(out)
        for v := range input {
            select {
            case <-ctx.Done():
                return
            case out <- transform(v):
            }
        }
    }()
    return out
}
```

### Channel Anti-Patterns
- Never close a channel from the receiver side
- Never close a channel more than once (use `sync.Once`)
- Don't use channel when mutex is simpler and sufficient
- Avoid sending on a nil channel (blocks forever)

## sync Primitives

### sync.Mutex / sync.RWMutex
```go
// GOOD: minimal critical section
mu.Lock()
value := m[key]
mu.Unlock()

// BAD: holding lock during I/O
mu.Lock()
result, err := http.Get(url) // blocks other goroutines
mu.Unlock()
```

- Use `RWMutex` when reads >> writes
- Never copy a mutex (pass by pointer)
- Lock ordering: always acquire in the same order to prevent deadlock
- Keep critical sections small - no I/O, no channel ops under lock

### sync.Once
```go
var initOnce sync.Once
var client *http.Client

func getClient() *http.Client {
    initOnce.Do(func() {
        client = &http.Client{Timeout: 10 * time.Second}
    })
    return client
}
```

### sync.Pool
- Use for frequently allocated/released objects in hot paths
- Objects may be garbage collected at any time - don't store state
- Always reset object before putting back
```go
var bufPool = sync.Pool{
    New: func() any { return new(bytes.Buffer) },
}

func process(data []byte) {
    buf := bufPool.Get().(*bytes.Buffer)
    defer func() {
        buf.Reset()
        bufPool.Put(buf)
    }()
    buf.Write(data)
}
```

### sync.Map
- Use ONLY when keys are stable (read-heavy, rarely written)
- For dynamic key sets, use regular map + RWMutex

## errgroup Pattern

```go
func fetchAll(ctx context.Context, urls []string) ([]Response, error) {
    g, ctx := errgroup.WithContext(ctx)
    results := make([]Response, len(urls))

    for i, url := range urls {
        i, url := i, url
        g.Go(func() error {
            resp, err := fetch(ctx, url)
            if err != nil {
                return fmt.Errorf("fetch %s: %w", url, err)
            }
            results[i] = resp
            return nil
        })
    }

    if err := g.Wait(); err != nil {
        return nil, err
    }
    return results, nil
}
```

- Use `errgroup.SetLimit(n)` to control concurrency
- First error cancels the derived context, stopping other goroutines
- Each goroutine writes to its own index - no mutex needed

## Context Propagation Rules

1. `context.Context` is always the first parameter
2. Never store context in a struct field (except for request-scoped objects)
3. Use `context.WithTimeout` for external calls
4. Use `context.WithCancel` for owned goroutines
5. Check `ctx.Err()` before expensive operations
6. Pass `context.TODO()` only as temporary placeholder, never in production

## Worker Pool Pattern

```go
type WorkerPool struct {
    tasks   chan func()
    wg      sync.WaitGroup
}

func NewWorkerPool(size int) *WorkerPool {
    p := &WorkerPool{tasks: make(chan func(), size*2)}
    for i := 0; i < size; i++ {
        p.wg.Add(1)
        go func() {
            defer p.wg.Done()
            for fn := range p.tasks {
                fn()
            }
        }()
    }
    return p
}

func (p *WorkerPool) Submit(fn func()) { p.tasks <- fn }
func (p *WorkerPool) Shutdown()        { close(p.tasks); p.wg.Wait() }
```

## Race Condition Prevention

- Always run tests with `-race` flag
- Use `atomic` package for simple counters/flags instead of mutex
- Never read and write shared variable from different goroutines without synchronization
- Use `chan struct{}` for signaling, not `chan bool`
