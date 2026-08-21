---
name: go-observability
description: Go logging and observability patterns. Covers structured logging with zap and gtkit/logger, OpenTelemetry tracing, Prometheus metrics, request tracing, and production monitoring best practices.
allowed-tools: "Read, Write, Edit, Bash, Glob, Grep"
---

# Go Logging & Observability

## Structured Logging

### Using zap (High Performance)

```go
import "go.uber.org/zap"

func NewLogger(env string) (*zap.Logger, error) {
    if env == "production" {
        cfg := zap.NewProductionConfig()
        cfg.OutputPaths = []string{"stdout"}
        cfg.ErrorOutputPaths = []string{"stderr"}
        cfg.EncoderConfig.TimeKey = "ts"
        cfg.EncoderConfig.EncodeTime = zapcore.ISO8601TimeEncoder
        return cfg.Build()
    }
    return zap.NewDevelopment()
}

// Usage
logger.Info("order created",
    zap.Int64("order_id", order.ID),
    zap.Int64("user_id", order.UserID),
    zap.String("status", order.Status),
    zap.Duration("duration", elapsed),
)

logger.Error("payment failed",
    zap.Int64("order_id", orderID),
    zap.Error(err),
)
```

### Using gtkit/logger (v2)

All logging goes through `github.com/gtkit/logger/v2`, a zap-based wrapper that
owns encoding, rotation, redaction and the process default instance. Build the
default once at startup; everywhere else call the package-level functions — they
forward to it, so `caller` still points at the real call site.

```go
import (
    "github.com/gtkit/logger/v2"
    "go.uber.org/zap"
)

func InitLogger(env string) {
    opts := []logger.Option{
        logger.WithPath("./logs/app"),
        logger.WithRedactKeys("password", "token", "authorization"),
    }
    if env == "production" {
        opts = append(opts,
            logger.WithOutJSON(true),      // JSON encoding
            logger.WithLevel("info"),
            logger.WithSampling(100, 100), // first, thereafter
        )
    } else {
        opts = append(opts,
            logger.WithConsole(true), // also write to stdout
            logger.WithLevel("debug"),
        )
    }
    logger.SetDefault(logger.MustNew(opts...))
}

// Usage — structured fields
logger.Info("order created",
    zap.Int64("order_id", order.ID),
    zap.Int64("user_id", order.UserID),
    zap.String("status", order.Status),
    zap.Duration("duration", elapsed),
)

logger.Error("payment failed",
    zap.Int64("order_id", orderID),
    zap.Error(err),
)

// Sugar style for ad-hoc key/value pairs
logger.Errorw("payment failed", "order_id", orderID, "err", err)

// *Ctx variants merge fields injected into the context
ctx = logger.ContextWithRequestID(ctx, requestID)
logger.InfoCtx(ctx, "order created", zap.Int64("order_id", order.ID))
```

Flush buffered writes before the process exits:

```go
defer logger.Sync()
```

`WithRedactKeys` replaces the value of every matching field with `[REDACTED]`,
which is what keeps sensitive fields out of the log files:

```
{"level":"INFO","msg":"login attempt","user":"alice","password":"[REDACTED]","token":"[REDACTED]","keep":"visible"}
```

### Logging Rules

| DO | DON'T |
|----|-------|
| Log at the right level | Log same error at multiple levels |
| Include request_id in all logs | Log sensitive data (passwords, tokens, PII) |
| Use structured fields | Use fmt.Sprintf in log messages |
| Log errors with stack context | Log expected/normal events as errors |
| Log at system boundaries | Log inside tight loops |
| Use sampling in production | Log request/response bodies in production |

### Log Levels
```
DEBUG  - Development diagnostics, disabled in production
INFO   - Business events: order created, user logged in, payment processed
WARN   - Degraded state: retry succeeded, fallback activated, slow query
ERROR  - Operation failed: payment error, DB timeout, external API failure
FATAL  - Cannot continue: config missing, port unavailable (only in main)
```

## Request Context Logging

Register the context extractor once at startup. The `*Ctx` methods then merge
those fields automatically, so no layer has to carry a logger instance around —
and no package-level name gets shadowed by a `logger` parameter.

```go
// At startup. The func must be concurrency-safe: the *Ctx methods call it
// from many goroutines.
logger.SetDefault(logger.MustNew(
    logger.WithPath("./logs/app"),
    logger.WithContextFields(func(ctx context.Context) []zap.Field {
        if id := logger.RequestIDFromContext(ctx); id != "" {
            return []zap.Field{zap.String("request_id", id)}
        }
        return nil
    }),
))

// Middleware: put the request id into the context
func RequestLoggerMiddleware() gin.HandlerFunc {
    return func(c *gin.Context) {
        requestID := c.GetHeader("X-Request-ID")
        if requestID == "" {
            requestID = uuid.New().String()
        }

        ctx := logger.ContextWithRequestID(c.Request.Context(), requestID)
        c.Request = c.Request.WithContext(ctx)
        c.Set("request_id", requestID)
        c.Header("X-Request-ID", requestID)

        start := time.Now()
        c.Next()

        logger.InfoCtx(ctx, "request completed",
            zap.String("method", c.Request.Method),
            zap.String("path", c.Request.URL.Path),
            zap.String("client_ip", c.ClientIP()),
            zap.Int("status", c.Writer.Status()),
            zap.Duration("latency", time.Since(start)),
            zap.Int("body_size", c.Writer.Size()),
        )
    }
}

// Downstream layers just pass ctx — request_id rides along, no logger param
func CreateOrder(ctx context.Context, userID int64) error {
    logger.InfoCtx(ctx, "order created", zap.Int64("user_id", userID))
    return nil
}
```

