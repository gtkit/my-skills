# 传输层：TLS 与服务器硬化

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
