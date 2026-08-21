---
name: go-redis-patterns
description: Redis integration patterns in Go including caching, distributed locks, Lua scripting, pub/sub, rate limiting, and session management. Use this skill whenever the user mentions Redis in Go, go-redis, caching strategies, distributed locking, Redis Lua scripts, cache invalidation, Redis pub/sub, rate limiting with Redis, or any Redis-related development in Go. Also trigger for Redis connection pooling, Redis cluster setup, and Redis data structure patterns.
---

# Go Redis Patterns

Production patterns for Redis integration in Go, covering caching, distributed locks, Lua scripting, pub/sub, and more.

## When to Use This Skill

- Redis caching with go-redis
- Distributed locking (Redis + Lua)
- Cache invalidation strategies
- Rate limiting with Redis
- Pub/Sub messaging
- Session management
- Redis connection and cluster setup

## Core Patterns

### 1. Redis Client Setup

```go
package redis

import (
    "context"
    "fmt"
    "time"

    "github.com/redis/go-redis/v9"
)

type Config struct {
    Addr         string
    Password     string
    DB           int
    PoolSize     int
    MinIdleConns int
    MaxRetries   int
    DialTimeout  time.Duration
    ReadTimeout  time.Duration
    WriteTimeout time.Duration
}

func DefaultConfig() Config {
    return Config{
        Addr:         "localhost:6379",
        DB:           0,
        PoolSize:     10,
        MinIdleConns: 3,
        MaxRetries:   3,
        DialTimeout:  5 * time.Second,
        ReadTimeout:  3 * time.Second,
        WriteTimeout: 3 * time.Second,
    }
}

func NewClient(cfg Config) (*redis.Client, error) {
    client := redis.NewClient(&redis.Options{
        Addr:         cfg.Addr,
        Password:     cfg.Password,
        DB:           cfg.DB,
        PoolSize:     cfg.PoolSize,
        MinIdleConns: cfg.MinIdleConns,
        MaxRetries:   cfg.MaxRetries,
        DialTimeout:  cfg.DialTimeout,
        ReadTimeout:  cfg.ReadTimeout,
        WriteTimeout: cfg.WriteTimeout,
    })

    ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
    defer cancel()

    if err := client.Ping(ctx).Err(); err != nil {
        return nil, fmt.Errorf("redis ping: %w", err)
    }

    return client, nil
}

// Cluster setup
func NewClusterClient(addrs []string, password string) (*redis.ClusterClient, error) {
    client := redis.NewClusterClient(&redis.ClusterOptions{
        Addrs:        addrs,
        Password:     password,
        PoolSize:     10,
        MinIdleConns: 3,
        MaxRetries:   3,
        RouteByLatency: true,
    })

    ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
    defer cancel()

    if err := client.Ping(ctx).Err(); err != nil {
        return nil, fmt.Errorf("redis cluster ping: %w", err)
    }

    return client, nil
}
```

### 2. Generic Cache Layer

```go
package cache

import (
    "context"
    "encoding/json"
    "errors"
    "fmt"
    "time"

    "github.com/redis/go-redis/v9"
)

var ErrCacheMiss = errors.New("cache miss")

type Cache struct {
    client *redis.Client
    prefix string
}

func NewCache(client *redis.Client, prefix string) *Cache {
    return &Cache{client: client, prefix: prefix}
}

func (c *Cache) key(k string) string {
    return c.prefix + ":" + k
}

// Get with JSON deserialization
func Get[T any](ctx context.Context, c *Cache, key string) (T, error) {
    var result T
    data, err := c.client.Get(ctx, c.key(key)).Bytes()
    if errors.Is(err, redis.Nil) {
        return result, ErrCacheMiss
    }
    if err != nil {
        return result, fmt.Errorf("cache get: %w", err)
    }
    if err := json.Unmarshal(data, &result); err != nil {
        return result, fmt.Errorf("cache unmarshal: %w", err)
    }
    return result, nil
}

// Set with JSON serialization
func Set[T any](ctx context.Context, c *Cache, key string, value T, ttl time.Duration) error {
    data, err := json.Marshal(value)
    if err != nil {
        return fmt.Errorf("cache marshal: %w", err)
    }
    return c.client.Set(ctx, c.key(key), data, ttl).Err()
}

// GetOrSet: cache-aside pattern
func GetOrSet[T any](ctx context.Context, c *Cache, key string, ttl time.Duration, fn func() (T, error)) (T, error) {
    // Try cache first
    result, err := Get[T](ctx, c, key)
    if err == nil {
        return result, nil
    }
    if !errors.Is(err, ErrCacheMiss) {
        // Log cache error but continue to source
    }

    // Fetch from source
    result, err = fn()
    if err != nil {
        return result, err
    }

    // Store in cache (fire and forget)
    go func() {
        bgCtx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
        defer cancel()
        Set(bgCtx, c, key, result, ttl)
    }()

    return result, nil
}

// Delete
func (c *Cache) Delete(ctx context.Context, keys ...string) error {
    fullKeys := make([]string, len(keys))
    for i, k := range keys {
        fullKeys[i] = c.key(k)
    }
    return c.client.Del(ctx, fullKeys...).Err()
}

// Delete by pattern
func (c *Cache) DeletePattern(ctx context.Context, pattern string) error {
    var cursor uint64
    for {
        keys, newCursor, err := c.client.Scan(ctx, cursor, c.key(pattern), 100).Result()
        if err != nil {
            return err
        }
        if len(keys) > 0 {
            c.client.Del(ctx, keys...)
        }
        cursor = newCursor
        if cursor == 0 {
            break
        }
    }
    return nil
}
```

