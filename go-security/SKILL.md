---
name: go-security
description: Go Web 服务安全编码规范：TLS 与 http.Server 硬化、JWT（golang-jwt/jwt/v5，kid 轮换）、argon2id/bcrypt 密码存储、IDOR 与 mass assignment、注入与输出编码、SSRF 安全客户端、JSON/zip/yaml 解析炸弹、安全响应头与 CSP、CSRF、crypto/rand 与 secret 管理、govulncheck 供应链扫描。用户提到 Go 安全、鉴权、JWT、OWASP、XSS、CSRF、SSRF、密码哈希、TLS、secret、漏洞扫描时触发。限流与熔断见 go-stability-engineering，SQL 参数化与列名白名单见 go-database-patterns，CI 门禁流程见 go-engineering-governance。
allowed-tools: "Read, Write, Edit, Bash, Glob, Grep"
---

# Go 安全编码

按"传输 → 入口 → 应用 → 数据 → 供应链"分层给规则与代码。限流/熔断在 go-stability-engineering，SQL 参数化与排序列白名单在 go-database-patterns，错误响应格式在 go-error-handling，HTTP 服务器完整 main 在 go-gin-api，govulncheck/gosec 接入 CI 的流程在 go-engineering-governance。

## 核心规则

1. 公网监听的 `http.Server` 必须设 `ReadHeaderTimeout`；每个收 body 的路由必须经 `http.MaxBytesReader`。缺任一项就是 Slowloris / 大包 DoS 面。
2. JWT 只用 `github.com/golang-jwt/jwt/v5`；解析必带 `jwt.WithValidMethods`；`sub` 是字符串；密钥带 `kid`，轮换靠多密钥并存。
3. 密码只存 argon2id（或 bcrypt cost ≥ 12）哈希；密文/签名/token 比较一律 `subtle.ConstantTimeCompare`。
4. 按 ID 取资源的 SQL 必须带所有者或租户列；请求体只绑定到 DTO，禁止绑到含 `Role`/`IsAdmin` 的 model。
5. 用户输入存原文，输出时按上下文编码；禁止"入库前剥离 HTML"——它破坏合法内容且对 JSON/SQL/HTML 三种下游只防了一种。
6. 以用户提供的 URL 发起出站请求必须走 SSRF 安全客户端：IP 校验放在 `DialContext`，不放在 URL 解析阶段。
7. 不设 `X-XSS-Protection`；设 CSP、`X-Content-Type-Options: nosniff`、HSTS、`Referrer-Policy`；`Cache-Control: no-store` 只加在敏感接口。
8. Cookie 会话必须 `SameSite=Lax/Strict` 并挂 CSRF 中间件（放行 `OPTIONS`）；纯 Bearer API 不挂。
9. 安全随机数只用 `crypto/rand`；secret 用 `os.LookupEnv` 读取、缺失即 fail-fast；日志脱敏靠 gtkit `WithRedactKeys`。
10. 5xx 不回显 `err.Error()`（见 go-error-handling）；登录、找回密码对"用户不存在"与"密码错误"返回同一状态码、同一文案、同一耗时量级。
11. 每次 CI 跑 `govulncheck ./...`；金额字段 `int64`（分）或 decimal，禁 float。

## 传输层：TLS 与服务器硬化

Go 1.22+ 服务端与客户端默认最小版本已是 TLS 1.2（`go doc crypto/tls Config.MinVersion`），显式写出是为了让 gosec G402 与代码审查能核对。`InsecureSkipVerify: true` 只允许出现在测试文件；生产要连私有 CA 用 `RootCAs`。mTLS 用于服务间调用：`ClientAuth: tls.RequireAndVerifyClientCert` + `ClientCAs`，证书 SAN 即调用方身份，不再另发 token。

```go
func ServerTLS() *tls.Config {
	return &tls.Config{
		MinVersion: tls.VersionTLS12,
		CipherSuites: []uint16{
			tls.TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256,
			tls.TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256,
			tls.TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305,
			tls.TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305,
		},
	}
}

func OutboundClient(rootCAs *x509.CertPool) *http.Client {
	tr := http.DefaultTransport.(*http.Transport).Clone()
	tr.TLSClientConfig = &tls.Config{MinVersion: tls.VersionTLS12, RootCAs: rootCAs}
	return &http.Client{Transport: tr, Timeout: 10 * time.Second}
}
```

