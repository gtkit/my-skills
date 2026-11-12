---
name: go-gin-api
description: 用 Gin 写生产级 REST API：http.Server 超时与优雅关闭、中间件栈、DTO 校验、JWT、CORS、幂等写接口、健康检查、Recovery。编写或审查 Gin 服务、handler、middleware、路由时使用。
---

# Go Gin API

## 前置必读：拒绝猜测与改动边界

- 每次使用本 skill、恢复任务及执行任何改动前，先实际读取本节、当前运行环境已配置的全局规则，以及目标项目已有的协作规则和错误记录。按已明确的配置入口定位，不猜路径、不硬编码本机目录，不以记忆或摘要替代；必需规则无法读取时停止改动并说明。
- 需求、接口、字段、权限、默认值、路径、工具能力、依赖与兼容结论必须有用户指令、已读取源码/配置、已核实官方资料或真实执行证据。未知保持未确认，先核实；仍不明确就停止依赖该信息的步骤，不凭猜测补全，不重复询问已经明确的要求。
- 修改代码前先完成并落盘方案和逐步计划，写清范围、文件、兼容约束、风险、回滚和验收；只执行获准范围及阶段。计划、候选原因和未执行步骤标为待验证，不能当作事实或已完成结果。
- 只有真实执行并回读后才能报告完成或通过，区分失败、未执行、未验证和不适用；模拟与静态证据不冒充真实链路。纯文档、注释、规则或 skill 说明任务只编辑指定内容并回读，不因本 skill 的流程扩展为测试、构建、同步、打包或 OpenSpec 操作。

Gin 服务的骨架与中间件参考。业务错误与日志沿用目标项目已确认的契约；以下示例采用 go-error-handling 的 `apperror.*AppError` 与 `ginmw.Errors()`，不要求其他项目替换既有模型。本文件不再重复定义该示例类型。

## Gin 框架原生写法（强制）

- **只要项目使用 Gin，路由、handler、中间件、参数绑定、校验、上下文和响应处理就必须遵守 Gin 的公开 API、调用语义及项目已经确认的惯例。** 禁止凭个人偏好绕开框架、照搬其他框架的处理方式，或给单个接口另造一套绑定流程。标准库和第三方组件用于 Gin 未承担的职责，不代表可以替换已有的 Gin 请求处理链。
- 写前实际读取项目锁定的 Gin 版本、模块替换及有关构建标签，同模块 handler、请求 DTO、统一响应工具、中间件和适用 Guide。API 与边界行为按该版本源码或官方资料核实；不能用其他版本的印象作依据，也不能把本 skill 的示例函数、目录或错误模型强加给已有项目。
- **普通结构化请求在 handler 直接使用与输入来源匹配的 `ShouldBind*`。** JSON 用 `ShouldBindJSON`，仅 query 用 `ShouldBindQuery`，路径参数用 `ShouldBindUri`，header 用 `ShouldBindHeader`，表单按实际契约使用 `ShouldBind` 或原生指定 binder。完整选择表见 [请求与校验](references/request.md)。禁止先 `ReadAll`、手工拆 Content-Type、`json.Unmarshal`，再逐字段检查来替代原生绑定。
- 基础必填、长度、格式和范围约束写入独立请求 DTO 的 `binding` 标签，字段来源使用相应的 `json`、`form`、`uri`、`header` 标签；业务状态、权限和数据库相关规则留在 application/service。缺失、零值、空字符串与 `null` 的区别以接口契约为准，不自行增加字段限制。
- 有统一错误响应的项目使用 `ShouldBind*` 返回错误，再交给已有错误出口并结束当前分支。`Bind*`/`MustBind*` 有自动写出错误状态及中断链的语义，不能与二次错误响应混用。响应复用项目已有、符合 Gin 语义的工具；`c.Abort()` 不会退出当前函数，拒绝分支仍须 `return`。下游 I/O 使用 `c.Request.Context()`，不向 application/service 传递 `*gin.Context`。
- **不得把自定义 `Bind`、`ParseRequest`、`binding.Binding` 实现或新的校验封装设为默认入口。** 已有 helper 只有在职责清楚、没有绕开原生绑定或破坏错误语义时才复用；用户指出过度复杂后，必须重新检查并删除不必要流程，不能只将其搬到另一函数或文件。
- 原始字节验签、流式请求、文件或特殊协议确有需求时，先核实已确认契约和 Gin 原生支持。原生能力不能满足时，写清差异、证据、影响与最小适配方案；新增自定义解析器或绑定器须经用户明确认可。保留已确认的限长、鉴权、脱敏和失败处理，不能为简化而删掉，也不能自己发明额外约束来证明复杂实现必要。
- 以上规则适用于当前获准的实现和审查范围；只要求保存规则或修改 skill 说明时，仅编辑并回读，不继续业务代码、测试、构建或 OpenSpec。