### 3. Distributed Lock (Redis + Lua)

```go
package lock

import (
    "context"
    "crypto/rand"
    "encoding/hex"
    "errors"
    "fmt"
    "time"

    "github.com/redis/go-redis/v9"
)

var (
    ErrLockNotAcquired = errors.New("lock not acquired")
    ErrLockNotHeld     = errors.New("lock not held")
)

// Lua script for atomic unlock (only unlock if we own the lock)
var unlockScript = redis.NewScript(`
    if redis.call("GET", KEYS[1]) == ARGV[1] then
        return redis.call("DEL", KEYS[1])
    else
        return 0
    end
`)

// Lua script for atomic extend
var extendScript = redis.NewScript(`
    if redis.call("GET", KEYS[1]) == ARGV[1] then
        return redis.call("PEXPIRE", KEYS[1], ARGV[2])
    else
        return 0
    end
`)

type Lock struct {
    client *redis.Client
    key    string
    value  string
    ttl    time.Duration
}

func NewLock(client *redis.Client, key string, ttl time.Duration) *Lock {
    return &Lock{
        client: client,
        key:    "lock:" + key,
        value:  generateToken(),
        ttl:    ttl,
    }
}

func (l *Lock) Acquire(ctx context.Context) error {
    ok, err := l.client.SetNX(ctx, l.key, l.value, l.ttl).Result()
    if err != nil {
        return fmt.Errorf("acquire lock: %w", err)
    }
    if !ok {
        return ErrLockNotAcquired
    }
    return nil
}

// AcquireWithRetry tries to acquire the lock with retries
func (l *Lock) AcquireWithRetry(ctx context.Context, retryInterval time.Duration, maxRetries int) error {
    for i := 0; i < maxRetries; i++ {
        err := l.Acquire(ctx)
        if err == nil {
            return nil
        }
        if !errors.Is(err, ErrLockNotAcquired) {
            return err
        }

        select {
        case <-ctx.Done():
            return ctx.Err()
        case <-time.After(retryInterval):
        }
    }
    return ErrLockNotAcquired
}

func (l *Lock) Release(ctx context.Context) error {
    result, err := unlockScript.Run(ctx, l.client, []string{l.key}, l.value).Int64()
    if err != nil {
        return fmt.Errorf("release lock: %w", err)
    }
    if result == 0 {
        return ErrLockNotHeld
    }
    return nil
}

func (l *Lock) Extend(ctx context.Context, ttl time.Duration) error {
    result, err := extendScript.Run(ctx, l.client, []string{l.key}, l.value, ttl.Milliseconds()).Int64()
    if err != nil {
        return fmt.Errorf("extend lock: %w", err)
    }
    if result == 0 {
        return ErrLockNotHeld
    }
    return nil
}

// WithLock executes fn while holding the lock
func WithLock(ctx context.Context, client *redis.Client, key string, ttl time.Duration, fn func() error) error {
    lock := NewLock(client, key, ttl)
    if err := lock.AcquireWithRetry(ctx, 100*time.Millisecond, 30); err != nil {
        return fmt.Errorf("acquiring lock %s: %w", key, err)
    }
    defer lock.Release(ctx)

    return fn()
}

func generateToken() string {
    b := make([]byte, 16)
    rand.Read(b)
    return hex.EncodeToString(b)
}
```

### 4. Rate Limiter (Sliding Window)

```go
package ratelimit

import (
    "context"
    "fmt"
    "time"

    "github.com/redis/go-redis/v9"
)

// Lua script for sliding window rate limiting
var slidingWindowScript = redis.NewScript(`
    local key = KEYS[1]
    local now = tonumber(ARGV[1])
    local window = tonumber(ARGV[2])
    local limit = tonumber(ARGV[3])

    -- Remove expired entries
    redis.call("ZREMRANGEBYSCORE", key, 0, now - window)

    -- Count current entries
    local count = redis.call("ZCARD", key)

    if count < limit then
        -- Add current request
        redis.call("ZADD", key, now, now .. "-" .. math.random(1000000))
        redis.call("PEXPIRE", key, window)
        return {1, limit - count - 1}
    else
        return {0, 0}
    end
