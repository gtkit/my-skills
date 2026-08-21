---
name: go-microservice
description: Go microservice patterns for production systems. Covers graceful shutdown, circuit breaker, rate limiting, distributed tracing, service discovery, health checks, and resilience patterns.
allowed-tools: "Read, Write, Edit, Bash, Glob, Grep"
---

# Go Microservice Patterns

## Graceful Shutdown

```go
func main() {
    srv := &http.Server{Addr: ":8080", Handler: router}

    go func() {
        if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
            log.Fatalf("listen: %s", err)
        }
    }()

    // Wait for interrupt signal
    quit := make(chan os.Signal, 1)
    signal.Notify(quit, syscall.SIGINT, syscall.SIGTERM)
    <-quit
    log.Println("shutting down server...")

    // Give outstanding requests a deadline to complete
    ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
    defer cancel()

    // Shutdown sequence: stop accepting -> drain -> close deps
    if err := srv.Shutdown(ctx); err != nil {
        log.Fatalf("server forced to shutdown: %s", err)
    }

    // Close DB, Redis, MQ connections
    db.Close()
    redisClient.Close()

    log.Println("server exited")
}
```

### Shutdown Order
1. Stop accepting new requests (http.Server.Shutdown)
2. Wait for in-flight requests to complete
3. Stop background workers (cancel context / close channels)
4. Close downstream connections (DB, Redis, MQ)
5. Flush logs and metrics

## Circuit Breaker

```go
import "github.com/sony/gobreaker"

var cb *gobreaker.CircuitBreaker

func init() {
    cb = gobreaker.NewCircuitBreaker(gobreaker.Settings{
        Name:        "payment-service",
        MaxRequests: 3,                // requests allowed in half-open
        Interval:    10 * time.Second, // reset counts interval
        Timeout:     30 * time.Second, // time in open before half-open
        ReadyToTrip: func(counts gobreaker.Counts) bool {
            failureRatio := float64(counts.TotalFailures) / float64(counts.Requests)
            return counts.Requests >= 10 && failureRatio >= 0.6
        },
        OnStateChange: func(name string, from, to gobreaker.State) {
            log.Printf("circuit breaker %s: %s -> %s", name, from, to)
        },
    })
}

func CallPaymentService(ctx context.Context, req *PayReq) (*PayResp, error) {
    result, err := cb.Execute(func() (interface{}, error) {
        return paymentClient.Pay(ctx, req)
    })
    if err != nil {
        if err == gobreaker.ErrOpenState {
            return nil, errors.New("payment service unavailable, please retry later")
        }
        return nil, fmt.Errorf("payment call: %w", err)
    }
    return result.(*PayResp), nil
}
```

## Retry with Backoff

```go
func RetryWithBackoff(ctx context.Context, maxRetries int, fn func() error) error {
    var err error
    for i := 0; i <= maxRetries; i++ {
        err = fn()
        if err == nil {
            return nil
        }
        if i == maxRetries {
            break
        }
        // Exponential backoff with jitter
        backoff := time.Duration(1<<uint(i)) * 100 * time.Millisecond
        jitter := time.Duration(rand.Int63n(int64(backoff / 2)))
        wait := backoff + jitter

        select {
        case <-ctx.Done():
            return ctx.Err()
        case <-time.After(wait):
        }
    }
    return fmt.Errorf("after %d retries: %w", maxRetries, err)
}
```

### Retry Rules
- Only retry idempotent operations
- Use exponential backoff + jitter to avoid thundering herd
- Set a maximum retry count
- Respect context cancellation
- Don't retry 4xx errors (client's fault)
- Retry 5xx and timeout errors

## Health Check

```go
type HealthChecker struct {
    db    *gorm.DB
    redis *redis.Client
}

func (h *HealthChecker) Check(c *gin.Context) {
    checks := map[string]string{}
    healthy := true

    // DB check
    sqlDB, _ := h.db.DB()
    if err := sqlDB.PingContext(c.Request.Context()); err != nil {
        checks["database"] = "unhealthy: " + err.Error()
        healthy = false
    } else {
        checks["database"] = "healthy"
    }

    // Redis check
    if err := h.redis.Ping(c.Request.Context()).Err(); err != nil {
        checks["redis"] = "unhealthy: " + err.Error()
        healthy = false
    } else {
        checks["redis"] = "healthy"
    }

    status := http.StatusOK
    if !healthy {
        status = http.StatusServiceUnavailable
    }
    c.JSON(status, gin.H{
        "status": map[bool]string{true: "healthy", false: "unhealthy"}[healthy],
        "checks": checks,
    })
}

// Register: router.GET("/health", checker.Check)
// Kubernetes liveness: /health
// Kubernetes readiness: /health (or separate /ready endpoint)
```

## Timeout Control

```go
// Per-request timeout middleware
func TimeoutMiddleware(timeout time.Duration) gin.HandlerFunc {
    return func(c *gin.Context) {
        ctx, cancel := context.WithTimeout(c.Request.Context(), timeout)
        defer cancel()
        c.Request = c.Request.WithContext(ctx)
        c.Next()
    }
}

// External call timeout
func callExternal(ctx context.Context) error {
    ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
    defer cancel()

    req, _ := http.NewRequestWithContext(ctx, "GET", url, nil)
    resp, err := httpClient.Do(req)
    // ...
}
```

### Timeout Strategy
| Layer | Timeout |
|-------|---------|
| Client-side (Nginx/LB) | 60s |
| HTTP handler | 30s |
| Service-to-service call | 5-10s |
| Database query | 3-5s |
| Redis operation | 1-2s |
| Each layer's timeout < parent's timeout |

## Idempotency

```go
// Use idempotency key for non-idempotent operations
func (s *OrderService) Pay(ctx context.Context, orderID int64, idempotencyKey string) error {
    // Check if already processed
    exists, err := s.redis.SetNX(ctx,
        fmt.Sprintf("pay:idem:%s", idempotencyKey),
        "processing",
        10*time.Minute,
    ).Result()
    if err != nil {
        return fmt.Errorf("check idempotency: %w", err)
    }
    if !exists {
        return nil // already processed
    }

    // Process payment
    if err := s.processPayment(ctx, orderID); err != nil {
        s.redis.Del(ctx, fmt.Sprintf("pay:idem:%s", idempotencyKey))
        return err
    }
    return nil
}
```

## Structured Logging for Microservices

```go
// Include trace context in every log
func LogMiddleware(logger *zap.Logger) gin.HandlerFunc {
    return func(c *gin.Context) {
        requestID := c.GetHeader("X-Request-ID")
        if requestID == "" {
            requestID = uuid.New().String()
        }
        c.Set("request_id", requestID)
        c.Header("X-Request-ID", requestID)

        start := time.Now()
        c.Next()
        duration := time.Since(start)

        logger.Info("request",
            zap.String("request_id", requestID),
            zap.String("method", c.Request.Method),
            zap.String("path", c.Request.URL.Path),
            zap.Int("status", c.Writer.Status()),
            zap.Duration("duration", duration),
            zap.String("client_ip", c.ClientIP()),
        )
    }
}
```

## Service Communication Checklist

- [ ] Circuit breaker on all external service calls
- [ ] Timeout on every outbound request
- [ ] Retry with exponential backoff for transient failures
- [ ] Idempotency key for payment/mutation operations
- [ ] Health check endpoint exposed
- [ ] Graceful shutdown handles SIGTERM
- [ ] Request ID propagated across service boundaries
- [ ] Connection pools configured for DB/Redis/HTTP