`request_id` is merged in without being passed explicitly:

```
{"level":"INFO","msg":"order created","request_id":"req-abc","user_id":42}
```

## Prometheus Metrics

```go
import "github.com/prometheus/client_golang/prometheus"

var (
    httpRequestsTotal = prometheus.NewCounterVec(
        prometheus.CounterOpts{
            Name: "http_requests_total",
            Help: "Total HTTP requests",
        },
        []string{"method", "path", "status"},
    )

    httpRequestDuration = prometheus.NewHistogramVec(
        prometheus.HistogramOpts{
            Name:    "http_request_duration_seconds",
            Help:    "HTTP request duration",
            Buckets: []float64{.005, .01, .025, .05, .1, .25, .5, 1, 2.5, 5},
        },
        []string{"method", "path"},
    )

    activeConnections = prometheus.NewGauge(
        prometheus.GaugeOpts{
            Name: "active_connections",
            Help: "Number of active connections",
        },
    )

    dbQueryDuration = prometheus.NewHistogramVec(
        prometheus.HistogramOpts{
            Name:    "db_query_duration_seconds",
            Help:    "Database query duration",
            Buckets: []float64{.001, .005, .01, .05, .1, .5, 1},
        },
        []string{"operation", "table"},
    )
)

func init() {
    prometheus.MustRegister(
        httpRequestsTotal,
        httpRequestDuration,
        activeConnections,
        dbQueryDuration,
    )
}

// Metrics middleware
func MetricsMiddleware() gin.HandlerFunc {
    return func(c *gin.Context) {
        start := time.Now()
        c.Next()
        duration := time.Since(start).Seconds()
        status := strconv.Itoa(c.Writer.Status())
        httpRequestsTotal.WithLabelValues(c.Request.Method, c.FullPath(), status).Inc()
        httpRequestDuration.WithLabelValues(c.Request.Method, c.FullPath()).Observe(duration)
    }
}

// Expose metrics endpoint
// router.GET("/metrics", gin.WrapH(promhttp.Handler()))
```

### Key Metrics to Track

| Category | Metrics |
|----------|---------|
| **RED** (Request) | Rate, Error rate, Duration |
| **USE** (Resource) | Utilization, Saturation, Errors |
| **Business** | Orders/min, Payment success rate, Active users |
| **Infrastructure** | Goroutine count, Memory usage, GC pause, Open connections |

```go
// Business metrics example
var (
    ordersCreated = prometheus.NewCounter(prometheus.CounterOpts{
        Name: "orders_created_total",
    })
    paymentSuccessRate = prometheus.NewCounterVec(
        prometheus.CounterOpts{Name: "payment_attempts_total"},
        []string{"result"}, // "success", "failed"
    )
)
```

## OpenTelemetry Tracing

```go
import (
    "go.opentelemetry.io/otel"
    "go.opentelemetry.io/otel/trace"
)

// Service layer with span
func (s *OrderService) CreateOrder(ctx context.Context, req *CreateOrderReq) (*Order, error) {
    ctx, span := otel.Tracer("order-service").Start(ctx, "CreateOrder")
    defer span.End()

    span.SetAttributes(
        attribute.Int64("user_id", req.UserID),
        attribute.String("product_id", req.ProductID),
    )

    order, err := s.repo.Create(ctx, req)
    if err != nil {
        span.RecordError(err)
        span.SetStatus(codes.Error, err.Error())
        return nil, err
    }

    span.SetAttributes(attribute.Int64("order_id", order.ID))
    return order, nil
}
```

## Slow Query Logging

```go
// GORM slow query callback
func SlowQueryPlugin(threshold time.Duration, logger *zap.Logger) gorm.Plugin {
    return &slowQuery{threshold: threshold, logger: logger}
}

type slowQuery struct {
    threshold time.Duration
    logger    *zap.Logger
}

func (s *slowQuery) Name() string { return "slow_query" }
func (s *slowQuery) Initialize(db *gorm.DB) error {
    db.Callback().Query().After("gorm:query").Register("slow_query:log", func(db *gorm.DB) {
        elapsed := db.Statement.Context.Value(elapsedKey).(time.Duration)
        if elapsed > s.threshold {
            s.logger.Warn("slow query",
                zap.String("sql", db.Statement.SQL.String()),
                zap.Duration("elapsed", elapsed),
                zap.Int64("rows", db.RowsAffected),
            )
        }
    })
    return nil
}
```

## Observability Checklist

- [ ] Structured JSON logging in production
- [ ] Request ID propagated through all layers
- [ ] HTTP metrics: request count, duration histogram, error rate
- [ ] DB metrics: query duration, connection pool stats
- [ ] Business metrics: key operations counted
- [ ] Health check endpoint with dependency status
- [ ] Slow query logging (> 200ms)
- [ ] Error logs include stack context (not just message)
- [ ] No sensitive data in logs or traces
- [ ] Log sampling enabled for high-throughput paths
- [ ] Goroutine and memory metrics exported
