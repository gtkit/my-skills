---
name: go-observability
description: Go 日志、metrics 与 tracing：沿用项目日志约定，提供 gtkit/logger 参考、请求关联、OpenTelemetry、Prometheus 和 SLO 告警。接入或审查可观测性时使用。
allowed-tools: "Read, Write, Edit, Bash, Glob, Grep"
---

# Go 可观测性

## 前置必读：拒绝猜测与改动边界

- 每次使用本 skill、恢复任务及执行任何改动前，先实际读取本节、当前运行环境已配置的全局规则，以及目标项目已有的协作规则和错误记录。按已明确的配置入口定位，不猜路径、不硬编码本机目录，不以记忆或摘要替代；必需规则无法读取时停止改动并说明。
- 需求、接口、字段、权限、默认值、路径、工具能力、依赖与兼容结论必须有用户指令、已读取源码/配置、已核实官方资料或真实执行证据。未知保持未确认，先核实；仍不明确就停止依赖该信息的步骤，不凭猜测补全，不重复询问已经明确的要求。
- 修改代码前先完成并落盘方案和逐步计划，写清范围、文件、兼容约束、风险、回滚和验收；只执行获准范围及阶段。计划、候选原因和未执行步骤标为待验证，不能当作事实或已完成结果。
- 只有真实执行并回读后才能报告完成或通过，区分失败、未执行、未验证和不适用；模拟与静态证据不冒充真实链路。纯文档、注释、规则或 skill 说明任务只编辑指定内容并回读，不因本 skill 的流程扩展为测试、构建、同步、打包或 OpenSpec 操作。

日志、metrics、tracing 的初始化与 Gin 中间件只在这里实现一次，其他 skill 只引用。目标是一条链路：告警 → P99 曲线 → exemplar 跳到 trace → 用 trace_id 捞出这条请求在所有服务的日志。

本仓库的团队默认与代码示例采用 gtkit；目标项目已有日志库、依赖注入和字段契约时，沿用它们并实现等价的关联、脱敏与刷新能力。下文的 gtkit API 名称只适用于采用该方案的项目，不构成替换现有日志库或升级依赖的授权。

## 核心规则

1. 优先项目已确认的日志契约。采用 gtkit 时，major 沿用 `go.mod`，本仓库参考使用 `/v2` + zap 字段和包级 `*Ctx` 函数；未引用时先按项目依赖政策确定版本，不使用“最新 major”作为默认值，不在无关任务里引入或升级依赖。
2. `request_id` / `trace_id` / `span_id` 在项目统一的日志适配层注入；gtkit 示例用 `WithContextFields`，业务代码不重复手写这些字段。
3. 不调 `otel.SetTracerProvider`，`otel.Tracer` 返回 no-op，span 全部静默丢弃（Go 1.27 + otel v1.46 实测：`SpanContext().IsValid()==false`，TraceID 全 0）；不调 `otel.SetTextMapPropagator`，本地 span 正常但出站不带 `traceparent`，跨服务链路断在这里。两者都不报错。
4. metric label 值域必须有限可枚举；每个 label 组合是一条独立时间序列。user_id / URL 原文 / IP / order_id 永远不做 label。
5. metrics 用 `prometheus.NewRegistry()` + `promauto.With(reg)`，不碰默认注册表。
6. 自动埋点（otelgin / otelhttp / otelgrpc / otelgorm / redisotel）优先；手写 span 只放业务边界。
7. 5xx 与慢请求 100% 留痕：日志侧 ERROR / WARN 单独 message 不被采样淹没，trace 侧靠 Collector tail sampling 保留；正常请求按比例采。
8. 结构化字段里不放 PII；`WithRedactKeys` 是兜底不是许可。
9. 慢 SQL 通过 GORM `logger.Interface` 适配器接项目日志方案；gtkit 适配见参考，日志里的 SQL 使用占位符而不包含实参。

## 按任务读取

以下内容按任务读取，只读本次需要的文件；核心规则与审查清单已覆盖其结论。

