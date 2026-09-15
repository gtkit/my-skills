# 数据层：随机数、secret 与日志

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
