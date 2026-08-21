---
name: go-error-handling
description: Go error handling patterns for enterprise systems. Covers error wrapping, sentinel errors, custom error types, error code systems, and structured error responses.
allowed-tools: "Read, Write, Edit, Bash, Glob, Grep"
---

# Go Error Handling Patterns

## Core Principles

1. Errors are values - treat them as first-class data
2. Handle errors at the right level - not too early, not too late
3. Add context when wrapping - each layer adds "what happened here"
4. Never silently discard errors - `_ = fn()` is a code smell

## Error Wrapping Chain

```go
// Repository layer - wraps the raw error with operation context
func (r *OrderRepo) GetByID(ctx context.Context, id int64) (*Order, error) {
    var order Order
    err := r.db.WithContext(ctx).First(&order, id).Error
    if err != nil {
        if errors.Is(err, gorm.ErrRecordNotFound) {
            return nil, ErrOrderNotFound
        }
        return nil, fmt.Errorf("query order id=%d: %w", id, err)
    }
    return &order, nil
}

// Service layer - wraps with business context
func (s *OrderService) GetOrder(ctx context.Context, id int64) (*OrderDTO, error) {
    order, err := s.repo.GetByID(ctx, id)
    if err != nil {
        return nil, fmt.Errorf("get order: %w", err)
    }
    return toDTO(order), nil
}

// Handler layer - translates to HTTP response
func (h *OrderHandler) Get(c *gin.Context) {
    order, err := h.svc.GetOrder(c.Request.Context(), id)
    if err != nil {
        if errors.Is(err, ErrOrderNotFound) {
            c.JSON(404, gin.H{"code": "ORDER_NOT_FOUND", "message": "order not found"})
            return
        }
        c.JSON(500, gin.H{"code": "INTERNAL_ERROR", "message": "internal error"})
        return
    }
    c.JSON(200, order)
}
```

## Sentinel Errors

Define at package level for errors that callers need to check:

```go
package order

var (
    ErrOrderNotFound   = errors.New("order not found")
    ErrOrderClosed     = errors.New("order already closed")
    ErrInsufficientQty = errors.New("insufficient quantity")
)
```

Rules:
- Use `errors.Is()` to compare, never `==`
- Prefix with `Err` by convention
- Only export errors that callers need to handle differently
- Keep the set small - not every error needs a sentinel

## Custom Error Types

For errors that carry structured data:

```go
type BusinessError struct {
    Code    int    `json:"code"`
    Message string `json:"message"`
    Detail  string `json:"detail,omitempty"`
}

func (e *BusinessError) Error() string {
    return fmt.Sprintf("[%d] %s", e.Code, e.Message)
}

func NewBusinessError(code int, message string) *BusinessError {
    return &BusinessError{Code: code, Message: message}
}

// Usage
func (s *Service) Pay(ctx context.Context, orderID int64) error {
    if order.Status != StatusPending {
        return &BusinessError{
            Code:    40001,
            Message: "order cannot be paid",
            Detail:  fmt.Sprintf("current status: %s", order.Status),
        }
    }
    return nil
}

// Checking
var bizErr *BusinessError
if errors.As(err, &bizErr) {
    c.JSON(http.StatusBadRequest, bizErr)
    return
}
```

## Error Code System

```go
// Package errcodes - centralized error code definitions
const (
    // Common: 10000-19999
    CodeSuccess       = 0
    CodeInternalError = 10001
    CodeInvalidParam  = 10002
    CodeUnauthorized  = 10003
    CodeForbidden     = 10004
    CodeNotFound      = 10005
    CodeTimeout       = 10006

    // Order: 20000-29999
    CodeOrderNotFound    = 20001
    CodeOrderClosed      = 20002
    CodeOrderPaidAlready = 20003

    // User: 30000-39999
    CodeUserNotFound   = 30001
    CodeUserDisabled   = 30002

    // Payment: 40000-49999
    CodePaymentFailed  = 40001
    CodeRefundFailed   = 40002
)

var codeMessages = map[int]string{
    CodeSuccess:       "success",
    CodeInternalError: "internal error",
    CodeInvalidParam:  "invalid parameter",
    // ...
}

func Message(code int) string {
    if msg, ok := codeMessages[code]; ok {
        return msg
    }
    return "unknown error"
}
```

## Error Handling Anti-Patterns

```go
// BAD: losing error context
if err != nil {
    return errors.New("failed") // original error lost
}

// GOOD: wrap with context
if err != nil {
    return fmt.Errorf("create order: %w", err)
}

// BAD: double wrapping same info
return fmt.Errorf("failed to create order: %w",
    fmt.Errorf("failed to create order: %w", err))

// BAD: logging AND returning (causes duplicate logs)
if err != nil {
    log.Error("failed", zap.Error(err))
    return err  // caller will also log
}

// GOOD: return error, let the top level log
if err != nil {
    return fmt.Errorf("create order: %w", err)
}

// BAD: panic in library/service code
func GetUser(id int) *User {
    u, err := db.Get(id)
    if err != nil {
        panic(err) // kills the process
    }
    return u
}

// GOOD: return error
func GetUser(id int) (*User, error) {
    u, err := db.Get(id)
    if err != nil {
        return nil, fmt.Errorf("get user %d: %w", id, err)
    }
    return u, nil
}
```

## Gin Error Response Convention

```go
// Unified API response
type Response struct {
    Code    int    `json:"code"`
    Message string `json:"message"`
    Data    any    `json:"data,omitempty"`
}

func Success(c *gin.Context, data any) {
    c.JSON(http.StatusOK, Response{Code: 0, Message: "success", Data: data})
}

func Fail(c *gin.Context, httpStatus int, code int, message string) {
    c.JSON(httpStatus, Response{Code: code, Message: message})
}

// Middleware to handle BusinessError
func ErrorHandler() gin.HandlerFunc {
    return func(c *gin.Context) {
        c.Next()
        if len(c.Errors) > 0 {
            err := c.Errors.Last().Err
            var bizErr *BusinessError
            if errors.As(err, &bizErr) {
                c.JSON(http.StatusBadRequest, Response{
                    Code: bizErr.Code, Message: bizErr.Message,
                })
                return
            }
            c.JSON(http.StatusInternalServerError, Response{
                Code: CodeInternalError, Message: "internal error",
            })
        }
    }
}
```

## Checklist

- [ ] Every error return adds context with `fmt.Errorf("...: %w", err)`
- [ ] Sentinel errors defined for caller-relevant distinctions
- [ ] `errors.Is()` / `errors.As()` used, never `==` or type assertion
- [ ] Error logged at one level only (usually handler/top-level)
- [ ] No silently discarded errors (`_ = fn()`)
- [ ] API errors use consistent code + message structure
- [ ] Panic only in truly unrecoverable situations (main init)