## 核心规则

1. `gin.New()` 自建中间件栈；`gin.Default()` 的 Logger/Recovery 写 stdout、不带 request_id、不判 `Written()`。
2. 必须 `r.SetTrustedProxies(...)`：gin 1.12 默认信任 `0.0.0.0/0, ::/0`，任何客户端可用 `X-Forwarded-For` 伪造 `ClientIP()`，限流与审计全部失真。
3. `http.Server` 四个超时字段全部显式设置（`r.Run()` 等于零超时裸奔，slowloris 打穿）；`signal.NotifyContext` + `srv.Shutdown(ctx)`，Shutdown 超时 < k8s `terminationGracePeriodSeconds`。
4. 每个请求体经 `http.MaxBytesReader` 限制（只看 `Content-Length` 挡不住 chunked）；用 Gin 原生方法绑定到独立 DTO（``Email string `json:"email" binding:"required,email"` ``），禁止绑到 GORM model。校验错误字段名按实际输入来源映射，优先复用已有工具；只有确有需要才通过 Gin 的 validator 扩展点注册，不为每个接口另建校验器。绑定错误不回显 `err.Error()`。
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

`BodyLimit(maxBytes)` 中间件：`c.Request.Body = http.MaxBytesReader(c.Writer, c.Request.Body, maxBytes)`。超限时 Read 返回 `*http.MaxBytesError`；`ShouldBind*` 返回的错误由项目已有错误出口识别并映射为 413，具体错误传播还须核对所用 JSON 实现。上传路由按契约设置独立上限与 `r.MaxMultipartMemory`，内存阈值不代替请求体大小限制。

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
- [ ] 已核对 Gin 版本、同模块 handler、DTO、响应工具和中间件；所有结构化输入使用来源匹配的原生绑定与 `binding` 标签
- [ ] 没有擅自新增手工解码、自定义 binder 或单次封装；确需的适配有契约证据与明确授权，保留原有安全约束
- [ ] 错误使用项目已有统一出口（本 skill 示例为 `ginmw.Fail`）；无原始错误泄漏、重复写响应或拒绝后继续执行业务；确需的 validator 注册在启动时完成并检查错误
- [ ] 路由组挂 `RouteTimeout`；handler 内每个 IO 都传 `c.Request.Context()`
- [ ] 无 `go func(){ ... c ... }()`；异步走队列或 `FireAndForget`
- [ ] JWT：`WithValidMethods`、`WithLeeway`、`WithExpirationRequired`、`CutPrefix` 检查 `Bearer `；CORS 白名单，无 `*` + `Authorization` 组合
- [ ] 写接口幂等：`Begin` 原子、key 绑定用户+路由、报错/5xx/panic 释放占位
- [ ] `/livez` 无依赖；`/readyz` 每依赖 2s 超时且并行；pprof 在 `127.0.0.1` 独立端口 + 独立 mux，无 `import _ "net/http/pprof"`；`Recovery` 记 `zap.Stack`、判 `Written()`、broken pipe 降为 WARN
- [ ] 全局 `BodyLimit`；request_id/访问日志/metrics 按 go-observability 接入；限流按 go-stability-engineering 接入
