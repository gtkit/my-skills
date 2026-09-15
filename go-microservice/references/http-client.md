# HTTP 客户端

```go
// New 进程内每个下游一个 Client 并复用：每次 &http.Client{} 都新建 Transport，
// 连接池失效、TIME_WAIT 与 TLS 握手数随 QPS 线性增长。
func New(perHostConns int) *http.Client {
	tr := &http.Transport{
		DialContext:           (&net.Dialer{Timeout: 3 * time.Second, KeepAlive: 30 * time.Second}).DialContext,
		MaxIdleConns:          perHostConns * 4,
		MaxIdleConnsPerHost:   perHostConns, // 默认 DefaultMaxIdleConnsPerHost = 2，高并发下几乎等于没有连接池
		IdleConnTimeout:       90 * time.Second,
		TLSHandshakeTimeout:   5 * time.Second,
		ResponseHeaderTimeout: 10 * time.Second, // 只管首字节；整体超时靠 ctx deadline
	}
	return &http.Client{
		// otelhttp 在出站请求注入 traceparent；需 main 里已装 TracerProvider + Propagator（见 go-observability）
		Transport: otelhttp.NewTransport(tr),
		// 不设 Client.Timeout：它会和 ctx deadline 竞争，且不区分"连接慢"与"读 body 慢"
	}
}

// GetJSON 演示出站请求的四个必做项：ctx、err 检查、Body 关闭、读尽 body 以复用连接。
func GetJSON[T any](ctx context.Context, c *http.Client, url string) (T, error) {
	var zero T
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil { // url 非法时在这里失败，忽略 err 会得到 nil req 并 panic
		return zero, fmt.Errorf("build request: %w", err)
	}
	resp, err := c.Do(req)
	if err != nil {
		return zero, err // 已含 url 与 method，不再包装
	}
	defer func() { // 未读尽的 body 无法归还连接池；LimitReader 防超大响应拖住 goroutine
		_, _ = io.Copy(io.Discard, io.LimitReader(resp.Body, 64<<10))
		_ = resp.Body.Close()
	}()
	if resp.StatusCode != http.StatusOK {
		return zero, &StatusError{Code: resp.StatusCode}
	}
	var out T
	if err := json.NewDecoder(io.LimitReader(resp.Body, 8<<20)).Decode(&out); err != nil {
		return zero, fmt.Errorf("decode response: %w", err)
	}
	return out, nil
}
```

`GetJSON` 的四个必做项：`http.NewRequestWithContext` 检查 err（url 非法时 req 为 nil，忽略 err 会 panic）；方法用 `http.MethodGet` 常量；`resp.Body` 必 Close；Close 前读尽（`io.Copy(io.Discard, io.LimitReader(...))`），未读尽的连接不能复用。状态码映射成实现 `Retryable()`/`Permanent()` 的 `StatusError`（只有 429/502/503/504 可重试，与 go-error-handling 一致），交给 go-stability-engineering 的重试与熔断判定。
