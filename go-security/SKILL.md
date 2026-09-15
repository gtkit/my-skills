---
name: go-security
description: Go Web 安全编码：TLS 与服务器硬化、JWT 与密钥轮换、密码哈希、IDOR、注入与输出编码、SSRF、解析炸弹、安全头与 CSRF、secret 管理、govulncheck。做鉴权、处理外部输入或做安全审查时使用。
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

## 按任务读取

以下内容按任务读取，只读本次需要的文件；核心规则与审查清单已覆盖其结论。

| 任务 | 读 |
|---|---|
| TLS 与 http.Server 硬化 | `references/transport.md` |
| 认证与授权：JWT、密码哈希、IDOR | `references/auth.md` |
| 输入校验、输出编码、SSRF、解析炸弹 | `references/input-output.md` |
| 安全头、CSP、CSRF | `references/browser.md` |
| 随机数、secret 与日志脱敏 | `references/secrets.md` |

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
