---
name: go-error-handling
description: Go 错误处理规范：AppError 类型（Error/Unwrap/Is）、错误码分段、HTTP 状态映射、可重试分类、ctx 取消处理、errors.Join、panic 边界、wrap 边界与 lint。当用户设计 Go 错误类型、错误码体系、统一错误响应、重试判定，或提到 errors.Is/As/AsType、fmt.Errorf %w、sentinel error、custom error、error code、recover 时触发。go-gin-api 引用本文件的 AppError，不自行定义；重试/熔断算法见 go-stability-engineering。
allowed-tools: "Read, Write, Edit, Bash, Glob, Grep"
---

# Go 错误处理

定义全仓唯一的业务错误类型 `*AppError` 与错误分类接口；go-gin-api / go-microservice 只引用这里的类型与哨兵。

## 核心规则

1. 只在**增加信息**时 `fmt.Errorf("op key=%v: %w", ..., err)`；纯透传 `return err`。每层都 wrap 会产生 `get order: get order: ...` 冗余链。
2. 哨兵用 `errors.Is`，类型用 `errors.AsType[T]`（Go 1.26 起）；`==` 与 `err.(T)` 在包装后必失效。
3. 自定义错误类型必须实现 `Unwrap()`（否则底层 `sql.ErrNoRows` 在链上不可达）；`*AppError` 通过 `Is(target)` 按 `Code` 比较——`Wrap` 返回新指针，没有 `Is` 时 `errors.Is(Wrap(ErrNotFound, e), ErrNotFound)` 为 false（Go 1.27 实测）。
4. 5xx 响应绝不带 `err.Error()` 原文；错误响应体带 `request_id`。
5. `context.Canceled` → 499、`DeadlineExceeded` → 504，日志 WARN；它们不是故障，不能刷 ERROR 告警。
6. 重试器只调用 `IsRetryable(err)`，熔断器只看 `Permanent()`：4xx 业务错误与 500 不重试，429/502/503/504 与网络超时才重试；`context.Canceled` 永不重试。
7. `defer f.Close()` 的错误用 `errors.Join` 合并进返回值；批处理部分失败用 `errors.Join(errs...)`。
8. 一个错误只记一次日志：谁终结它（handler / worker 顶层）谁记；中间层只 wrap 或透传。自起 goroutine、errgroup worker、MQ 回调、cron 任务必须 `recover`——`gin.Recovery` 只覆盖 handler 链所在 goroutine。

## AppError

```go
// AppError 是贯穿 service → handler 的唯一业务错误类型。
// Code 给客户端做分支，HTTP 给传输层，Message 给人看，Err 只进日志、绝不进响应体。
type AppError struct {
	Code    int
	Message string
	HTTP    int
	Err     error
}

func (e *AppError) Error() string {
	if e.Err != nil {
		return fmt.Sprintf("[%d] %s: %v", e.Code, e.Message, e.Err)
	}
	return fmt.Sprintf("[%d] %s", e.Code, e.Message)
}

// Unwrap 让 errors.Is(err, sql.ErrNoRows) 这类对底层原因的判断继续成立。
func (e *AppError) Unwrap() error { return e.Err }

// Is 按 Code 比较：Wrap/WithMessage 返回的是新指针，没有 Is 时 errors.Is(Wrap(ErrNotFound, x), ErrNotFound) 为 false。
func (e *AppError) Is(target error) bool {
	t, ok := target.(*AppError)
	return ok && t != nil && t.Code == e.Code
}

// Wrap 保留 base 的 Code/Message/HTTP，挂上底层原因。
func Wrap(base *AppError, err error) *AppError {
	return &AppError{Code: base.Code, Message: base.Message, HTTP: base.HTTP, Err: err}
}

// WithMessage 替换面向客户端的文案，其余不变。msg 不得含内部细节（表名、SQL、IP）。
func WithMessage(base *AppError, msg string) *AppError {
	return &AppError{Code: base.Code, Message: msg, HTTP: base.HTTP, Err: base.Err}
}

// From 把任意 error 归一为 *AppError：ctx 取消 → 499，超时 → 504，其余未知错误 → 500。
// 这是响应层唯一的入口，保证 5xx 永远不带 err.Error() 原文。
func From(err error) *AppError {
	if ae, ok := errors.AsType[*AppError](err); ok {
		return ae
	}
	switch {
	case errors.Is(err, context.Canceled):
		return Wrap(ErrClientClosed, err)
	case errors.Is(err, context.DeadlineExceeded):
		return Wrap(ErrTimeout, err)
	}
	return Wrap(ErrInternal, err)
}
```

最小反证测试（去掉 `Is` 方法即失败）：

