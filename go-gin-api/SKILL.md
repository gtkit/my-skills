---
name: go-gin-api
description: Build production-grade REST APIs with Go Gin framework. Use this skill whenever the user mentions Gin, REST API in Go, HTTP handlers, middleware, routing, JSON responses, request validation, or any Go web server development. Also trigger when the user asks about Go API architecture, request/response handling, error handling patterns, or authentication middleware in Go.
---

# Go Gin API Patterns

Production-ready patterns for building REST APIs with the Gin web framework in Go.

## When to Use This Skill

- Building REST APIs with Gin
- Designing middleware chains
- Handling JSON request/response
- Implementing request validation
- Structuring Go API projects
- Error handling in HTTP handlers
- Authentication and authorization middleware

## Project Structure

```
project/
├── cmd/
│   └── server/
│       └── main.go          # Entry point
├── internal/
│   ├── handler/             # HTTP handlers
│   │   ├── user.go
│   │   └── order.go
│   ├── middleware/           # Custom middleware
│   │   ├── auth.go
│   │   ├── cors.go
│   │   ├── ratelimit.go
│   │   └── logger.go
│   ├── model/               # Data models
│   │   ├── user.go
│   │   └── order.go
│   ├── service/             # Business logic
│   │   ├── user.go
│   │   └── order.go
│   ├── repository/          # Data access
│   │   ├── user.go
│   │   └── order.go
│   └── dto/                 # Request/Response DTOs
│       ├── request.go
│       └── response.go
├── pkg/
│   ├── apperror/            # Custom errors
│   │   └── error.go
│   └── response/            # Unified response
│       └── response.go
└── config/
    └── config.go
```

## Core Patterns

### 1. Unified JSON Response

```go
package response

import (
    "net/http"
    "github.com/gin-gonic/gin"
)

type Response struct {
    Code    int         `json:"code"`
    Message string      `json:"message"`
    Data    interface{} `json:"data,omitempty"`
}

type PagedResponse struct {
    Response
    Meta PageMeta `json:"meta,omitempty"`
}

type PageMeta struct {
    Page      int   `json:"page"`
    PerPage   int   `json:"per_page"`
    Total     int64 `json:"total"`
    TotalPage int   `json:"total_page"`
}

func OK(c *gin.Context, data interface{}) {
    c.JSON(http.StatusOK, Response{
        Code:    0,
        Message: "success",
        Data:    data,
    })
}

func Created(c *gin.Context, data interface{}) {
    c.JSON(http.StatusCreated, Response{
        Code:    0,
        Message: "created",
        Data:    data,
    })
}

func Error(c *gin.Context, httpStatus int, code int, message string) {
    c.AbortWithStatusJSON(httpStatus, Response{
        Code:    code,
        Message: message,
    })
}

func Paged(c *gin.Context, data interface{}, page, perPage int, total int64) {
    totalPage := int(total) / perPage
    if int(total)%perPage > 0 {
        totalPage++
    }
    c.JSON(http.StatusOK, PagedResponse{
        Response: Response{Code: 0, Message: "success", Data: data},
        Meta: PageMeta{
            Page:      page,
            PerPage:   perPage,
            Total:     total,
            TotalPage: totalPage,
        },
    })
}
```

### 2. Custom Error Handling

```go
package apperror

import "fmt"

type AppError struct {
    Code    int    `json:"code"`
    Message string `json:"message"`
    HTTP    int    `json:"-"`
    Err     error  `json:"-"`
}

func (e *AppError) Error() string {
    if e.Err != nil {
        return fmt.Sprintf("[%d] %s: %v", e.Code, e.Message, e.Err)
    }
    return fmt.Sprintf("[%d] %s", e.Code, e.Message)
}

func (e *AppError) Unwrap() error { return e.Err }

// Predefined errors
var (
    ErrNotFound       = &AppError{Code: 1001, Message: "resource not found", HTTP: 404}
    ErrUnauthorized   = &AppError{Code: 1002, Message: "unauthorized", HTTP: 401}
    ErrForbidden      = &AppError{Code: 1003, Message: "forbidden", HTTP: 403}
    ErrBadRequest     = &AppError{Code: 1004, Message: "bad request", HTTP: 400}
    ErrInternal       = &AppError{Code: 1005, Message: "internal server error", HTTP: 500}
    ErrConflict       = &AppError{Code: 1006, Message: "resource conflict", HTTP: 409}
    ErrTooManyReqs    = &AppError{Code: 1007, Message: "too many requests", HTTP: 429}
)

func Wrap(base *AppError, err error) *AppError {
    return &AppError{
        Code:    base.Code,
        Message: base.Message,
        HTTP:    base.HTTP,
        Err:     err,
    }
}

func WithMessage(base *AppError, msg string) *AppError {
    return &AppError{
        Code:    base.Code,
        Message: msg,
        HTTP:    base.HTTP,
        Err:     base.Err,
    }
}
```

