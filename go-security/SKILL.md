---
name: go-security
description: Go secure coding practices for web applications. Covers SQL injection, XSS, CSRF, JWT best practices, input validation, secrets management, and OWASP top 10 mitigations.
allowed-tools: "Read, Write, Edit, Bash, Glob, Grep"
---

# Go Secure Coding Practices

## SQL Injection Prevention

### Always Use Parameterized Queries
```go
// BAD: SQL injection
db.Raw("SELECT * FROM users WHERE name = '" + name + "'").Scan(&users)
db.Where("name = " + name).Find(&users)

// GOOD: parameterized
db.Where("name = ?", name).Find(&users)
db.Raw("SELECT * FROM users WHERE name = ?", name).Scan(&users)

// GOOD: struct-based (GORM escapes automatically)
db.Where(&User{Name: name}).Find(&users)
```

### LIKE Queries
```go
// BAD: injection via LIKE
db.Where("name LIKE '%" + input + "%'").Find(&users)

// GOOD: parameterized LIKE
db.Where("name LIKE ?", "%"+input+"%").Find(&users)
```

### IN Queries
```go
// GOOD: GORM handles slice parameters
db.Where("id IN ?", ids).Find(&users)
```

### Raw SQL - Extra Care
```go
// If you must use raw SQL, ALWAYS parameterize
db.Exec("UPDATE orders SET status = ? WHERE id = ? AND user_id = ?",
    status, orderID, userID)
```

## XSS Prevention

### Output Encoding
```go
// In HTML templates, use html/template (auto-escapes)
import "html/template"

// For JSON API responses, Go's json.Marshal escapes HTML by default

// For user-generated content stored in DB:
import "github.com/microcosm-cc/bluemonday"
p := bluemonday.UGCPolicy()
safeHTML := p.Sanitize(userInput)
```

### Content-Type Headers
```go
// Always set correct content type
c.Header("Content-Type", "application/json; charset=utf-8")
c.Header("X-Content-Type-Options", "nosniff")
```

## CSRF Protection

```go
// For cookie-based auth, use CSRF tokens
// For JWT in Authorization header, CSRF is not needed (browser won't auto-send)

// If using cookies:
func CSRFMiddleware() gin.HandlerFunc {
    return func(c *gin.Context) {
        if c.Request.Method != "GET" && c.Request.Method != "HEAD" {
            token := c.GetHeader("X-CSRF-Token")
            expected := getCSRFToken(c)
            if !hmac.Equal([]byte(token), []byte(expected)) {
                c.AbortWithStatusJSON(403, gin.H{"error": "CSRF validation failed"})
                return
            }
        }
        c.Next()
    }
}
```

## JWT Security

### Token Generation
```go
func GenerateToken(userID int64, role string) (string, error) {
    now := time.Now()
    claims := jwt.MapClaims{
        "sub":  userID,
        "role": role,
        "iat":  now.Unix(),
        "exp":  now.Add(2 * time.Hour).Unix(), // short-lived
        "jti":  uuid.New().String(),            // unique ID for revocation
    }
    token := jwt.NewWithClaims(jwt.SigningMethodHS256, claims)
    return token.SignedString([]byte(secretKey))
}
```

### Token Validation
```go
func ValidateToken(tokenString string) (*Claims, error) {
    token, err := jwt.Parse(tokenString, func(token *jwt.Token) (interface{}, error) {
        // CRITICAL: verify signing method
        if _, ok := token.Method.(*jwt.SigningMethodHMAC); !ok {
            return nil, fmt.Errorf("unexpected signing method: %v", token.Header["alg"])
        }
        return []byte(secretKey), nil
    })
    if err != nil {
        return nil, fmt.Errorf("parse token: %w", err)
    }
    if !token.Valid {
        return nil, errors.New("invalid token")
    }
    // ... extract claims
}
```