四个超时字段各防一种慢速攻击：`ReadHeaderTimeout` 防头部慢发（Slowloris），`ReadTimeout` 防 body 慢发，`WriteTimeout` 防慢读，`IdleTimeout` 防 keep-alive 占坑。`MaxBytesReader` 超限后 Bind 返回 `*http.MaxBytesError`，用 `errors.AsType[*http.MaxBytesError](err)` 映射为 413；`MaxMultipartMemory` 只决定多大以后落盘临时文件，不是上限。

```go
func NewServer(h http.Handler) *http.Server {
	return &http.Server{
		Addr:              ":8080",
		Handler:           h,
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       15 * time.Second,
		WriteTimeout:      30 * time.Second, // SSE/长连接路由见 go-websocket-sse
		IdleTimeout:       60 * time.Second,
		MaxHeaderBytes:    64 << 10, // 默认 DefaultMaxHeaderBytes = 1 MiB
		TLSConfig:         ServerTLS(),
	}
}

func BodyLimit(n int64) gin.HandlerFunc {
	return func(c *gin.Context) {
		c.Request.Body = http.MaxBytesReader(c.Writer, c.Request.Body, n)
		c.Next()
	}
}

func Router() *gin.Engine {
	r := gin.New()
	r.MaxMultipartMemory = 8 << 20                                      // 超出部分落盘临时文件，不是拒绝；拒绝靠 BodyLimit
	if err := r.SetTrustedProxies([]string{"10.0.0.0/8"}); err != nil { // 不设则任何人可用 X-Forwarded-For 伪造 ClientIP
		logger.Fatal("trusted proxies", zap.Error(err))
	}
	r.Use(BodyLimit(maxBodyBytes))
	return r
}
```

## 入口层：认证

### JWT（golang-jwt/jwt/v5）

`MapClaims` 里写 `"sub": userID`（int64）是最常见错误：RFC 7519 规定 `sub` 为 StringOrURI，v5 用 `RegisteredClaims` 解析时直接失败（Go 1.27 实测报 `token is malformed: could not JSON decode claim`），用 `MapClaims.GetSubject()` 则报 `invalid type for claim: sub is invalid`。`WithValidMethods` 拒绝 `alg=none`（实测 `token signature is invalid: signing method none is invalid`）与 RS256 公钥被当 HS256 密钥的算法混淆。

```go
type Claims struct {
	jwt.RegisteredClaims
	Role     string `json:"role,omitempty"`
	TenantID string `json:"tid,omitempty"`
}

type KeySet struct {
	Current   string
	Keys      map[string][]byte // HS256 每把 ≥ 32 字节
	Issuer    string
	Audience  string
	AccessTTL time.Duration // ≤ 15 分钟：吊销靠短寿命 + refresh 轮换，不靠查黑名单
}

	t := jwt.NewWithClaims(jwt.SigningMethodHS256, c)
	t.Header["kid"] = k.Current
	return t.SignedString(k.Keys[k.Current])

func (k *KeySet) keyFunc(t *jwt.Token) (any, error) {
	kid, _ := t.Header["kid"].(string)
	key, ok := k.Keys[kid]
	if !ok {
		return nil, fmt.Errorf("unknown kid %q", kid)
	}
	return key, nil
}

func (k *KeySet) Parse(raw string) (*Claims, error) {
	var c Claims
	_, err := jwt.ParseWithClaims(raw, &c, k.keyFunc,
		jwt.WithValidMethods([]string{jwt.SigningMethodHS256.Alg()}), // 拒绝 alg=none 与 RS→HS 密钥混淆
		jwt.WithExpirationRequired(),
		jwt.WithIssuer(k.Issuer),
		jwt.WithAudience(k.Audience),
		jwt.WithLeeway(30*time.Second), // 只吸收时钟漂移，不是宽限期
	)
	if err != nil {
		return nil, err // errors.Is(err, jwt.ErrTokenExpired) 可区分过期与伪造
	}
	return &c, nil
}
```

