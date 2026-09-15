# 入口层：认证与授权

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
