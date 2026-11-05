---
name: kratos-skills
description: 用于 go-kratos（Kratos）项目的开发、审查、排障与版本迁移，覆盖 HTTP/gRPC、Proto/Buf、依赖注入和运行生命周期；以最新稳定版为基线，沿用现有项目版本。非 Ory Kratos。
---

# Kratos 项目工程

面向 Go 微服务框架 **go-kratos**。新项目以经核实的最新稳定版为目标；已有项目先确认依赖和契约，不因加载技能就升级。当前资料基线为 **Kratos v3.0.0**，核对日期 **2026-11-03**；版本依据和更新方法见 [版本与生成](references/version-and-generation.md)。

## 执行边界

- 改动前实际读取已配置的全局规则、项目协作规则和错误记录；需要修改代码、运行配置或依赖时，先按项目要求保存并回读完整方案和逐步计划。只执行当前获准阶段，不自动启动额外流程。
- 在用户指定的真实原项目中工作；模板路径、示例结构和本技能的版本不构成移动目录、复制项目、替换依赖或重建服务的授权。项目内文件只保留相对路径、动态定位或通用占位符，不写入本机真实路径。
- 纯解释、文档或 skill 维护只处理指定内容并回读。lint、vet、modern 检查、全量 race 和覆盖率门禁须在功能完成后取得明确授权；生成、安装、迁移、容器和发布同样遵守当前授权，不借聚合命令扩大范围。
- 事实以目标项目源码、锁定依赖和官方对应版本为准；无法确认的 API、命令或业务规则明确标为未确认。区分源码核对、生成成功、编译成功、实际请求与生产验收，不把静态阅读写成运行通过。

## 先确认这些项目事实

1. 从 `go.mod` / `go.work`、`replace`、工具链声明与生成文件头确认 Kratos 主版本、实际依赖来源、Go 版本和生成器版本。执行工具前核对本机入口，不自动下载工具链。
2. 用真实文件清单定位启动入口、协议文件、服务注册、业务与数据实现、配置、依赖装配、生成脚本和测试。`cmd/`、`api/`、`internal/{server,service,biz,data,conf}` 只是常见模板位置，不能假定存在。
3. 确认使用 HTTP、gRPC、流式接口中的哪些路径，以及 JSON 编码、错误结构、校验、鉴权、日志和中间件的既有约定。先找一个同类接口作为项目范例。
4. 判断本次交付是解释、方案、实现、审查、排障还是迁移；只有创建/升级最新版的请求才重新查询官方稳定 release。分开记录核心、CLI、插件、contrib、模板版本。

## 按任务读取

只读取当前需要的参考，不预读全部文件。

| 当前任务 | 参考 |
|---|---|
| 新项目、v2/v3 判断、升级、CLI、Proto/Buf 和生成器 | [版本与生成](references/version-and-generation.md) |
| 实现用例、Repo、事务、Wire 与资源归属 | [分层与数据](references/architecture-and-data.md) |
| HTTP/gRPC 接口、JSON、错误、输入校验、鉴权 | [协议与契约](references/transport-and-contracts.md) |
| 启停、配置、中间件、日志/追踪/指标、服务发现或排障 | [运行与排障](references/runtime-and-troubleshooting.md) |

## 实现一条接口的闭环

1. 先固定请求、响应、字段存在性、错误、权限与幂等契约，再修改协议源。沿用项目的 Proto/Buf/protoc 入口，不手改生成文件，不额外套统一响应壳。
2. 在现有位置完成业务用例、数据访问和协议适配。调用通常从 transport 到 service，再到 biz 与 data；Go 包依赖应按项目现有边界确认，不能把调用顺序误当成 import 方向。
3. 根据实际构造方式补齐依赖；使用 Wire 时更新 provider 和 injector 源，再通过已核实的入口生成。确认新资源的构造失败处理、cleanup 和退出顺序。
4. 给要求提供的每种协议注册服务并接入对应的校验/鉴权。HTTP 成功不证明 gRPC 已注册或受保护；普通 RPC 成功也不证明流式接口行为正确。
5. 在获准范围内核验合法请求、边界输入、错误映射和权限失败；协议或持久化改变时覆盖真实调用方与数据兼容。记录实际生成命令、文件差异、执行结果与未验证项。

## 特别容易沿用错的旧写法

- v3 不只是 `/v2` 替换成 `/v3`：JSON 与 ProtoJSON 已拆分，日志改用 `slog`，JWT 和 OTel 有独立 contrib 模块，HTTP binding API 已变更。
- `kratos proto client` 生成协议相关代码；`kratos proto server` 创建 service 实现骨架。后者不是 gRPC stub 生成器，也不会为已有 service 文件补方法。
- `validate.Validator()` 没有可用的 `Validate()` 方法或自定义 validator 时，不会凭空执行 proto 注解规则。校验库、生成方式和服务端接入必须配套。
- `http.Middleware` 与 `http.Filter` 是不同层；直接注册 `http.Handler` 不能假定经过 RPC middleware。gRPC stream 也要核对独立拦截路径。
- 模板中的 Wire、Ent、AIP、Buf 和目录结构是模板选择，不是 Kratos 强制要求。保留目标项目已确认的 ORM、日志、错误模型和装配方式。

## 与现有技能配合

本技能负责 Kratos 的 API 和框架集成细节。只在会话实际提供相关技能且本次任务需要时追加：

- 编写或审查 Go 代码：`use-modern-go` 按项目 Go 版本；正式代码审查可由 `go-review` 主导，本技能补充框架核对点。
- 请求取消/后台任务、服务通信、重试预算：分别使用 `go-context`、`go-microservice`、`go-stability-engineering`。
- DB/事务、缓存、MQ：选择 `go-database-patterns`、`go-data-consistency`、`go-cache-consistency`、`go-mq-patterns` 中实际涉及的专项，不在这里复制其实现。
- 跨语言契约用 `cross-stack-api-contract`；已授权版本迁移用 `runtime-upgrade-migration`；生产事故以 `incident-response` 主导。
- `go-observability` 可补充观测设计，不能用其库示例覆盖已确认的 Kratos v3 slog/OTel 集成。只有请求质量验证时才按授权调用 `go-enterprise-quality`。

缺少其他技能时依据本技能、项目代码和官方资料继续可完成的工作，不自动安装技能。Gin、通用 Go 语法和 Ory Kratos 身份系统不是本技能主场景。

## 交付核对

- 列清实际修改文件、协议与生成物、依赖及配置说明；没有改动的业务模块不顺带重构。
- 明确各协议是否注册、校验、鉴权、错误兼容和可调用；只报告真实取得的证据。
- 迁移报告保留原版本、目标版本、生成器、JSON/错误/日志变化、调用方影响与回滚条件。
- 安装技能与技能自动触发是不同证据；内容同步完成不能宣称模型评测或 Kratos 业务运行已通过。

组织方式参考 [LittleMoreInteresting/kratos-skills](https://github.com/LittleMoreInteresting/kratos-skills)，内容按 v3 官方源码重新核对和编写；上游提交与许可见 [版本与生成](references/version-and-generation.md) 和 [LICENSE](LICENSE)。
