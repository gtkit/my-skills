---
name: go-gin-api
description: 用 Gin 构建生产级 REST API：http.Server 超时与优雅关闭、中间件栈、请求体限制、路由超时、DTO 绑定校验、JWT、CORS、幂等写接口、健康检查、Recovery。当用户提到 Gin、gin-gonic、Go REST API、HTTP handler、middleware、路由、请求校验、JSON 响应、Go web server 时触发。错误类型与错误码见 go-error-handling；日志/metrics/request_id 中间件见 go-observability；限流熔断见 go-stability-engineering。
---

# Go Gin API

Gin 服务的骨架与每个中间件的正确形态。业务错误一律使用 go-error-handling 的 `apperror.*AppError` 与 `ginmw.Errors()`，本文件不再定义错误类型。

## 核心规则

1. `gin.New()` 自建中间件栈；`gin.Default()` 的 Logger/Recovery 写 stdout、不带 request_id、不判 `Written()`。
2. 必须 `r.SetTrustedProxies(...)`：gin 1.12 默认信任 `0.0.0.0/0, ::/0`，任何客户端可用 `X-Forwarded-For` 伪造 `ClientIP()`，限流与审计全部失真。
3. `http.Server` 四个超时字段全部显式设置（`r.Run()` 等于零超时裸奔，slowloris 打穿）；`signal.NotifyContext` + `srv.Shutdown(ctx)`，Shutdown 超时 < k8s `terminationGracePeriodSeconds`。
4. 每个请求体经 `http.MaxBytesReader` 限制（只看 `Content-Length` 挡不住 chunked）；绑定到独立 DTO（``Email string `json:"email" binding:"required,email"` ``），禁止绑到 GORM model；校验错误字段名经 `RegisterTagNameFunc` 映射为 json 名；绑定错误不回显 `err.Error()`。
5. `context.WithTimeout` 不会中断 handler，只让传了 ctx 的下游调用返回；路由级超时用 `gin-contrib/timeout`，且 handler 内所有 IO 必须传 `c.Request.Context()`。
6. handler 内异步：`cp := c.Copy()` + `context.WithoutCancel(c.Request.Context())`，优先投队列。`go func(){ use(c) }()` 读到的是被复用的 Context。
7. `/livez` 无依赖检查，`/readyz` 才检查依赖，每个依赖 2s 超时；pprof/metrics 只监听本机独立端口；`gin.SetMode(gin.ReleaseMode)`。

## 项目结构

```
cmd/server/main.go        启动：logger、validator、engine、http.Server、信号
internal/{handler,dto}/   handler 只做绑定、调 service、写响应；dto 放请求结构与校验注册
internal/{service,repository}/  业务逻辑返回 *apperror.AppError；repository 翻译驱动错误（见 go-database-patterns）
internal/middleware/ pkg/response/  本文件的中间件；成功响应结构
```

## main：服务器、超时、优雅关闭

