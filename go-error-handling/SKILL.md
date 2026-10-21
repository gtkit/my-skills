---
name: go-error-handling
description: Go 错误处理：项目错误契约与 AppError 参考、错误码与 HTTP 映射、重试分类、取消、errors.Join、panic 和 wrap 边界。设计或审查错误类型、响应及重试判定时使用。
allowed-tools: "Read, Write, Edit, Bash, Glob, Grep"
---

# Go 错误处理

## 前置必读：拒绝猜测与改动边界

- 每次使用本 skill、恢复任务及执行任何改动前，先实际读取本节、当前运行环境已配置的全局规则，以及目标项目已有的协作规则和错误记录。按已明确的配置入口定位，不猜路径、不硬编码本机目录，不以记忆或摘要替代；必需规则无法读取时停止改动并说明。
- 需求、接口、字段、权限、默认值、路径、工具能力、依赖与兼容结论必须有用户指令、已读取源码/配置、已核实官方资料或真实执行证据。未知保持未确认，先核实；仍不明确就停止依赖该信息的步骤，不凭猜测补全，不重复询问已经明确的要求。
- 修改代码前先完成并落盘方案和逐步计划，写清范围、文件、兼容约束、风险、回滚和验收；只执行获准范围及阶段。计划、候选原因和未执行步骤标为待验证，不能当作事实或已完成结果。
- 只有真实执行并回读后才能报告完成或通过，区分失败、未执行、未验证和不适用；模拟与静态证据不冒充真实链路。纯文档、注释、规则或 skill 说明任务只编辑指定内容并回读，不因本 skill 的流程扩展为测试、构建、同步、打包或 OpenSpec 操作。

提供业务错误与分类的统一指导。目标项目已有错误类型、错误码、响应形状和重试接口时沿用其契约；`*AppError`、`apperror.From`、`IsRetryable` / `Permanent` 是本仓库团队默认参考，不要求其他项目改成同名模型。go-gin-api / go-microservice 采用这套示例时引用同一实现，不各定义一份。

## 核心规则

1. 只在**增加信息**时 `fmt.Errorf("op key=%v: %w", ..., err)`；纯透传 `return err`。每层都 wrap 会产生 `get order: get order: ...` 冗余链。
2. 哨兵用 `errors.Is`，类型用 `errors.AsType[T]`（Go 1.26 起）；`==` 与 `err.(T)` 在包装后必失效。
3. 需要保留底层错误链的自定义类型实现 `Unwrap()`。本仓库 `*AppError` 示例通过 `Is(target)` 按 `Code` 比较——`Wrap` 返回新指针，没有 `Is` 时 `errors.Is(Wrap(ErrNotFound, e), ErrNotFound)` 为 false（沿用 Go 1.27 实测记录）。项目已有模型按其身份与包装契约核对，不强制重命名。
4. 5xx 响应绝不带 `err.Error()` 原文；错误响应体带 `request_id`。
5. 按 go-context 区分取消来源与超时预算，再遵守项目 HTTP/gRPC 与 SLO 契约；本仓库响应示例使用 499/504，但不能据状态码把服务或下游超时一律降为噪音。
6. 重试与熔断通过项目统一分类接口判定；本仓库示例为 `IsRetryable(err)` / `Permanent()`。状态码或超时不足以独立授权重试，仍需幂等语义、有效总预算和对应失败分类；已取消的操作不继续重试。
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
- [ ] 需暴露底层错误链的类型有 `Unwrap()`；采用 `*AppError` 示例时其 `Is` 有 Wrap 后仍匹配的测试
- [ ] 错误码引用常量；类型位与 HTTP 状态一致；无复用的旧号
- [ ] 响应层经项目统一适配归一（本仓库示例为 `apperror.From`）；5xx 不含 `err.Error()`；含 `request_id`
- [ ] 取消来源、超时故障计数、响应与日志级别遵守项目契约；未把所有取消/超时一律忽略
- [ ] 重试与熔断统一分类，且重试具备幂等语义与总预算；未以状态码作为唯一依据
- [ ] 所有 `go func` / errgroup / 消费回调有 `recover`；library 无 `panic`；`defer Close()` 错误用 `errors.Join` 合并
- [ ] `errcheck`/`errorlint`/`wrapcheck`/`nilerr` 在 CI 中为阻断级