Refresh token 轮换规则（实现骨架见 build 的 `auth/refresh.go`）：refresh 是不透明随机串（`rand.Text()`），服务端只存 SHA-256；每次使用原子地"取出并删除"再签发新对（`Take` 语义）；已被消费的旧 token 再次出现说明泄露，吊销整条 family 而不只是这一枚。Access token 寿命 ≤ 15 分钟时不需要黑名单查库；确需即时吊销，按 `jti` 写 Redis `SET EX 剩余寿命`。

### 密码与比较

参数取 RFC 9106 第二推荐档（t=3、m=64 MiB、p=4）；第一档 m=2 GiB 在并发登录下会把服务打成 OOM。bcrypt 若仍在用：cost ≥ 12，且 `x/crypto/bcrypt` 对超过 72 字节的密码直接返回 `ErrPasswordTooLong`——前端不限长的 passphrase 用户会在注册时失败。

```go
func HashPassword(pw string) (string, error) {
	salt := make([]byte, saltLen)
	if _, err := rand.Read(salt); err != nil {
		return "", err
	}
	key := argon2.IDKey([]byte(pw), salt, argonTime, argonMemory, argonThreads, argonKeyLen)
	return fmt.Sprintf("$argon2id$v=%d$m=%d,t=%d,p=%d$%s$%s", argon2.Version, argonMemory, argonTime, argonThreads,
		base64.RawStdEncoding.EncodeToString(salt), base64.RawStdEncoding.EncodeToString(key)), nil
}

	got := argon2.IDKey([]byte(pw), salt, t, m, p, uint32(len(want)))
	return subtle.ConstantTimeCompare(got, want) == 1, nil // bytes.Equal 会泄漏前缀匹配长度

// dummyHash：用户不存在时也跑一次完整 argon2，让两条路径耗时一致。
var dummyHash = sync.OnceValue(func() string { h, _ := HashPassword(rand.Text()); return h })

func (s *Service) Login(ctx context.Context, email, pw string) (*User, error) {
	u, err := s.repo.FindByEmail(ctx, email)
	hash := dummyHash()
	if err == nil && u != nil { // 仓储实现若用 (nil, nil) 表示未找到，少了 u != nil 就是登录接口上的空指针 panic
		hash = u.PasswordHash
	}
	ok, verr := VerifyPassword(hash, pw)
	if err != nil || verr != nil || !ok {
		return nil, ErrInvalidCredentials
	}
	return u, nil
}
```

## 入口层：授权

IDOR 是业务系统实际漏洞第一位：`GET /orders/:id` 只按 id 查，换个数字就看到别人的订单。规则是查询条件必须同时含资源 ID 与当前主体（用户或租户）列，且越权与不存在返回同一错误——返回 403 等于告诉攻击者"存在但不是你的"。

```go
func (r *OrderRepo) GetForUser(ctx context.Context, orderID, userID int64) (*Order, error) {
	const q = `SELECT id, user_id, amount_cents, status FROM orders WHERE id = $1 AND user_id = $2`
	var o Order
	err := r.db.QueryRowContext(ctx, q, orderID, userID).Scan(&o.ID, &o.UserID, &o.AmountCents, &o.Status)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, fmt.Errorf("get order %d: %w", orderID, err)
	}
	return &o, nil
}

// UpdateProfileReq：只含客户端可改字段。反例 c.ShouldBindJSON(&user)——User 含 Role/IsAdmin，多传一个字段即提权。
type UpdateProfileReq struct {
	Nickname string `json:"nickname" binding:"required,max=32"`
	Bio      string `json:"bio" binding:"max=500"`
}
```

## 应用层：输入与输出

- 注入：参数化查询与列名白名单见 go-database-patterns；`fmt.Sprintf` 拼任何 SQL 片段都是缺陷。
- 输出编码：`html/template` 按位置选转义器（文本节点 HTML 转义，`href` 查询串 URL 转义，`<script>` 内 JS 转义），`text/template` 一个都没有；`encoding/json` 默认把 `<`、`>`、`&` 转成 `\u003c` 等，`SetEscapeHTML(false)` 只用于非浏览器消费方。
- 邮箱用 `net/mail.ParseAddress`，正则校验邮箱是经典反模式；路径用 `filepath.IsLocal`（Go 1.20，词法）+ `os.Root`（Go 1.24，运行时含符号链接）双重拦截。