### 3. Error Recovery Middleware

```go
package middleware

import (
    "errors"
    "net/http"
    "github.com/gin-gonic/gin"
    "yourapp/pkg/apperror"
    "yourapp/pkg/response"
    "go.uber.org/zap"
)

func ErrorHandler(logger *zap.Logger) gin.HandlerFunc {
    return func(c *gin.Context) {
        c.Next()

        if len(c.Errors) == 0 {
            return
        }

        err := c.Errors.Last().Err
        var appErr *apperror.AppError

        if errors.As(err, &appErr) {
            if appErr.HTTP >= 500 {
                logger.Error("server error",
                    zap.Error(appErr),
                    zap.String("path", c.Request.URL.Path),
                )
            }
            response.Error(c, appErr.HTTP, appErr.Code, appErr.Message)
        } else {
            logger.Error("unhandled error",
                zap.Error(err),
                zap.String("path", c.Request.URL.Path),
            )
            response.Error(c, http.StatusInternalServerError, 9999, "internal server error")
        }
    }
}

func Recovery(logger *zap.Logger) gin.HandlerFunc {
    return func(c *gin.Context) {
        defer func() {
            if r := recover(); r != nil {
                logger.Error("panic recovered",
                    zap.Any("error", r),
                    zap.String("path", c.Request.URL.Path),
                )
                response.Error(c, http.StatusInternalServerError, 9999, "internal server error")
            }
        }()
        c.Next()
    }
}
```

### 4. Request Validation with Binding

```go
package dto

import (
    "github.com/gin-gonic/gin"
    "github.com/go-playground/validator/v10"
)

// Request DTOs with validation tags
type CreateUserReq struct {
    Name     string `json:"name" binding:"required,min=2,max=50"`
    Email    string `json:"email" binding:"required,email"`
    Password string `json:"password" binding:"required,min=8"`
    Role     string `json:"role" binding:"required,oneof=admin user moderator"`
    Age      int    `json:"age" binding:"omitempty,gte=0,lte=150"`
}

type UpdateUserReq struct {
    Name  *string `json:"name" binding:"omitempty,min=2,max=50"`
    Email *string `json:"email" binding:"omitempty,email"`
    Role  *string `json:"role" binding:"omitempty,oneof=admin user moderator"`
}

type ListReq struct {
    Page    int    `form:"page" binding:"omitempty,min=1"`
    PerPage int    `form:"per_page" binding:"omitempty,min=1,max=100"`
    Sort    string `form:"sort" binding:"omitempty,oneof=created_at updated_at name"`
    Order   string `form:"order" binding:"omitempty,oneof=asc desc"`
    Search  string `form:"search" binding:"omitempty,max=100"`
}

func (r *ListReq) Defaults() {
    if r.Page == 0 { r.Page = 1 }
    if r.PerPage == 0 { r.PerPage = 20 }
    if r.Sort == "" { r.Sort = "created_at" }
    if r.Order == "" { r.Order = "desc" }
}

// Custom validator registration
func RegisterCustomValidators(v *validator.Validate) {
    v.RegisterValidation("phone", func(fl validator.FieldLevel) bool {
        // Custom phone validation
        phone := fl.Field().String()
        return len(phone) >= 10 && len(phone) <= 15
    })
}

// Validation error formatting
func FormatValidationErrors(err error) map[string]string {
    errs := make(map[string]string)
    if ve, ok := err.(validator.ValidationErrors); ok {
        for _, fe := range ve {
            errs[fe.Field()] = formatFieldError(fe)
        }
    }
    return errs
}

func formatFieldError(fe validator.FieldError) string {
    switch fe.Tag() {
    case "required":
        return "this field is required"
    case "email":
        return "invalid email format"
    case "min":
        return "value is too short"
    case "max":
        return "value is too long"
    default:
        return "invalid value"
    }
}
```

