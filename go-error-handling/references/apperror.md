# AppError 与错误码

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