```go
var page = template.Must(template.New("p").Parse(`<p>{{.Comment}}</p><a href="/search?q={{.Query}}">再搜</a>`))

func ValidEmail(s string) (string, error) {
	addr, err := mail.ParseAddress(s)
	if err != nil || addr.Name != "" {
		return "", ErrBadEmail
	}
	return addr.Address, nil
}

func OpenUpload(baseDir, name string) (*os.File, error) {
	if !filepath.IsLocal(name) { // 拒绝 ""、绝对路径、"../x"、Windows 保留名
		return nil, ErrBadPath
	}
	root, err := os.OpenRoot(baseDir)
	if err != nil {
		return nil, err
	}
	defer root.Close()
	return root.Open(name) // 链接指向 root 之外时返回错误
}
```

### SSRF

流程：入口只接受 `http/https` 且有 Host → 解析出全部 IP → 任一命中 loopback / 私网 / 100.64.0.0/10（`IsPrivate` 不含，阿里云元数据在此段）/ 链路本地（169.254.169.254）/ 多播 / 未指定即拒绝 → 连接刚校验过的那个 IP → 重定向次数上限且目标同样走校验。IP 校验必须在 `DialContext` 里做：先解析再交给默认拨号会二次解析，攻击者的 DNS 第一次返回公网、第二次返回 10.0.0.1（DNS rebinding）。

```go
var cgnat = netip.MustParsePrefix("100.64.0.0/10") // RFC 6598；IsPrivate 不含它，阿里云元数据 100.100.100.200 就在这段

func blocked(ip netip.Addr) bool {
	ip = ip.Unmap() // ::ffff:10.0.0.1 这类 4in6 绕过
	return !ip.IsValid() || ip.IsLoopback() || ip.IsPrivate() || cgnat.Contains(ip) || ip.IsUnspecified() ||
		ip.IsLinkLocalUnicast() || // 169.254.169.254 云元数据
		ip.IsLinkLocalMulticast() || ip.IsInterfaceLocalMulticast() || ip.IsMulticast()
}

	tr.DialContext = func(ctx context.Context, network, addr string) (net.Conn, error) {
		host, port, err := net.SplitHostPort(addr)
		if err != nil {
			return nil, err
		}
		ips, err := net.DefaultResolver.LookupNetIP(ctx, "ip", host)
		if err != nil {
			return nil, err
		}
		for _, ip := range ips {
			if blocked(ip) { // 任一解析结果命中即拒绝，防混合 A 记录
				return nil, ErrForbiddenAddr
			}
		}
		return dialer.DialContext(ctx, network, net.JoinHostPort(ips[0].Unmap().String(), port))
	}
```

### 反序列化与解析炸弹

- JSON：`encoding/json` 嵌套深度硬上限 10000，超出报 `exceeded max depth`（Go 1.27 实测），深度不用自己防；体积靠 `MaxBytesReader`/`LimitReader`；`DisallowUnknownFields` 是 mass assignment 的第二道闸。
- XML：`encoding/xml` 不解析 DTD 实体声明，自定义实体在 Strict 模式报 `invalid character entity`（实测），billion laughs 天然免疫；基于 libxml2 的 cgo 库不在此列。
- YAML：`gopkg.in/yaml.v3` 对别名展开有上限，炸弹文档报 `yaml: document contains excessive aliasing`（实测）。
- zip：条目名过 `IsLocal` 防 zip slip；解压总字节按实际读出计数，头部 `UncompressedSize64` 可伪造。

```go
func DecodeJSON[T any](r io.Reader, limit int64) (T, error) {
	var v T
	dec := json.NewDecoder(io.LimitReader(r, limit))
	dec.DisallowUnknownFields()
	err := dec.Decode(&v)
	return v, err
}

		if !filepath.IsLocal(f.Name) {
			return fmt.Errorf("zip: illegal entry %q", f.Name)
		}

	n, err := io.Copy(dst, io.LimitReader(rc, limit))
```

## 应用层：浏览器侧防护

### 安全头