```go
const shutdownTimeout = 20 * time.Second // preStop 5s + 排空 20s + 关依赖余量 5s = terminationGracePeriodSeconds 默认 30s（时序见 go-microservice）

func main() {
	logger.SetDefault(logger.MustNew(logger.WithLevel("info"), logger.WithOutJSON(true), logger.WithConsole(true),
		logger.WithRedactKeys("password", "token", "authorization")))
	defer logger.Sync()

	if err := dto.SetupValidator(); err != nil {
		logger.Fatal("setup validator", zap.Error(err))
	}
	gin.SetMode(gin.ReleaseMode)
	r := gin.New() // gin.Default() 的 Logger/Recovery 写 stdout 且不带 request_id，不用
	if err := r.SetTrustedProxies([]string{"10.0.0.0/8"}); err != nil { // 默认信任 0.0.0.0/0：任何人可伪造 X-Forwarded-For
		logger.Fatal("trusted proxies", zap.Error(err))
	}
	r.MaxMultipartMemory = 8 << 20
	// 顺序即包裹顺序：Recovery 最外层；request_id/日志/metrics 中间件见 go-observability；限流见 go-stability-engineering。
	r.Use(middleware.Recovery(), ginmw.Errors(), middleware.BodyLimit(1<<20), middleware.CORS([]string{"https://app.example.com"}))
	health.Register(r, map[string]health.Checker{})
	api := r.Group("/api/v1", middleware.JWT([]byte(os.Getenv("JWT_SECRET"))), middleware.RouteTimeout(5*time.Second))
	api.GET("/ping", func(c *gin.Context) { c.String(http.StatusOK, "pong") })

	srv := &http.Server{
		Addr:              ":8080",
		Handler:           r,
		ReadHeaderTimeout: 5 * time.Second, // 缺它 = slowloris 直接打穿
		ReadTimeout:       15 * time.Second,
		WriteTimeout:      30 * time.Second, // SSE/长轮询路由需单独用 ResponseController.SetWriteDeadline
		IdleTimeout:       120 * time.Second,
		MaxHeaderBytes:    1 << 20,
	}
	go serveAdmin() // pprof/metrics 只监听本机端口，绝不挂到业务端口

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	go func() {
		if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			logger.Error("listen", zap.Error(err))
			stop()
		}
	}()
	<-ctx.Done()
	// SIGTERM 后 readiness 需先变为失败并等 endpoint 摘除（sleep 数秒），再 Shutdown，否则仍有新连接被路由进来。
	shutdownCtx, cancel := context.WithTimeout(context.Background(), shutdownTimeout)
	defer cancel()
	if err := srv.Shutdown(shutdownCtx); err != nil {
		logger.Error("shutdown", zap.Error(err)) // 超时后仍有活跃连接会被强制断开
	}
}
```

`serveAdmin` 用独立 `http.Server{Addr: "127.0.0.1:6060", ReadHeaderTimeout: 5s}` + 独立 `http.NewServeMux()`，把 `pprof.Index`/`pprof.Profile` 显式注册上去。**不能 `import _ "net/http/pprof"`**：它的 init 把 handler 注册进 `DefaultServeMux`，业务 server 只要用了 `DefaultServeMux`（或任何最终回落到它的 `http.Handle`），`/debug/pprof` 就跟业务一起暴露在业务端口上（同 go-performance）。`Shutdown` 不等待 SSE/WebSocket 这类被 Hijack 或长写的连接，需业务自行关闭（见 go-websocket-sse）。

## 请求体限制与路由超时

`BodyLimit(maxBytes)` 中间件：`c.Request.Body = http.MaxBytesReader(c.Writer, c.Request.Body, maxBytes)`。超限时 Read 返回 `*http.MaxBytesError`（`dto.Bind` 映射为 413），且服务器在响应后关闭连接；上传路由单独放宽并设 `r.MaxMultipartMemory`。

`RouteTimeout(d)` = `timeout.New(timeout.WithTimeout(d), timeout.WithResponse(func(c *gin.Context) { c.JSON(http.StatusGatewayTimeout, ginmw.ErrorBody{Code: apperror.CodeTimeout, Message: apperror.ErrTimeout.Message}) }))`。gin-contrib/timeout v1.2.1 给 `c.Request.Context()` 设 deadline、把 handler 放到独立 goroutine，超时后丢弃其后续写入，但会**等 handler 返回**才结束——handler 的 IO 不传 ctx 时，超时只缩短了客户端等待，没释放任何资源。取舍：`http.TimeoutHandler` 包整个 engine、固定回 503、不支持 Flusher（SSE 全废）；显式 `select { case <-ctx.Done(): case res := <-ch: }` 只适合单个慢调用；三者都无法真正终止 handler 的 goroutine，唯一能释放资源的是 handler 尊重 ctx。

## 统一成功响应

```go
// Paged 是公共包，不能假设调用方已做默认值处理：perPage <= 0 直接整除零 panic，
// total 为负（COUNT 减去软删数量写错符号）会算出负页数，前端翻页控件按负数循环请求。
// items 为 nil 时输出 [] 而非 null，客户端不必区分两种"空"。
func Paged[T any](c *gin.Context, items []T, page, perPage int, total int64) {
	perPage = max(perPage, 1)
	total = max(total, 0)
	if items == nil {
		items = []T{}
	}
	// 先除后补，不用 (total+perPage-1)/perPage：total 接近 MaxInt64 时那个写法会溢出成负数。
	totalPage := int(total / int64(perPage))
	if total%int64(perPage) != 0 {
		totalPage++
	}
	c.JSON(http.StatusOK, Response{
		Message: "success",
		Data:    items,
		Meta:    PageMeta{Page: max(page, 1), PerPage: perPage, Total: total, TotalPage: totalPage},
	})
}
```

