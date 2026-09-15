---
name: go-gin-api
description: 用 Gin 写生产级 REST API：http.Server 超时与优雅关闭、中间件栈、DTO 校验、JWT、CORS、幂等写接口、健康检查、Recovery。编写或审查 Gin 服务、handler、middleware、路由时使用。
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

## 按任务读取

以下内容按任务读取，只读本次需要的文件；核心规则与审查清单已覆盖其结论。

| 任务 | 读 |
|---|---|
| 搭服务骨架：main、超时、优雅关闭、健康检查、Recovery | `references/server.md` |
| 定义响应结构、DTO 绑定与校验 | `references/request.md` |
| JWT 与 CORS 中间件 | `references/auth.md` |
| 幂等写接口（Idempotency-Key） | `references/idempotency.md` |

## 项目结构

```
cmd/server/main.go        启动：logger、validator、engine、http.Server、信号
internal/{handler,dto}/   handler 只做绑定、调 service、写响应；dto 放请求结构与校验注册
internal/{service,repository}/  业务逻辑返回 *apperror.AppError；repository 翻译驱动错误（见 go-database-patterns）
internal/middleware/ pkg/response/  本文件的中间件；成功响应结构
```

## 请求体限制与路由超时

`BodyLimit(maxBytes)` 中间件：`c.Request.Body = http.MaxBytesReader(c.Writer, c.Request.Body, maxBytes)`。超限时 Read 返回 `*http.MaxBytesError`（`dto.Bind` 映射为 413），且服务器在响应后关闭连接；上传路由单独放宽并设 `r.MaxMultipartMemory`。

`RouteTimeout(d)` = `timeout.New(timeout.WithTimeout(d), timeout.WithResponse(func(c *gin.Context) { c.JSON(http.StatusGatewayTimeout, ginmw.ErrorBody{Code: apperror.CodeTimeout, Message: apperror.ErrTimeout.Message}) }))`。gin-contrib/timeout v1.2.1 给 `c.Request.Context()` 设 deadline、把 handler 放到独立 goroutine，超时后丢弃其后续写入，但会**等 handler 返回**才结束——handler 的 IO 不传 ctx 时，超时只缩短了客户端等待，没释放任何资源。取舍：`http.TimeoutHandler` 包整个 engine、固定回 503、不支持 Flusher（SSE 全废）；显式 `select { case <-ctx.Done(): case res := <-ch: }` 只适合单个慢调用；三者都无法真正终止 handler 的 goroutine，唯一能释放资源的是 handler 尊重 ctx。

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