`X-XSS-Protection: 1; mode=block` 是有害配置：Chrome/Edge 已删除 XSS Auditor，Firefox 从未实现，历史上 Auditor 自身被用作 XS-Leak 探测页面内容。防 XSS 的头是 CSP。HSTS 只在 HTTPS 响应上有意义；撤回要下发 `max-age=0` 且客户端得再访问一次 HTTPS 才收得到，进了 preload 列表更要等数月，所以先用短 `max-age` 验证再放大。

```go
func SecurityHeaders(api bool) gin.HandlerFunc {
	csp := "default-src 'self'; object-src 'none'; base-uri 'self'; frame-ancestors 'none'"
	if api { // 纯 JSON API 没有可执行内容
		csp = "default-src 'none'; frame-ancestors 'none'"
	}
	return func(c *gin.Context) {
		h := c.Writer.Header()
		h.Set("X-Content-Type-Options", "nosniff")
		h.Set("Content-Security-Policy", csp)
		h.Set("X-Frame-Options", "DENY") // 旧浏览器兜底，现代浏览器以 frame-ancestors 为准
		h.Set("Referrer-Policy", "strict-origin-when-cross-origin")
		h.Set("Strict-Transport-Security", "max-age=63072000; includeSubDomains") // 只在 HTTPS 响应上有意义；撤回要再发 max-age=0
		c.Next()
	}
}
```

### CSRF

三道防线按顺序：`SameSite=Lax` cookie（阻断跨站 POST）→ `Sec-Fetch-Site` 校验（浏览器自动带，不可伪造）→ 双提交 token 兜底没有该头的老客户端。`OPTIONS` 必须放行，否则 CORS 预检全部 403。`same-site`（其他子域）与 `cross-site` 同样拒绝——子域接管是常见跳板。

```go
func CSRF(cookieName, headerName string) gin.HandlerFunc {
	safe := map[string]bool{http.MethodGet: true, http.MethodHead: true, http.MethodOptions: true} // OPTIONS 是 CORS 预检，拦了整站跨域全挂
	return func(c *gin.Context) {
		if safe[c.Request.Method] {
			c.Next()
			return
		}
		switch c.GetHeader("Sec-Fetch-Site") {
		case "same-origin", "none": // none = 用户从地址栏/书签直接发起
		case "": // 老客户端：退到双提交 token；token cookie 不能 HttpOnly，否则前端读不到
			cookie, err := c.Cookie(cookieName)
			if err != nil || cookie == "" || subtle.ConstantTimeCompare([]byte(cookie), []byte(c.GetHeader(headerName))) != 1 {
				c.AbortWithStatus(http.StatusForbidden)
				return
			}
		default: // cross-site、same-site（其他子域可能被接管）一律拒
			c.AbortWithStatus(http.StatusForbidden)
			return
		}
		c.Next()
	}
}
```

## 数据层：随机数、secret 与日志

- `math/rand` 与 `math/rand/v2` 都不能生成 token、验证码、salt；`crypto/rand.Text()`（Go 1.24）直接给出 ≥ 128 bit 的 base32 串。
- `os.Getenv` 缺配置返回空串，服务会用空密码"正常"启动；用 `os.LookupEnv` 并 fail-fast。
- Vault / KMS / 云 Secret Manager 接入要点：进程启动时拉一次并缓存在内存，按租约到期前刷新；数据库密码轮换用双凭据（新旧并存一个轮换周期）；secret 不落磁盘、不进镜像层、不进 `ConfigMap`。
- 日志：`WithRedactKeys` 只脱敏结构化字段，`fmt.Sprintf` 拼进 message 的值不受保护；再给 secret 一个自定义类型让 `%v` 也打不出来。

```go
type Secret string

func (Secret) String() string   { return "[REDACTED]" }
func (s Secret) Reveal() string { return string(s) }

func mustEnv(name string) Secret {
	v, ok := os.LookupEnv(name)
	if !ok || v == "" {
		logger.Fatal("missing required env", zap.String("name", name))
	}
	return Secret(v)
}

func InitLogger() {
	logger.SetDefault(logger.MustNew(
		logger.WithLevel("info"),
		logger.WithOutJSON(true),
		logger.WithRedactKeys("password", "token", "authorization", "cookie", "id_card", "phone"),
	))
}

func NewOpaqueToken() string { return rand.Text() } // Go 1.24：≥ 128 bit，base32，直接可用
```