``Response{Code int; Message string; Data any `json:"data,omitzero"`; Meta PageMeta `json:"meta,omitzero"`}``：`omitempty` 对 struct 值不生效（encoding/json 只认 false/0/nil/空集合），`PageMeta` 零值照样输出——Go 1.24 起用 `omitzero`（Go 1.27 实测）。错误响应形状是 go-error-handling 的 `ginmw.ErrorBody`。

## DTO 绑定与校验

```go
// SetupValidator 在启动时调用一次。binding.Validator.Engine() 返回 any，需断言为 *validator.Validate。
// 不注册 TagNameFunc 时 FieldError.Field() 返回 Go 字段名 "Email"，客户端拿到的字段名与请求体对不上。
func SetupValidator() error {
	v, ok := binding.Validator.Engine().(*validator.Validate)
	if !ok {
		return errors.New("binding.Validator.Engine() is not *validator.Validate")
	}
	v.RegisterTagNameFunc(func(fld reflect.StructField) string {
		name, _, _ := strings.Cut(fld.Tag.Get("json"), ",")
		if name == "-" {
			return ""
		}
		return name
	})
	return v.RegisterValidation("phone", func(fl validator.FieldLevel) bool {
		return phoneRE.MatchString(fl.Field().String())
	})
}

// Bind 是 handler 里唯一的绑定入口：校验错误按字段返回，其余解码错误一律 400 且不回显原文——
// err.Error() 会泄漏 "Key: 'CreateUserReq.Email' Error:..." 之类内部结构名，以及 json.SyntaxError 的偏移量细节。
func Bind(c *gin.Context, dst any) bool {
	err := c.ShouldBindJSON(dst)
	if err == nil {
		return true
	}
	if mbe, ok := errors.AsType[*http.MaxBytesError](err); ok {
		ginmw.Fail(c, apperror.WithMessage(&apperror.AppError{Code: apperror.CodeInvalidParam, HTTP: http.StatusRequestEntityTooLarge},
			fmt.Sprintf("request body exceeds %d bytes", mbe.Limit)))
		return false
	}
	if ves, ok := errors.AsType[validator.ValidationErrors](err); ok {
		msgs := make([]string, 0, len(ves))
		for _, fe := range ves {
			msgs = append(msgs, fe.Field()+": failed on "+fe.Tag()) // fe.Field() 已是 json 名
		}
		ginmw.Fail(c, apperror.WithMessage(apperror.ErrInvalidParam, strings.Join(msgs, "; ")))
		return false
	}
	ginmw.Fail(c, apperror.Wrap(apperror.WithMessage(apperror.ErrInvalidParam, "malformed request body"), err))
	return false
}
```

## 异步任务

首选投递队列并返回 202：可重试、可观测、进程被 SIGTERM 时不丢任务。反例 `go func() { use(c) }()`：`c.Request.Context()` 在 `ServeHTTP` 返回时已取消，`*gin.Context` 被池化复用，后台 goroutine 读到的是别的请求的数据。只有埋点这类不值得进队列的旁路工作才用下面的 `FireAndForget`：`c.Copy()` 隔离 gin.Context，`WithoutCancel` 保留 trace/request_id 值但脱离请求取消链，且必须自带超时。

```go
func FireAndForget(c *gin.Context, do func(ctx context.Context, cp *gin.Context) error) {
	cp := c.Copy()
	ctx, cancel := context.WithTimeout(context.WithoutCancel(c.Request.Context()), asyncTimeout)
	go func() {
		defer cancel()
		defer func() {
			if r := recover(); r != nil {
				logger.ErrorCtx(ctx, "async panic", zap.Any("panic", r), zap.Stack("stack"))
			}
		}()
		if err := do(ctx, cp); err != nil {
			logger.WarnCtx(ctx, "async task failed", zap.Error(err))
		}
	}()
}
```

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

## 幂等写接口（Idempotency-Key）