`)

type RateLimiter struct {
    client *redis.Client
    prefix string
}

func NewRateLimiter(client *redis.Client, prefix string) *RateLimiter {
    return &RateLimiter{client: client, prefix: prefix}
}

type RateLimitResult struct {
    Allowed   bool
    Remaining int64
}

func (rl *RateLimiter) Allow(ctx context.Context, key string, limit int64, window time.Duration) (*RateLimitResult, error) {
    fullKey := rl.prefix + ":ratelimit:" + key
    now := time.Now().UnixMilli()

    result, err := slidingWindowScript.Run(ctx, rl.client, []string{fullKey}, now, window.Milliseconds(), limit).Int64Slice()
    if err != nil {
        return nil, fmt.Errorf("rate limit check: %w", err)
    }

    return &RateLimitResult{
        Allowed:   result[0] == 1,
        Remaining: result[1],
    }, nil
}

// Token bucket implementation
var tokenBucketScript = redis.NewScript(`
    local key = KEYS[1]
    local rate = tonumber(ARGV[1])         -- tokens per second
    local capacity = tonumber(ARGV[2])     -- max tokens
    local now = tonumber(ARGV[3])          -- current time in ms
    local requested = tonumber(ARGV[4])    -- tokens requested

    local data = redis.call("HMGET", key, "tokens", "last_refill")
    local tokens = tonumber(data[1]) or capacity
    local last_refill = tonumber(data[2]) or now

    -- Refill tokens
    local elapsed = (now - last_refill) / 1000
    tokens = math.min(capacity, tokens + elapsed * rate)

    if tokens >= requested then
        tokens = tokens - requested
        redis.call("HMSET", key, "tokens", tokens, "last_refill", now)
        redis.call("PEXPIRE", key, math.ceil(capacity / rate) * 1000 + 1000)
        return {1, math.floor(tokens)}
    else
        redis.call("HMSET", key, "tokens", tokens, "last_refill", now)
        return {0, math.floor(tokens)}
    end
`)
```

### 5. Pub/Sub Pattern

```go
package pubsub

import (
    "context"
    "encoding/json"
    "fmt"

    "github.com/redis/go-redis/v9"
)

type Event struct {
    Type    string          `json:"type"`
    Payload json.RawMessage `json:"payload"`
}

type Publisher struct {
    client *redis.Client
}

func NewPublisher(client *redis.Client) *Publisher {
    return &Publisher{client: client}
}

func (p *Publisher) Publish(ctx context.Context, channel string, event Event) error {
    data, err := json.Marshal(event)
    if err != nil {
        return fmt.Errorf("marshal event: %w", err)
    }
    return p.client.Publish(ctx, channel, data).Err()
}

type Handler func(ctx context.Context, event Event) error

type Subscriber struct {
    client   *redis.Client
    handlers map[string][]Handler
}

func NewSubscriber(client *redis.Client) *Subscriber {
    return &Subscriber{
        client:   client,
        handlers: make(map[string][]Handler),
    }
}

func (s *Subscriber) On(eventType string, handler Handler) {
    s.handlers[eventType] = append(s.handlers[eventType], handler)
}

func (s *Subscriber) Subscribe(ctx context.Context, channels ...string) error {
    sub := s.client.Subscribe(ctx, channels...)
    defer sub.Close()

    ch := sub.Channel()
    for {
        select {
        case <-ctx.Done():
            return ctx.Err()
        case msg := <-ch:
            var event Event
            if err := json.Unmarshal([]byte(msg.Payload), &event); err != nil {
                continue // Log and skip malformed events
            }

            handlers, ok := s.handlers[event.Type]
            if !ok {
                continue
            }
            for _, h := range handlers {
                if err := h(ctx, event); err != nil {
                    // Log handler error
                }
            }
        }
    }
}
```

### 6. Inventory Deduction with Lua (Atomic)

```go
package inventory

import "github.com/redis/go-redis/v9"

// Atomic stock deduction — checks and decrements in one round trip
var deductStockScript = redis.NewScript(`
    local key = KEYS[1]
    local quantity = tonumber(ARGV[1])

    local stock = tonumber(redis.call("GET", key) or "0")
    if stock < quantity then
        return {0, stock}  -- insufficient stock
    end

    local remaining = redis.call("DECRBY", key, quantity)
    return {1, remaining}
