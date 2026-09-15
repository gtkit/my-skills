---
name: go-observability
description: Go 日志/metrics/tracing 的唯一实现处：gtkit/logger 初始化与字段规范、request_id 与访问日志中间件、OpenTelemetry 接入、Prometheus RED 指标、慢 SQL、SLO 告警。接日志、埋点、trace 或写这些中间件时使用。
allowed-tools: "Read, Write, Edit, Bash, Glob, Grep"
---

# Go 可观测性

日志、metrics、tracing 的初始化与 Gin 中间件只在这里实现一次，其他 skill 只引用。目标是一条链路：告警 → P99 曲线 → exemplar 跳到 trace → 用 trace_id 捞出这条请求在所有服务的日志。

## 核心规则

1. 日志库只有 `github.com/gtkit/logger/v2`（底层 zap，字段构造器沿用 `zap.String` 等）。调用点用包级 `*Ctx` 函数，不传 logger 实例，不把 `*zap.Logger` 当参数类型。
2. `request_id` / `trace_id` / `span_id` 由 `WithContextFields` 注入，业务代码不手写这三个字段。
3. 不调 `otel.SetTracerProvider`，`otel.Tracer` 返回 no-op，span 全部静默丢弃（Go 1.27 + otel v1.46 实测：`SpanContext().IsValid()==false`，TraceID 全 0）；不调 `otel.SetTextMapPropagator`，本地 span 正常但出站不带 `traceparent`，跨服务链路断在这里。两者都不报错。
4. metric label 值域必须有限可枚举；每个 label 组合是一条独立时间序列。user_id / URL 原文 / IP / order_id 永远不做 label。
5. metrics 用 `prometheus.NewRegistry()` + `promauto.With(reg)`，不碰默认注册表。
6. 自动埋点（otelgin / otelhttp / otelgrpc / otelgorm / redisotel）优先；手写 span 只放业务边界。
7. 5xx 与慢请求 100% 留痕：日志侧 ERROR / WARN 单独 message 不被采样淹没，trace 侧靠 Collector tail sampling 保留；正常请求按比例采。
8. 结构化字段里不放 PII；`WithRedactKeys` 是兜底不是许可。
9. 慢 SQL 通过 GORM `logger.Interface` 适配器接 gtkit，日志里的 SQL 只含 `?` 占位符。

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
| 客户端已取消的请求 | WARN，不 ERROR，不触发告警 | 不是服务故障，进 ERROR 会淹没真告警 |
| 按用户 / 订单维度看指标 | 查日志或 trace，不加 label | 高基数直接压垮 Prometheus |
| health check 路由 | 访问日志与 metrics 中间件跳过 `/livez` `/readyz` | 探针每秒来一次，全是噪音 |

## 审查清单

- [ ] 日志只 import `github.com/gtkit/logger/v2` + `go.uber.org/zap`（字段）；没有 `log`、`log/slog`、`*zap.Logger` 参数
- [ ] `WithContextFields` 注入了 request_id / trace_id / span_id，业务代码里 grep 不到手写这三个字段
- [ ] main 里 `otelsetup.Init` 与 `otel.SetTextMapPropagator` 都执行了；随手起一个 span 检查 `SpanContext().IsValid()` 为 true
- [ ] 中间件顺序：otelgin → RequestID → AccessLog → metrics；request_id 写进 `c.Request.Context()` 而不只 `c.Set`
- [ ] 出站 HTTP 用 `otelhttp.NewTransport`，gRPC 用 `otelgrpc.NewServerHandler/NewClientHandler`，GORM / Redis 插件已 `Use` / `InstrumentTracing`
- [ ] 所有 label 值域可枚举：route 用 `FullPath()` 且空串映射 `unmatched`，method 有白名单，没有 user_id / IP / URL 原文 / 错误文本
- [ ] metrics 注册用 `promauto.With(reg)` + 独立 registry；`/metrics` 与 pprof 在独立 admin 端口
- [ ] `WithRedactKeys` 覆盖 password / token / authorization / id_card / phone；高频日志 message 固定、无变量拼接（否则 `WithSampling` 失效）
- [ ] 慢 SQL 日志的 SQL 只含 `?`（`ParamsFilter` 或 `WithoutQueryVariables`）；GORM 回调用 `InstanceGet` 带 ok 断言
- [ ] histogram bucket 在 SLO 目标附近有边界；告警基于 SLI 多窗口 burn rate，不是单点阈值
- [ ] `logger.Sync()` 与 tracing `shutdown(ctx)` 都在 `srv.Shutdown` 之后执行