状态机：无记录 → `processing` → `done(status, body)`。首选实现是 DB 业务表上的幂等键 UNIQUE 约束（取舍见 go-data-consistency），中间件方案是其上的应用层补充。`IdemStore` 接口：`Begin(ctx, key, ttl) (rec *IdemRecord, acquired bool, err error)` 必须是原子占位（Redis `SET NX` / DB 唯一键 INSERT），两个并发请求只能有一个 `acquired`；`Finish(ctx, key, rec, ttl)`；`Abort(ctx, key)`。反例：先 `GET` 再 `SET`——并发请求都查到空、都执行业务。`captureWriter` 嵌入 `gin.ResponseWriter`，重写 `Write`/`WriteString` 同时写入 `bytes.Buffer`。

```go
// Idempotency 状态机：无记录 → processing → done(result)。
// 命中 processing 返回 409（客户端稍后重试），命中 done 原样回放首次响应；handler 报错（c.Errors 非空）、5xx 或 panic 则释放占位允许重试。
func Idempotency(store IdemStore, ttl time.Duration) gin.HandlerFunc {
	return func(c *gin.Context) {
		key := c.GetHeader("Idempotency-Key")
		if key == "" || len(key) > 128 {
			ginmw.Fail(c, apperror.WithMessage(apperror.ErrInvalidParam, "Idempotency-Key header required (1-128 chars)"))
			return
		}
		ctx := c.Request.Context()
		key = c.GetString(KeyUserID) + ":" + c.FullPath() + ":" + key // 绑定用户与路由，防止跨用户串号
		rec, acquired, err := store.Begin(ctx, key, ttl)
		if err != nil {
			ginmw.Fail(c, apperror.Wrap(apperror.ErrUnavailable, err))
			return
		}
		if !acquired {
			if rec != nil && rec.State == IdemDone { // 实现返回 acquired=false 却给 nil 记录时按 processing 处理，不能 panic
				c.Data(rec.Status, "application/json", rec.Body)
			} else {
				c.JSON(http.StatusConflict, ginmw.ErrorBody{Code: apperror.CodeConflict, Message: "request with same Idempotency-Key is in progress"})
			}
			c.Abort()
			return
		}
		bg := context.WithoutCancel(ctx) // 客户端此时断开也要把状态写完，否则占位卡在 processing 直到 TTL
		defer func() {
			if r := recover(); r != nil {
				_ = store.Abort(bg, key)
				panic(r) // 交给外层 Recovery 记录栈
			}
		}()
		w := &captureWriter{ResponseWriter: c.Writer}
		c.Writer = w
		c.Next()
		// 经 ginmw.Fail 报告的错误此时尚未被外层 Errors 中间件写出，Status() 仍是默认 200（Go 1.27 + gin 1.12 实测）：
		// 必须同时看 c.Errors，否则失败请求被记成 done/200，之后同 key 的重试全部回放这个空 200。
		if len(c.Errors) > 0 || c.Writer.Status() >= http.StatusInternalServerError {
			_ = store.Abort(bg, key)
			return
		}
		_ = store.Finish(bg, key, IdemRecord{State: IdemDone, Status: c.Writer.Status(), Body: w.buf.Bytes()}, ttl)
	}
}
```

## 健康检查

```go
// Register：/livez 只证明进程活着——挂上依赖检查后，DB 抖动会让 k8s 重启所有副本，形成重启风暴。
// /readyz 才检查依赖，失败只是摘流量。每个依赖独立 2s 超时并行检查，总耗时受最慢者约束而非求和：
// 串行时 5 个依赖最坏 10s，远超 kubelet 默认 timeoutSeconds=1（与 go-microservice 的 net/http 版实现相同）。
func Register(r gin.IRouter, deps map[string]Checker) {
	r.GET("/livez", func(c *gin.Context) { c.String(http.StatusOK, "ok") })
	r.GET("/readyz", func(c *gin.Context) {
		var mu sync.Mutex
		var wg sync.WaitGroup
		failed := map[string]string{} // 只暴露依赖名：err.Error() 常含 DSN/主机名，进日志不进响应
		for name, check := range deps {
			wg.Go(func() {
				ctx, cancel := context.WithTimeout(c.Request.Context(), perCheckTimeout)
				defer cancel()
				if err := check(ctx); err != nil {
					logger.WarnCtx(ctx, "readiness check failed", zap.String("dep", name), zap.Error(err))
					mu.Lock()
					failed[name] = "down"
					mu.Unlock()
				}
			})
		}
		wg.Wait()
		status := http.StatusOK
		if len(failed) > 0 {
			status = http.StatusServiceUnavailable
		}
		c.JSON(status, gin.H{"failed": failed})
	})
}
```