```go
// 反证：去掉 (*AppError).Is 方法，前两个断言必失败——Wrap 返回的是新指针。
func TestIs(t *testing.T) {
	wrapped := Wrap(ErrNotFound, sql.ErrNoRows)
	deep := fmt.Errorf("service.GetUser id=%d: %w", 42, wrapped)
	if !errors.Is(wrapped, ErrNotFound) || !errors.Is(deep, ErrNotFound) {
		t.Fatal("Wrap 后以及再经 %w 包装后都应匹配同 Code 哨兵")
	}
	if errors.Is(wrapped, ErrConflict) {
		t.Fatal("不同 Code 不得匹配")
	}
}
```

## 错误码分段与哨兵

```go
// 错误码 5 位：MKNN → M M = 模块（10 通用 / 20 订单 / 30 用户 / 40 支付），K = 类型，NN = 序号。
// 类型位决定默认 HTTP：1 参数(400) 2 状态(404/409) 3 权限(401/403) 4 流控(429/499/504) 5 内部或依赖(500/502/503)。
// 新增错误码只能追加序号，不得复用已下线的号；类型位与 HTTP 不一致的定义在 code review 直接打回。
const (
	CodeInvalidParam    = 10101
	CodeUnauthorized    = 10301
	CodeForbidden       = 10302
	CodeNotFound        = 10201
	CodeConflict        = 10202
	CodeTooManyRequests = 10401
	CodeClientClosed    = 10402
	CodeTimeout         = 10403
	CodeInternal        = 10501
	CodeUpstream        = 10502
	CodeUnavailable     = 10503

	CodeOrderNotFound   = 20201
	CodeOrderClosed     = 20202
	CodeOrderNotPayable = 20203

	CodePaymentDeclined = 40201
)
```

哨兵按同一模式定义：`ErrNotFound = &AppError{Code: CodeNotFound, Message: "resource not found", HTTP: http.StatusNotFound}`，`ErrClientClosed` 用 `StatusClientClosedRequest`(499)。使用点一律引用常量：`apperror.Wrap(apperror.ErrOrderNotPayable, err)`；出现 `Code: 20203` 字面量直接打回。

## 错误分类：可重试 / 永久

```go
// errors.AsType 的类型参数必须满足 error，接口里要嵌入 error。
type retryable interface {
	error
	Retryable() bool
}

type permanent struct{ err error }

func (p *permanent) Error() string   { return p.err.Error() }
func (p *permanent) Unwrap() error   { return p.err }
func (p *permanent) Retryable() bool { return false }
func (p *permanent) Permanent() bool { return true } // 供熔断器：是确定性失败，不是下游故障

// Permanent 把一个本来会被判定为可重试的错误（如网络超时）标记为不可重试，
// 用于"已经知道重试无意义"的场景：签名错误、余额不足、下游明确返回 4xx。
func Permanent(err error) error {
	if err == nil {
		return nil
	}
	return &permanent{err: err}
}

// IsRetryable 是重试器唯一应该调用的判定函数。
// 优先级：ctx 取消（调用方已放弃，永不重试）> 显式标记（Permanent / AppError.Retryable）> net.Error 超时 > 默认不重试。
// 取消必须排在标记之前：带可重试标记却包着 context.Canceled 的错误，重试是在给没人等的请求耗资源。
func IsRetryable(err error) bool {
	if err == nil || errors.Is(err, context.Canceled) {
		return false
	}
	if r, ok := errors.AsType[retryable](err); ok {
		return r.Retryable()
	}
	if ne, ok := errors.AsType[net.Error](err); ok && ne.Timeout() {
		return true
	}
	return false
}
```

`AppError.Retryable()` 仅对 429/502/503/504 返回 true；`AppError.Permanent()` 对 4xx（429 除外）返回 true，供 go-stability-engineering 的熔断器 `IsSuccessful` 把"下游正常拒绝"从失败计数里剔除，5xx 与 429 仍计失败。`Permanent` 包在外层，`AsType` 深度优先先命中它、覆盖内层判定；带可重试标记却包着 `context.Canceled` 的错误不重试（均有 `TestFromAndRetryable` 反证）。`context.DeadlineExceeded` 与 `net.timeoutError`（dial 超时）都满足 `net.Error` 且 `Timeout()` 为 true，`IsRetryable` 视为超时类可重试；是否真的重试由重试器按调用方 `ctx.Err()` 与剩余预算决定，见 go-stability-engineering。

## wrap 边界、errors.Join、AsType

