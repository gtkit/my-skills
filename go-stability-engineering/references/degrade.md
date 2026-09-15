# 降级与预案

```go
// WithFallback：主路径失败或开关强制降级时走兜底（静态默认值、上次缓存、异步补偿）。
// 兜底结果必须在响应里可辨认（如 degraded=true），否则排障时分不清"真数据"与"兜底数据"。
func WithFallback[T any](ctx context.Context, force *Switch, primary func(ctx context.Context) (T, error), fallback func(ctx context.Context) (T, error)) (T, bool, error) {
	if force != nil && force.On() {
		v, err := fallback(ctx)
		return v, true, err
	}
	v, err := primary(ctx)
	if err == nil {
		return v, false, nil
	}
	if ctx.Err() != nil {
		return v, false, err // 调用方已放弃，兜底也没人收
	}
	logger.WarnCtx(ctx, "primary failed, using fallback", zap.Error(err))
	fv, ferr := fallback(ctx)
	return fv, true, ferr
}
```

| 手段 | 适用 | 约束 |
|---|---|---|
| 功能开关（配置中心热更新） | 非核心功能一键关（推荐、评论、导出） | 开关变更要有审计与自动过期 |
| 静态兜底 | 配置、类目、默认推荐位 | 兜底数据要有版本与更新流程 |
| 读缓存降级 | DB 抖动时只读缓存（可能过期） | 响应标 `degraded`，写路径不能走这里 |
| 写异步化 | 下游不可用时先落本地队列/MQ 再补偿 | 需要幂等键与补偿任务（见 go-mq-patterns） |

预案表每条四列：触发条件（可观测指标 + 阈值）→ 动作（开关名/命令）→ 回滚方式 → 负责人。没有回滚方式的预案不上线；预案每季度演练一次，演练不通过的预案视为不存在。