### 5. Handler Pattern

```go
package handler

import (
    "net/http"
    "strconv"
    "github.com/gin-gonic/gin"
    "yourapp/internal/dto"
    "yourapp/internal/service"
    "yourapp/pkg/apperror"
    "yourapp/pkg/response"
)

type UserHandler struct {
    userSvc service.UserService
}

func NewUserHandler(userSvc service.UserService) *UserHandler {
    return &UserHandler{userSvc: userSvc}
}

func (h *UserHandler) Create(c *gin.Context) {
    var req dto.CreateUserReq
    if err := c.ShouldBindJSON(&req); err != nil {
        response.Error(c, http.StatusBadRequest, 1004, err.Error())
        return
    }

    user, err := h.userSvc.Create(c.Request.Context(), &req)
    if err != nil {
        c.Error(err) // Let error middleware handle it
        return
    }

    response.Created(c, user)
}

func (h *UserHandler) GetByID(c *gin.Context) {
    id, err := strconv.ParseInt(c.Param("id"), 10, 64)
    if err != nil {
        response.Error(c, http.StatusBadRequest, 1004, "invalid id")
        return
    }

    user, err := h.userSvc.GetByID(c.Request.Context(), id)
    if err != nil {
        c.Error(err)
        return
    }

    response.OK(c, user)
}

func (h *UserHandler) List(c *gin.Context) {
    var req dto.ListReq
    if err := c.ShouldBindQuery(&req); err != nil {
        response.Error(c, http.StatusBadRequest, 1004, err.Error())
        return
    }
    req.Defaults()

    users, total, err := h.userSvc.List(c.Request.Context(), &req)
    if err != nil {
        c.Error(err)
        return
    }

    response.Paged(c, users, req.Page, req.PerPage, total)
}
```

### 6. Router Setup

```go
package main

import (
    "github.com/gin-gonic/gin"
    "yourapp/internal/handler"
    "yourapp/internal/middleware"
)

func SetupRouter(
    userHandler *handler.UserHandler,
    authMW gin.HandlerFunc,
    logger *zap.Logger,
) *gin.Engine {
    r := gin.New()

    // Global middleware
    r.Use(middleware.Recovery(logger))
    r.Use(middleware.ErrorHandler(logger))
    r.Use(middleware.RequestLogger(logger))
    r.Use(middleware.CORS())

    // Health check
    r.GET("/health", func(c *gin.Context) {
        c.JSON(200, gin.H{"status": "ok"})
    })

    // API v1
    v1 := r.Group("/api/v1")
    {
        // Public routes
        v1.POST("/auth/login", authHandler.Login)
        v1.POST("/auth/register", authHandler.Register)

        // Protected routes
        protected := v1.Group("")
        protected.Use(authMW)
        {
            users := protected.Group("/users")
            {
                users.GET("", userHandler.List)
                users.POST("", userHandler.Create)
                users.GET("/:id", userHandler.GetByID)
                users.PUT("/:id", userHandler.Update)
                users.DELETE("/:id", userHandler.Delete)
            }
        }
    }

    return r
}
```

### 7. Authentication Middleware (JWT)

```go
package middleware

import (
    "net/http"
    "strings"
    "github.com/gin-gonic/gin"
    "github.com/golang-jwt/jwt/v5"
    "yourapp/pkg/response"
)

type Claims struct {
    UserID int64  `json:"user_id"`
    Role   string `json:"role"`
    jwt.RegisteredClaims
}

func JWTAuth(secret string) gin.HandlerFunc {
    return func(c *gin.Context) {
        authHeader := c.GetHeader("Authorization")
        if authHeader == "" {
            response.Error(c, http.StatusUnauthorized, 1002, "missing authorization header")
            return
        }

        tokenString := strings.TrimPrefix(authHeader, "Bearer ")
        claims := &Claims{}

        token, err := jwt.ParseWithClaims(tokenString, claims, func(t *jwt.Token) (interface{}, error) {
            return []byte(secret), nil
        })

        if err != nil || !token.Valid {
            response.Error(c, http.StatusUnauthorized, 1002, "invalid token")
            return
        }

        c.Set("user_id", claims.UserID)
        c.Set("role", claims.Role)
        c.Next()
    }
}

func RequireRole(roles ...string) gin.HandlerFunc {
    return func(c *gin.Context) {
        role, _ := c.Get("role")
        roleStr, _ := role.(string)

        for _, r := range roles {
            if r == roleStr {
                c.Next()
                return
            }
        }

        response.Error(c, http.StatusForbidden, 1003, "insufficient permissions")
    }
}
```