### JWT Checklist
- [ ] Always verify signing algorithm (`alg`) matches expected
- [ ] Use strong secret (256+ bits for HMAC, RSA 2048+ for RSA)
- [ ] Set reasonable expiration (access: 15min-2h, refresh: 7-30d)
- [ ] Include `jti` claim for token revocation support
- [ ] Never store sensitive data in JWT payload (it's base64, not encrypted)
- [ ] Refresh token rotation: issue new refresh token on each refresh
- [ ] Secret key loaded from environment, never hardcoded

## Input Validation

### Handler Level Validation
```go
type CreateOrderReq struct {
    ProductID int64   `json:"product_id" binding:"required,gt=0"`
    Quantity  int     `json:"quantity" binding:"required,min=1,max=999"`
    Price     float64 `json:"price" binding:"required,gt=0"`
    Remark    string  `json:"remark" binding:"max=500"`
}

func (h *Handler) CreateOrder(c *gin.Context) {
    var req CreateOrderReq
    if err := c.ShouldBindJSON(&req); err != nil {
        c.JSON(400, gin.H{"error": "invalid parameters"})
        return
    }
    // req is now validated
}
```

### Path Parameter Validation
```go
// Always validate path parameters
id, err := strconv.ParseInt(c.Param("id"), 10, 64)
if err != nil || id <= 0 {
    c.JSON(400, gin.H{"error": "invalid id"})
    return
}
```

### Sanitize Before Storage
- Strip HTML tags from text fields
- Normalize Unicode (NFC)
- Trim whitespace
- Validate email format with regexp
- Validate phone number format

## Secrets Management

### Environment Variables
```go
// GOOD: from environment
dbPassword := os.Getenv("DB_PASSWORD")
jwtSecret := os.Getenv("JWT_SECRET")

// BAD: hardcoded
const jwtSecret = "my-secret-key"
const dbPassword = "password123"
```

### Never Log Secrets
```go
// BAD
log.Printf("connecting to db with password: %s", password)
log.Printf("token: %s", token)

// GOOD
log.Printf("connecting to db host=%s dbname=%s", host, dbname)
log.Printf("token validated for user_id=%d", userID)
```

### Never Return Secrets in API
```go
type UserResponse struct {
    ID    int64  `json:"id"`
    Name  string `json:"name"`
    Email string `json:"email"`
    // Password string `json:"-"` <- exclude with json:"-"
}
```

## Security Headers

```go
func SecurityHeaders() gin.HandlerFunc {
    return func(c *gin.Context) {
        c.Header("X-Content-Type-Options", "nosniff")
        c.Header("X-Frame-Options", "DENY")
        c.Header("X-XSS-Protection", "1; mode=block")
        c.Header("Strict-Transport-Security", "max-age=31536000; includeSubDomains")
        c.Header("Cache-Control", "no-store")
        c.Header("Referrer-Policy", "strict-origin-when-cross-origin")
        c.Next()
    }
}
```

## Rate Limiting

```go
import "golang.org/x/time/rate"

func RateLimiter(rps int, burst int) gin.HandlerFunc {
    limiters := sync.Map{}
    return func(c *gin.Context) {
        ip := c.ClientIP()
        l, _ := limiters.LoadOrStore(ip, rate.NewLimiter(rate.Limit(rps), burst))
        if !l.(*rate.Limiter).Allow() {
            c.AbortWithStatusJSON(429, gin.H{"error": "too many requests"})
            return
        }
        c.Next()
    }
}
```

## Security Checklist

- [ ] All SQL uses parameterized queries
- [ ] User input validated at handler boundary
- [ ] JWT algorithm verified on parse
- [ ] No secrets in code, logs, or API responses
- [ ] Security headers set on all responses
- [ ] Rate limiting on auth and public endpoints
- [ ] HTTPS enforced in production
- [ ] Passwords hashed with bcrypt (cost >= 10)
- [ ] File upload: validate type, limit size, no path traversal
- [ ] CORS configured for specific origins, not wildcard
