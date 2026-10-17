# Vue 异步请求与 API 边界

## 请求生命周期

把每次请求看成 `created → active → succeeded | failed | cancelled`，并把查询输入（租户、用户、筛选、分页、排序）放进请求键。新请求开始时使旧序号失效；清空、登出、租户切换、路由离开和卸载都要取消或丢弃旧请求。

```ts
let requestSeq = 0
let controller: AbortController | undefined

async function loadRows(query: string, tenantId: string) {
  const seq = ++requestSeq
  controller?.abort()
  controller = new AbortController()
  if (!query.trim()) {
    rows.value = []
    return
  }
  try {
    const result = await api.search({ query, tenantId }, controller.signal)
    if (seq !== requestSeq || tenantId !== activeTenantId.value) return
    rows.value = result
  } catch (error) {
    if (controller.signal.aborted || seq !== requestSeq) return
    errorState.value = normalizeApiError(error)
  }
}
```

生产代码使用 query library 时，把 `tenantId` 和查询参数放入 key，并确认 query function 真的把 `signal` 交给 HTTP 客户端；只在组件侧隐藏过期结果而不取消请求会继续占用连接和服务端资源。

## 401 刷新

- 原请求只允许一次刷新后重试；刷新请求本身失败、重复 401 或会话已切换时清理认证状态。
- 刷新并发必须单飞，共享同一个 Promise；不能每个请求各自刷新，也不能无界重试。
- 重试请求必须复用原始请求体的可重放表示；流式/一次性 body 要先设计重放策略。

## API 适配

- 传输 DTO 和领域模型分离；服务器新增字段默认不应使旧客户端崩溃，关键字段缺失要显式失败。
- 统一处理 `401/403/404/409/422/429/5xx`，把字段级校验错误映射到表单，把 request id 留在错误报告中。
- 客户端显示的权限、价格、库存和状态只是提示；提交时必须以服务端响应为准，并能处理服务端拒绝后的回滚。
