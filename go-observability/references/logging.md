# 日志：gtkit/logger/v2

以下是本仓库团队默认的 gtkit 参考，适用前提是项目已选择相应版本。已有 slog、zap 或其他日志契约的项目沿用原方案，实现同等的关联字段、脱敏与退出刷新；不照搬本例更换日志库。

main 里初始化一次，`TraceFields` 同时负责 trace ↔ log 关联：

```go
// TraceFields 交给 WithContextFields：每条 *Ctx 日志自动带 request_id / trace_id / span_id。
// 只读 ctx、不碰共享状态，因此并发安全（库要求该函数可被多个 goroutine 同时调用）。
func TraceFields(ctx context.Context) []zap.Field {
	fields := make([]zap.Field, 0, 3)
	if id := logger.RequestIDFromContext(ctx); id != "" {
		fields = append(fields, zap.String("request_id", id))
	}
	if sc := trace.SpanContextFromContext(ctx); sc.IsValid() {
		fields = append(fields,
			zap.String("trace_id", sc.TraceID().String()),
			zap.String("span_id", sc.SpanID().String()),
		)
	}
	return fields
}

// Init 在 main 里调用一次；返回值在进程退出前 defer 调用。
func Init(production bool) func() {
	level, console, jsonOut := "debug", true, false
	if production {
		level, console, jsonOut = "info", false, true
	}
	logger.SetDefault(logger.MustNew(
		logger.WithLevel(level),
		logger.WithOutJSON(jsonOut),
		logger.WithConsole(console),
		logger.WithFile(true),
		logger.WithPath("/var/log/app/app"),
		logger.WithDivision("daily"),
		logger.WithRedactKeys("password", "token", "authorization", "id_card", "phone"),
		logger.WithSampling(100, 100),
		logger.WithContextFields(TraceFields),
		logger.WithChannel("audit", logger.WithChannelPath("/var/log/app/audit")),
	))
	return logger.Sync
}
```

| 选项 | 作用（v2.3.0，`go doc` 核对） |
|---|---|
| `WithLevel("info")` | debug / info / warn / error / dpanic / panic / fatal，默认 info；实例 `SetLevel` 可运行期调整 |
| `WithOutJSON(true)` | JSON 编码，默认 false（console 编码）；生产必开，聚合系统才能按字段检索 |
| `WithConsole(true)` | 同时写 stdout，默认 false |
| `WithFile(true)` | 写文件，默认 true |
| `WithPath(p)` | 文件路径前缀，最终 `{path}-{level}.log`，默认 `./logs/` |
| `WithDivision("daily")` | 切割方式 size / daily / both，默认 both |
| `WithRedactKeys(keys...)` | 命中 Key 的结构化字段值替换为 `[REDACTED]`；大小写敏感精确匹配；只作用于结构化字段，拼进 message 的文本不管 |
| `WithSampling(first, thereafter)` | 每 1 秒窗口内，相同 level+message 前 `first` 条全记，之后每 `thereafter` 条记 1 条；`first<=0` 回退为 1，`thereafter==0` 表示首批之后全部丢弃。按 message 文本去重，所以 message 必须固定、变量进字段 |
| `WithContextFields(fn)` | 注册从 ctx 提取字段的函数，`*Ctx` 系列自动合并；fn 必须并发安全 |
| `WithChannel(name, WithChannelPath(p))` | 独立文件路由（audit / access），继承切割与脱敏配置；`logger.Default().Channel("audit")` 取用 |

调用点：`logger.InfoCtx(ctx, "order created", zap.Int64("order_id", id))`；sugar 风格 `logger.ErrorwCtx(ctx, "payment failed", "order_id", id, "error", err)`；`logger.LogIfCtx(ctx, err)`；`logger.Fatal` 只在 main 初始化阶段。

### 字段规范

| 字段 | 规则 |
|---|---|
| 命名 | snake_case；跨服务同名同义（`order_id` 不写成 `orderId` / `oid`），否则聚合查询要写 N 个 OR |
| `error` | 固定名，用 `zap.Error(err)`；不把 err 拼进 message，否则采样失效、也无法按错误类型聚合 |
| `request_id` / `trace_id` / `span_id` | 由 `TraceFields` 注入，业务代码不写 |
| `user_id` | 内部数字 ID 可记；手机号、邮箱、身份证、token 不记，其键名列进 `WithRedactKeys` |
| `elapsed` | `zap.Duration`，默认编码为秒（浮点）；全仓统一，不混用毫秒整数 |
| message | 固定文案（"order created"），变量全部进字段 |

级别规则沿用项目约定：同一错误只在最外层记一次，内层 `return err` 透传。gtkit 示例中 ERROR 用于请求失败，WARN 用于降级、慢 SQL 或业务拒绝；取消和超时按 go-context 核对来源，已确认的客户端主动取消与本服务/下游超时分别处理，不因错误类型一律降为 WARN 或排除 SLO 告警。INFO 用于业务事件与访问日志；DEBUG 的生产开关与 FATAL 的退出策略按项目进程生命周期确定。

成本：每请求一条 300 字节的 INFO，1 万 QPS × 86400 秒 ≈ 260 GB/天（未压缩），留 30 天是 7.8 TB。所以访问日志 message 固定 + `WithSampling`，循环体内不记日志，请求 / 响应体不进生产日志。