```go
// Get 是"增加信息"的层：把驱动错误翻译成业务哨兵，或补上操作名与主键。
func (r *Repo) Get(ctx context.Context, id int64) (*Order, error) {
	var o Order
	err := r.db.QueryRowContext(ctx, "SELECT id FROM orders WHERE id = $1", id).Scan(&o.ID)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, apperror.Wrap(apperror.ErrOrderNotFound, err)
	}
	if err != nil {
		return nil, fmt.Errorf("repo.Order.Get id=%d: %w", id, err)
	}
	return &o, nil
}

// Get 是"纯透传"的层：不 wrap。否则日志里出现 "get order: get order: repo.Order.Get id=1: ..." 的冗余链。
func (s *Service) Get(ctx context.Context, id int64) (*Order, error) {
	return s.repo.Get(ctx, id)
}

// WriteFile 演示 defer Close 的错误合并：f.Close() 在写盘失败时才暴露 ENOSPC，丢掉它等于吞错。
func WriteFile(path string, data []byte) (err error) {
	f, err := os.Create(path)
	if err != nil {
		return err
	}
	defer func() { err = errors.Join(err, f.Close()) }()
	_, err = f.Write(data)
	return err
}

// HTTPStatus 演示 errors.AsType：无需先声明变量再取地址。
func HTTPStatus(err error) int {
	if ae, ok := errors.AsType[*apperror.AppError](err); ok {
		return ae.HTTP
	}
	return apperror.ErrInternal.HTTP
}
```

批处理部分失败不在第一个错误处中断：`errs = append(errs, fmt.Errorf("item %d: %w", id, err))` 后 `return errors.Join(errs...)`；`errors.Is/As` 会遍历 `Unwrap() []error` 树，Join 后仍可定位具体原因。`fmt.Errorf` 允许多个 `%w`（Go 1.20 起）。

## Gin 错误中间件：ctx 取消、request_id、不回显

```go
// ErrorBody 是所有非 2xx 响应的唯一形状。request_id 让用户报障时能直接定位到日志。
type ErrorBody struct {
	Code      int    `json:"code"`
	Message   string `json:"message"`
	RequestID string `json:"request_id,omitzero"`
}

// Errors 必须注册在业务中间件之前（它在 c.Next() 之后工作）。
// handler 里只做 `_ = c.Error(err); c.Abort(); return`，不自己写错误响应。
func Errors() gin.HandlerFunc {
	return func(c *gin.Context) {
		c.Next()
		if len(c.Errors) == 0 || c.Writer.Written() {
			return // handler 已写响应再写一次会触发 "superfluous response.WriteHeader" 并输出两段 body
		}
		err := c.Errors.Last().Err
		ctx := c.Request.Context()
		ae := apperror.From(err)
		fields := []zap.Field{zap.Int("code", ae.Code), zap.Int("status", ae.HTTP), zap.Error(err)}
		switch {
		case ae.HTTP == apperror.StatusClientClosedRequest || ae.HTTP == http.StatusGatewayTimeout:
			logger.WarnCtx(ctx, "request aborted", fields...) // 客户端断开/超时是噪音，不进 ERROR 告警
		case ae.HTTP >= http.StatusInternalServerError:
			logger.ErrorCtx(ctx, "request failed", fields...)
		default:
			logger.DebugCtx(ctx, "request rejected", fields...)
		}
		c.JSON(ae.HTTP, ErrorBody{Code: ae.Code, Message: ae.Message, RequestID: logger.RequestIDFromContext(ctx)})
	}
}

// Fail 是 handler 内统一的失败出口。
func Fail(c *gin.Context, err error) {
	_ = c.Error(err)
	c.Abort()
}
```

handler 侧：`if err != nil { ginmw.Fail(c, err); return }`。`c.Error` 有返回值，`_ =` 显式丢弃以过 errcheck。中间件不判 `c.Writer.Written()` 的后果：handler 已写 200 又 `c.Error` 时输出两段 body 并打印 `http: superfluous response.WriteHeader`。

## 跨服务错误映射

```go
// FromGRPC 把下游 gRPC 错误翻译为本服务的 AppError。
// 原则：下游的 Internal/Unknown 对终端用户是 502 "upstream error"，不透传下游文案（含内部主机名、SQL）。
func FromGRPC(err error) error {
	if err == nil {
		return nil
	}
	switch status.Code(err) {
	case codes.NotFound:
		return apperror.Wrap(apperror.ErrNotFound, err)
	case codes.AlreadyExists, codes.FailedPrecondition, codes.Aborted:
		return apperror.Wrap(apperror.ErrConflict, err)
	case codes.InvalidArgument:
		return apperror.Wrap(apperror.ErrInternal, err) // 我们发出了非法请求：是本服务的 bug，不是用户的
	case codes.Unauthenticated, codes.PermissionDenied:
		return apperror.Wrap(apperror.ErrInternal, err) // 服务间凭证问题同理
	case codes.ResourceExhausted:
		return apperror.Wrap(apperror.ErrTooManyRequests, err)
	case codes.DeadlineExceeded:
		return apperror.Wrap(apperror.ErrTimeout, err)
	case codes.Canceled:
		return apperror.Wrap(apperror.ErrClientClosed, err)
	case codes.Unavailable:
		return apperror.Wrap(apperror.ErrUnavailable, err)
	default:
		return apperror.Wrap(apperror.ErrUpstream, err)
	}
}
```