### 8. Rate Limiting Middleware

```go
package middleware

import (
    "net/http"
    "sync"
    "time"
    "github.com/gin-gonic/gin"
    "golang.org/x/time/rate"
    "yourapp/pkg/response"
)

type RateLimiter struct {
    visitors map[string]*rate.Limiter
    mu       sync.RWMutex
    rate     rate.Limit
    burst    int
}

func NewRateLimiter(r rate.Limit, burst int) *RateLimiter {
    rl := &RateLimiter{
        visitors: make(map[string]*rate.Limiter),
        rate:     r,
        burst:    burst,
    }
    // Cleanup stale entries
    go rl.cleanup()
    return rl
}

func (rl *RateLimiter) getLimiter(key string) *rate.Limiter {
    rl.mu.Lock()
    defer rl.mu.Unlock()

    if limiter, exists := rl.visitors[key]; exists {
        return limiter
    }

    limiter := rate.NewLimiter(rl.rate, rl.burst)
    rl.visitors[key] = limiter
    return limiter
}

func (rl *RateLimiter) cleanup() {
    for {
        time.Sleep(time.Minute)
        rl.mu.Lock()
        rl.visitors = make(map[string]*rate.Limiter)
        rl.mu.Unlock()
    }
}

func RateLimit(rl *RateLimiter) gin.HandlerFunc {
    return func(c *gin.Context) {
        key := c.ClientIP()
        limiter := rl.getLimiter(key)

        if !limiter.Allow() {
            response.Error(c, http.StatusTooManyRequests, 1007, "rate limit exceeded")
            return
        }
        c.Next()
    }
}
```

### 9. CORS Middleware

```go
package middleware

import (
    "github.com/gin-gonic/gin"
)

func CORS() gin.HandlerFunc {
    return func(c *gin.Context) {
        c.Header("Access-Control-Allow-Origin", "*")
        c.Header("Access-Control-Allow-Methods", "GET, POST, PUT, PATCH, DELETE, OPTIONS")
        c.Header("Access-Control-Allow-Headers", "Origin, Content-Type, Authorization")
        c.Header("Access-Control-Max-Age", "86400")

        if c.Request.Method == "OPTIONS" {
            c.AbortWithStatus(204)
            return
        }
        c.Next()
    }
}
```

### 10. Request Logger Middleware

```go
package middleware

import (
    "time"
    "github.com/gin-gonic/gin"
    "go.uber.org/zap"
)

func RequestLogger(logger *zap.Logger) gin.HandlerFunc {
    return func(c *gin.Context) {
        start := time.Now()
        path := c.Request.URL.Path
        query := c.Request.URL.RawQuery

        c.Next()

        latency := time.Since(start)
        status := c.Writer.Status()

        fields := []zap.Field{
            zap.Int("status", status),
            zap.String("method", c.Request.Method),
            zap.String("path", path),
            zap.String("query", query),
            zap.String("ip", c.ClientIP()),
            zap.Duration("latency", latency),
            zap.Int("body_size", c.Writer.Size()),
        }

        if status >= 500 {
            logger.Error("server error", fields...)
        } else if status >= 400 {
            logger.Warn("client error", fields...)
        } else {
            logger.Info("request", fields...)
        }
    }
}
```

## Best Practices

### Do's
- **Use ShouldBind** over MustBind for better error control
- **Pass context** via `c.Request.Context()` to downstream services
- **Use c.Error()** with error middleware instead of inline error responses
- **Group routes** by version and authentication requirements
- **Use pointer fields** in update DTOs for partial updates
- **Set default values** for pagination parameters

### Don'ts
- **Don't use gin.Default()** in production — build your own middleware stack
- **Don't block in handlers** — use goroutines for long tasks with proper context
- **Don't return raw DB errors** — map them to AppError
- **Don't hardcode config** — use environment variables or config files
- **Don't skip request validation** — always validate and sanitize input