| 任务 | 读 |
|---|---|
| 初始化 gtkit/logger/v2、选项、`*Ctx` 调用与字段规范 | `references/logging.md` |
| 写或接入 request_id、访问日志中间件 | `references/middleware.md` |
| 接 OpenTelemetry：TracerProvider、OTLP、otelgin/otelhttp/otelgrpc/otelgorm、采样 | `references/tracing.md` |
| Prometheus RED 指标、label 基数、exemplar、runtime 指标 | `references/metrics.md` |
| 慢 SQL 日志与指标 | `references/slow-sql.md` |

## SLO 与告警

```promql
# P99 延迟（按路由）
histogram_quantile(0.99, sum by (le, route) (rate(http_request_duration_seconds_bucket[5m])))
# 错误率 SLI（5xx 占比）
sum(rate(http_requests_total{status=~"5.."}[5m])) / sum(rate(http_requests_total[5m]))
# 多窗口 burn rate：30 天 99.9% SLO，1h 窗口烧掉 2% 预算（14.4×）且 5m 窗口同时超标才告警，避免尖刺误报
(error_ratio_1h > 14.4 * 0.001 and error_ratio_5m > 14.4 * 0.001)
  or (error_ratio_6h > 6 * 0.001 and error_ratio_30m > 6 * 0.001)
```

`error_ratio_*` 用 recording rule 预先算好。告警只挂 SLI（错误率、延迟），原因指标（CPU、连接数）进 dashboard 用于定位。错误预算、告警分级与降级策略见 go-stability-engineering。

## 何时不该记 / 不该做 label

| 场景 | 做法 | 理由 |
|---|---|---|
| 循环体 / 每条消息一行 INFO | 循环外汇总一条，或 DEBUG | 10 万条/秒的日志先打爆磁盘再打爆采集 agent |
| 请求 / 响应体 | 不记；排障用 trace 的 event 或抓包 | 体积大且几乎必含 PII |
| 已确认由客户端主动取消的请求 | 按项目约定记录取消来源；与服务超时分别计数 | 不把本服务预算耗尽或下游超时误归为客户端取消并丢弃告警 |
| 按用户 / 订单维度看指标 | 查日志或 trace，不加 label | 高基数直接压垮 Prometheus |
| health check 路由 | 访问日志与 metrics 中间件跳过 `/livez` `/readyz` | 探针每秒来一次，全是噪音 |

## 审查清单

- [ ] 日志库、版本与装配遵守项目约定；gtkit 项目沿用已确认的 major 和包级函数，未擅自迁移其他日志方案
- [ ] 统一适配层注入 request_id / trace_id / span_id（gtkit 使用 `WithContextFields`），业务代码未重复拼装
- [ ] main 里 `otelsetup.Init` 与 `otel.SetTextMapPropagator` 都执行了；随手起一个 span 检查 `SpanContext().IsValid()` 为 true
- [ ] 中间件顺序：otelgin → RequestID → AccessLog → metrics；request_id 写进 `c.Request.Context()` 而不只 `c.Set`
- [ ] 出站 HTTP 用 `otelhttp.NewTransport`，gRPC 用 `otelgrpc.NewServerHandler/NewClientHandler`，GORM / Redis 插件已 `Use` / `InstrumentTracing`
- [ ] 所有 label 值域可枚举：route 用 `FullPath()` 且空串映射 `unmatched`，method 有白名单，没有 user_id / IP / URL 原文 / 错误文本
- [ ] metrics 注册用 `promauto.With(reg)` + 独立 registry；`/metrics` 与 pprof 在独立 admin 端口
- [ ] `WithRedactKeys` 覆盖 password / token / authorization / id_card / phone；高频日志 message 固定、无变量拼接（否则 `WithSampling` 失效）
- [ ] 慢 SQL 日志的 SQL 只含 `?`（`ParamsFilter` 或 `WithoutQueryVariables`）；GORM 回调用 `InstanceGet` 带 ok 断言
- [ ] histogram bucket 在 SLO 目标附近有边界；告警基于 SLI 多窗口 burn rate，不是单点阈值
- [ ] `logger.Sync()` 与 tracing `shutdown(ctx)` 都在 `srv.Shutdown` 之后执行