HTTP 下游同理（`downstream.FromHTTP`）：404/409/429/503/504 按语义映射；5xx → 502 `upstream error`；**其余 4xx 表示我们的调用有 bug，对用户是 500**，不能把下游的 400 文案当成用户输入错误返回。

## panic 边界

| 位置 | 谁兜底 | 不兜底的后果 |
|---|---|---|
| Gin handler 链 | `Recovery` 中间件（见 go-gin-api） | 500 + 栈 |
| handler 内 `go func(){}` | 自己 `recover` | **进程退出**，所有在途请求 502 |
| `errgroup.Group.Go` | `Protect` 包装 | 进程退出（x/sync v0.22.0 明确不传播 panic） |
| MQ 消费回调 / cron 任务 | 框架 recover 或 `Protect` | 消费者停摆、消息积压 |
| library 代码 | 不 panic，返回 error | 调用方无法预期 |

```go
// Go 是自起 goroutine 的唯一入口：handler 里 `go func(){...}()` 一旦 panic，gin.Recovery 管不到，进程直接退出。
func Go(ctx context.Context, task string, fn func(ctx context.Context) error) {
	go func() {
		defer func() {
			if r := recover(); r != nil {
				logger.ErrorCtx(ctx, "goroutine panic", zap.String("task", task), zap.Any("panic", r), zap.Stack("stack"))
			}
		}()
		if err := fn(ctx); err != nil {
			logger.ErrorCtx(ctx, "task failed", zap.String("task", task), zap.Error(err))
		}
	}()
}

// Protect 把 panic 转成 error，供 errgroup / MQ 消费回调 / cron 任务使用。
// x/sync v0.22.0 的 errgroup 明确不传播 panic（见其源码注释），worker 内 panic 同样会杀进程。
func Protect(fn func() error) func() error {
	return func() (err error) {
		defer func() {
			if r := recover(); r != nil {
				err = fmt.Errorf("panic: %v\n%s", r, debug.Stack())
			}
		}()
		return fn()
	}
}
```

用法：`g.Go(panics.Protect(func() error { return do(ctx, id) }))`；MQ 消费回调同样用 `Protect` 包一层再交给 SDK。

## 选型：哨兵 vs 自定义类型 vs 纯 wrap

| 场景 | 选择 | 理由 |
|---|---|---|
| 调用方只需分支（找不到 / 已关闭） | 哨兵 `*AppError` 变量 | `errors.Is` 一行判断，附带 Code/HTTP |
| 调用方需要读字段（哪个字段校验失败、Retry-After 多久） | 自定义类型 + `Unwrap` | `errors.AsType[T]` 取结构化数据 |
| 只需给日志加上下文 | `fmt.Errorf("...: %w")` | 不引入新类型；调用方不该对文案做分支 |
| 底层错误对调用方无意义（驱动内部错误） | 翻译为 `Wrap(ErrInternal, err)` | 防止驱动细节泄漏到响应 |

## lint 落地

`.golangci.yml` 启用：`errcheck`（未检查返回错误）、`errorlint`（`==` 比较哨兵、`err.(T)` 断言、`%v` 代替 `%w`）、`wrapcheck`（外部包错误在边界处未包装；本模块内部透传用 `ignorePackageGlobs` 放行）、`nilerr`（`if err != nil { return nil }`）。CI 门禁配置见 go-engineering-governance。

## 审查清单

- [ ] 每个 `fmt.Errorf` 都新增了下层没有的信息（操作名、主键、参数）；纯透传处没有 wrap
- [ ] 没有 `err == ErrX`、`err.(*T)`、`err.Error() == "..."`、`strings.Contains(err.Error(), ...)`
- [ ] 自定义错误类型有 `Unwrap()`；`*AppError` 的 `Is` 有 Wrap 后仍匹配的测试
- [ ] 错误码引用常量；类型位与 HTTP 状态一致；无复用的旧号
- [ ] 响应层只经 `apperror.From` 归一；5xx 文案固定，不含 `err.Error()`；含 `request_id`
- [ ] `context.Canceled`/`DeadlineExceeded` 走 499/504 + WARN
- [ ] 重试器只用 `IsRetryable`；业务 4xx 被 `Permanent` 或 Code 判为不可重试
- [ ] 所有 `go func` / errgroup / 消费回调有 `recover`；library 无 `panic`；`defer Close()` 错误用 `errors.Join` 合并
- [ ] `errcheck`/`errorlint`/`wrapcheck`/`nilerr` 在 CI 中为阻断级