## 供应链

- `govulncheck ./...`：官方工具，基于调用图只报实际可达的漏洞，误报远低于按依赖清单比对的扫描器；每次 CI 必跑。
- `gosec ./...`：静态规则（G101 硬编码凭据、G112 缺 ReadHeaderTimeout、G402 TLS 配置、G304 路径拼接）。
- `go mod verify` 校验模块缓存未被篡改；`go.sum` 必须提交；私有代理设 `GONOSUMDB`/`GOPRIVATE` 而不是关掉校验。
- SBOM 用 `cyclonedx-gomod` 或 `syft` 生成并随制品归档；依赖最小化——一个只用了三个函数的库是三十个传递依赖的入口。
- 门禁与失败策略（阻断级别、例外流程）见 go-engineering-governance。

## 限流

实现（令牌桶 / 滑动窗口、单机 / Redis）见 go-stability-engineering。按 IP 限流有三个坑：未 `SetTrustedProxies` 时 `c.ClientIP()` 可被 `X-Forwarded-For` 伪造而绕过；限流键空间无界（每个新 IP 一个 limiter 且不淘汰）会让限流器本身成为内存 DoS 面；NAT 与企业出口共享 IP 会误伤，登录、验证码类接口要按账号维度再限一层。

## 何时不该用

| 场景 | 选择 | 理由 |
|---|---|---|
| 纯 `Authorization: Bearer` API | 不挂 CSRF 中间件 | 浏览器不会自动附带该头，不存在 CSRF；挂了只会拦掉合法的跨域预检 |
| 全站 `Cache-Control: no-store` | 只对敏感接口设 | 全局设置打掉静态资源与 CDN 缓存，首屏性能下降数倍 |
| `X-XSS-Protection` | 不设或设 `0` | 见安全头一节 |
| bcrypt 用于新系统 | argon2id | 72 字节截断、无内存硬度；bcrypt 只在存量系统保留 |
| 存储前"清洗" HTML | 存原文、输出编码 | 清洗规则与输出上下文不一致，Markdown/富文本合法内容被破坏 |
| JWT 做会话即时吊销 | 短寿命 + refresh 轮换 | 每次请求查黑名单等于退回有状态会话，JWT 优势归零 |
| 按 IP 限流保护登录 | 账号维度限流 + 验证码 | 攻击者换 IP 成本远低于换账号 |

## 审查清单

- [ ] 传输：`http.Server` 四个超时齐全；`MaxBytesReader` 在 Bind 之前；`tls.Config.MinVersion` 显式；仓库 grep 不到 `InsecureSkipVerify: true`（测试文件除外）
- [ ] 认证：`jwt.WithValidMethods` 存在；`sub` 为字符串；`kid` 多密钥；refresh 用后即删并有 family 吊销；密码哈希为 argon2id 或 bcrypt cost ≥ 12；比较走 `ConstantTimeCompare`
- [ ] 授权：每条按 ID 查询的 SQL 含所有者/租户列；请求体绑定的是 DTO；越权与不存在返回同一错误
- [ ] 输入输出：无 `fmt.Sprintf` 拼 SQL；HTML 走 `html/template`；邮箱走 `mail.ParseAddress`；用户可控路径过 `IsLocal` + `os.Root`
- [ ] SSRF：用户 URL 的出站请求走 `NewSafeClient`；`DialContext` 内校验；重定向有上限
- [ ] 解析：JSON 体积有限制；zip 解压按实际字节计数；不可信 YAML 只用 yaml.v3
- [ ] 浏览器：无 `X-XSS-Protection`；有 CSP / nosniff / Referrer-Policy；HSTS 仅 HTTPS；Cookie `HttpOnly + Secure + SameSite`；CSRF 放行 `OPTIONS`
- [ ] secret：无 `os.Getenv` 直接取密钥；无硬编码；日志 `WithRedactKeys` 覆盖 password/token/authorization；secret 类型实现 `String()` 脱敏
- [ ] 供应链：CI 有 `govulncheck`；`go.sum` 已提交；金额字段无 float
