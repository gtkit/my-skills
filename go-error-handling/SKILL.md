---
name: go-error-handling
description: Go 错误处理：AppError 类型、错误码分段与 HTTP 状态映射、可重试分类、ctx 取消映射、errors.Join、panic 与 wrap 边界。设计错误类型、错误码体系、统一错误响应或重试判定时使用。
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

## 按任务读取

以下内容按任务读取，只读本次需要的文件；核心规则与审查清单已覆盖其结论。

| 任务 | 读 |
|---|---|
| 定义 AppError 类型、错误码分段与哨兵错误 | `references/apperror.md` |
| 做可重试判定、给错误分类 | `references/classify.md` |
| 决定在哪层 wrap、用 errors.Join / AsType | `references/wrap.md` |
| 写统一错误响应中间件、映射跨服务错误 | `references/middleware.md` |
| 设置 panic 边界与 recover | `references/panic.md` |

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
