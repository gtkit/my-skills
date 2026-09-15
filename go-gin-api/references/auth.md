# JWT 与 CORS 中间件

## JWT 中间件

```go
// Claims 复用 RegisteredClaims：sub 按 RFC 7519 是字符串，v5 解析数字 sub 会直接报错。
type Claims struct {
	Role string `json:"role"`
	jwt.RegisteredClaims
}

func JWT(secret []byte) gin.HandlerFunc {
	parser := jwt.NewParser(
		jwt.WithValidMethods([]string{jwt.SigningMethodHS256.Alg()}), // 不限定算法 = alg:none / RS→HS 混淆攻击入口
		jwt.WithLeeway(30*time.Second),                              // 容忍集群时钟偏差
		jwt.WithExpirationRequired(),
	)
	return func(c *gin.Context) {
		raw, ok := strings.CutPrefix(c.GetHeader("Authorization"), "Bearer ")
		if !ok || raw == "" { // TrimPrefix 不检查前缀存在，"Basic xxx" 也会被当 token 解析
			ginmw.Fail(c, apperror.ErrUnauthorized)
			return
		}
		claims := &Claims{}
		if _, err := parser.ParseWithClaims(raw, claims, func(*jwt.Token) (any, error) { return secret, nil }); err != nil {
			ginmw.Fail(c, apperror.Wrap(apperror.ErrUnauthorized, err)) // err 只进日志：客户端只看到 401
			return
		}
		c.Set(KeyUserID, claims.Subject)
		c.Set(KeyRole, claims.Role)
		c.Next()
	}
}
```

`RequireRole(roles ...string)`：`slices.Contains(roles, c.GetString(KeyRole))` 不成立则 `ginmw.Fail(c, apperror.ErrForbidden)`。刷新令牌轮换、`jti` 吊销见 go-security。

## CORS

`cors.New(cors.Config{AllowOrigins: origins, AllowMethods: [...], AllowHeaders: []string{"Authorization", "Content-Type", "Idempotency-Key"}, AllowCredentials: true, MaxAge: 12 * time.Hour})`。带 `Authorization` 的 API 绝不能 `Allow-Origin: *`；gin-contrib/cors 回显白名单 Origin 时自动附加 `Vary: Origin`，缺它时 CDN 会把 A 站的 CORS 头缓存给 B 站。`AllowAllOrigins` + `AllowCredentials` 库不拦（v1.7.7 `Validate` 只查 origin 配置冲突），会同时发出 `Allow-Origin: *` 与 `Allow-Credentials: true`，浏览器直接拒绝带凭证的响应；`AllowOrigins` 写完整 scheme+host。