## Recovery

不记 `zap.Stack` 时线上 panic 只剩一行 `runtime error: index out of range`；不判 `Written()` 时对已发头的响应再写 JSON 触发 `superfluous response.WriteHeader`。

```go
// Recovery 只覆盖 handler 链所在的 goroutine；handler 里自起的 goroutine panic 仍会杀进程（见 go-error-handling）。
func Recovery() gin.HandlerFunc {
	return func(c *gin.Context) {
		defer func() {
			r := recover()
			if r == nil {
				return
			}
			ctx := c.Request.Context()
			if err, ok := r.(error); ok && (errors.Is(err, syscall.EPIPE) || errors.Is(err, syscall.ECONNRESET) || errors.Is(err, http.ErrAbortHandler)) {
				logger.WarnCtx(ctx, "client connection broken", zap.Error(err)) // 对端已断，写响应没有意义
				c.Abort()
				return
			}
			logger.ErrorCtx(ctx, "panic recovered", zap.Any("panic", r), zap.String("path", c.FullPath()), zap.Stack("stack"))
			if c.Writer.Written() {
				c.Abort() // 头已发出，只能中断链
				return
			}
			c.AbortWithStatusJSON(http.StatusInternalServerError, ginmw.ErrorBody{
				Code: apperror.CodeInternal, Message: apperror.ErrInternal.Message, RequestID: logger.RequestIDFromContext(ctx),
			})
		}()
		c.Next()
	}
}
```

## 何时不该用 Gin

| 场景 | 选择 | 理由 |
|---|---|---|
| 少量路由、无需中间件生态 | `net/http.ServeMux`（Go 1.22 起支持 `GET /users/{id}` 方法+通配路由） | 零依赖，`http.Handler` 直接复用 |
| 需要大量 `http.Handler` 生态（otelhttp、promhttp、gorilla/handlers） | `net/http` 或 chi | Gin 的 `HandlerFunc` 与 `http.Handler` 需 `gin.WrapH` 桥接，中间件语义（Abort）不互通 |
| gRPC 为主、HTTP 只是网关 | grpc-gateway / connect-go | 由 proto 生成，避免手写两套校验 |

## 上线前审查清单

- [ ] `gin.New()`、`SetMode(ReleaseMode)`、`SetTrustedProxies` 为真实 LB 网段
- [ ] `http.Server` 的 `ReadHeaderTimeout/ReadTimeout/WriteTimeout/IdleTimeout/MaxHeaderBytes` 全部设置
- [ ] `signal.NotifyContext` + `Shutdown`，超时 < `terminationGracePeriodSeconds`
- [ ] 所有 handler 绑定到 DTO；`SetupValidator` 在启动时调用并检查返回值
- [ ] 错误出口只有 `ginmw.Fail`；无 `c.JSON(500, err.Error())`
- [ ] 路由组挂 `RouteTimeout`；handler 内每个 IO 都传 `c.Request.Context()`
- [ ] 无 `go func(){ ... c ... }()`；异步走队列或 `FireAndForget`
- [ ] JWT：`WithValidMethods`、`WithLeeway`、`WithExpirationRequired`、`CutPrefix` 检查 `Bearer `；CORS 白名单，无 `*` + `Authorization` 组合
- [ ] 写接口幂等：`Begin` 原子、key 绑定用户+路由、报错/5xx/panic 释放占位
- [ ] `/livez` 无依赖；`/readyz` 每依赖 2s 超时且并行；pprof 在 `127.0.0.1` 独立端口 + 独立 mux，无 `import _ "net/http/pprof"`；`Recovery` 记 `zap.Stack`、判 `Written()`、broken pipe 降为 WARN
- [ ] 全局 `BodyLimit`；request_id/访问日志/metrics 按 go-observability 接入；限流按 go-stability-engineering 接入
