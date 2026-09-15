# SLO、错误预算与告警分级

- SLI = 好事件 / 全部事件（如非 5xx 且延迟 < 300ms 的请求占比）。SLO 是 SLI 的目标值与窗口（30 天滚动）。错误预算 = 1 − SLO：99.9%/30 天 = 43.2 分钟，99.95% = 21.6 分钟，99.99% = 4.3 分钟。
- 燃烧率 = 实际错误率 / (1 − SLO)。1× 表示刚好在窗口末用完预算；SLO 99.9% 时 14.4× 对应错误率 1.44%。
- 多窗口多燃烧率告警：长窗口判"确实在烧"，短窗口判"还在烧"，两者同时满足才告警，避免恢复后仍呼叫。

| 燃烧率 | 长窗口 | 短窗口 | 消耗预算 | 动作 |
|-------|-------|-------|---------|------|
| 14.4× | 1h | 5m | 2% | 呼叫 on-call |
| 6× | 6h | 30m | 5% | 呼叫 on-call |
| 3× | 1d | 2h | 10% | 工单，次日处理 |
| 1× | 3d | 6h | 10% | 工单，周会讨论 |

```yaml
# Prometheus 规则：SLO 99.9%，14.4× 一档
- alert: ApiErrorBudgetBurnFast
  expr: |
    (sum(rate(http_requests_total{job="api",code=~"5.."}[1h])) / sum(rate(http_requests_total{job="api"}[1h]))) > (14.4 * 0.001)
    and
    (sum(rate(http_requests_total{job="api",code=~"5.."}[5m])) / sum(rate(http_requests_total{job="api"}[5m]))) > (14.4 * 0.001)
  for: 2m
  labels: { severity: page }
  annotations: { runbook: "https://runbooks.example.com/api-5xx" }
```

- 告警等级：`page`（SLO 燃烧、用户可见故障，15 分钟内响应）、`ticket`（容量趋势、证书 14 天内到期、备份失败）、仅仪表盘（CPU/内存等原因类指标）。每条 page 必附 runbook；连续 3 次触发无人动作即删除或降级。on-call 主备两人轮值一周，一周被 page 超过约 10 次说明该修系统或告警，不是加人。
- 事故等级：SEV1 = 核心功能对多数用户不可用或数据丢失（立即拉群、指定指挥官、每 30 分钟对外通报）；SEV2 = 部分功能受损或预算快速燃烧（30 分钟内响应）；SEV3 = 有绕过方案的降级（工作时间处理）。SEV1/2 在 5 个工作日内完成免责复盘，行动项有 owner 与截止日。