`)

type StockResult struct {
    Success   bool
    Remaining int64
}

func DeductStock(ctx context.Context, client *redis.Client, productID string, quantity int) (*StockResult, error) {
    key := "stock:" + productID
    result, err := deductStockScript.Run(ctx, client, []string{key}, quantity).Int64Slice()
    if err != nil {
        return nil, err
    }
    return &StockResult{
        Success:   result[0] == 1,
        Remaining: result[1],
    }, nil
}
```

### 7. Session Management

```go
package session

import (
    "context"
    "crypto/rand"
    "encoding/hex"
    "encoding/json"
    "fmt"
    "time"

    "github.com/redis/go-redis/v9"
)

type Session struct {
    ID     string                 `json:"id"`
    UserID int64                  `json:"user_id"`
    Data   map[string]interface{} `json:"data"`
    Expiry time.Time              `json:"expiry"`
}

type SessionStore struct {
    client *redis.Client
    ttl    time.Duration
    prefix string
}

func NewSessionStore(client *redis.Client, ttl time.Duration) *SessionStore {
    return &SessionStore{client: client, ttl: ttl, prefix: "session"}
}

func (s *SessionStore) Create(ctx context.Context, userID int64, data map[string]interface{}) (*Session, error) {
    sess := &Session{
        ID:     generateSessionID(),
        UserID: userID,
        Data:   data,
        Expiry: time.Now().Add(s.ttl),
    }

    bytes, err := json.Marshal(sess)
    if err != nil {
        return nil, err
    }

    key := fmt.Sprintf("%s:%s", s.prefix, sess.ID)
    if err := s.client.Set(ctx, key, bytes, s.ttl).Err(); err != nil {
        return nil, err
    }

    return sess, nil
}

func (s *SessionStore) Get(ctx context.Context, sessionID string) (*Session, error) {
    key := fmt.Sprintf("%s:%s", s.prefix, sessionID)
    data, err := s.client.Get(ctx, key).Bytes()
    if err != nil {
        return nil, fmt.Errorf("session not found: %w", err)
    }

    var sess Session
    if err := json.Unmarshal(data, &sess); err != nil {
        return nil, err
    }
    return &sess, nil
}

func (s *SessionStore) Refresh(ctx context.Context, sessionID string) error {
    key := fmt.Sprintf("%s:%s", s.prefix, sessionID)
    return s.client.Expire(ctx, key, s.ttl).Err()
}

func (s *SessionStore) Destroy(ctx context.Context, sessionID string) error {
    key := fmt.Sprintf("%s:%s", s.prefix, sessionID)
    return s.client.Del(ctx, key).Err()
}

func generateSessionID() string {
    b := make([]byte, 32)
    rand.Read(b)
    return hex.EncodeToString(b)
}
```

### 8. Redis Pipeline for Batch Operations

```go
func BatchGetUsers(ctx context.Context, client *redis.Client, userIDs []int64) (map[int64]*User, error) {
    pipe := client.Pipeline()

    cmds := make(map[int64]*redis.StringCmd, len(userIDs))
    for _, id := range userIDs {
        key := fmt.Sprintf("user:%d", id)
        cmds[id] = pipe.Get(ctx, key)
    }

    _, err := pipe.Exec(ctx)
    if err != nil && !errors.Is(err, redis.Nil) {
        return nil, err
    }

    result := make(map[int64]*User, len(userIDs))
    for id, cmd := range cmds {
        data, err := cmd.Bytes()
        if err != nil {
            continue // Cache miss
        }
        var user User
        if json.Unmarshal(data, &user) == nil {
            result[id] = &user
        }
    }
    return result, nil
}
```

## Pool Tuning

| Workload | PoolSize | MinIdleConns | ReadTimeout | WriteTimeout |
|----------|----------|-------------|-------------|--------------|
| Low traffic | 10 | 3 | 3s | 3s |
| Medium API | 25 | 5 | 1s | 1s |
| High traffic | 50-100 | 10 | 500ms | 500ms |
| Pub/Sub heavy | 30 | 5 | 0 (block) | 3s |

## Best Practices

### Do's
- **Use Lua scripts** for atomic multi-step operations
- **Set TTL on all keys** to prevent memory leaks
- **Use pipelines** for batch operations (reduces round trips)
- **Use key prefixes** for namespace isolation
- **Monitor memory** with `INFO memory` and set `maxmemory`
- **Handle `redis.Nil`** explicitly for cache misses

### Don'ts
- **Don't use KEYS** in production — use SCAN instead
- **Don't store large values** — keep values under 1MB
- **Don't use Redis as primary DB** — it's a cache/store layer
- **Don't forget eviction policy** — set `maxmemory-policy`
- **Don't block on single-threaded ops** — batch with pipelines
- **Don't skip connection error handling** — implement circuit breaker for production
