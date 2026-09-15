# HTTP 测试：Gin handler 与出站请求

## Gin handler 测试：必须挂完整中间件栈

go-gin-api 约定 handler 出错只 `c.Error(err); return`，状态码由错误中间件映射。测试若绕过中间件，错误路径返回 200 空 body（Go 1.27 + gin v1.12 实测）。

```go
// NewRouter 是生产与测试共用的唯一路由装配点：测试若自己 gin.New() 只挂 handler，
// 错误路径会返回 200 空 body，测不出任何问题。
func NewRouter(h *Handler) *gin.Engine {
	r := gin.New()
	r.Use(gin.Recovery(), errorHandler())
	r.GET("/users/:id", h.GetUser)
	return r
}
```

```go
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			req := httptest.NewRequestWithContext(t.Context(), http.MethodGet, tt.path, nil)
			rec := httptest.NewRecorder()
			router.ServeHTTP(rec, req)
			require.Equal(t, tt.wantCode, rec.Code)
			require.JSONEq(t, tt.wantBody, rec.Body.String())
		})
```

`gin.SetMode(gin.TestMode)` 放 `TestMain`；响应体用 `require.JSONEq` 断言，不比对字符串。

## 出站 HTTP：httptest.NewServer 与 fake RoundTripper

```go
// httptest.NewServer：走真实 TCP 与 http.Transport，适合验证超时、重试、状态码语义。
func TestClient_Ping_Upstream5xx(t *testing.T) {
	t.Parallel()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusServiceUnavailable)
	}))
	t.Cleanup(srv.Close)

	err := outbound.NewClient(srv.URL, "tok", srv.Client()).Ping(t.Context())
	require.ErrorIs(t, err, outbound.ErrUpstream)
}

type roundTripFunc func(*http.Request) (*http.Response, error)

func (f roundTripFunc) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }

// fake RoundTripper：不开端口，直接断言出站请求的形状（header、path），单测里更快更稳。
func TestClient_Ping_SendsBearer(t *testing.T) {
	t.Parallel()
	hc := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		require.Equal(t, "Bearer tok", r.Header.Get("Authorization"))
		require.Equal(t, "/ping", r.URL.Path)
		return &http.Response{StatusCode: http.StatusOK, Body: io.NopCloser(strings.NewReader(""))}, nil
	})}
	require.NoError(t, outbound.NewClient("http://api", "tok", hc).Ping(t.Context()))
}
```

客户端必须接受注入的 `*http.Client`；fake `Response` 的 `Body` 不能为 nil。
