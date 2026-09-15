# 限流

| 算法 | 实现 | 特性 | 选择 |
|---|---|---|---|
| 令牌桶 | `golang.org/x/time/rate` | 允许突发到 burst；单机、无锁竞争小 | 单实例保护自身、按 key 限流 |
| 滑动窗口 | Redis Lua（见 go-redis-patterns） | 集群共享配额、精确到窗口 | 多实例共享用户/租户配额 |
| 漏桶 | `rate.Limiter.Wait` 或队列 + 固定速率消费 | 输出恒定速率、平滑突发 | 对下游有恒定速率要求（短信、第三方 API） |
| 自适应 | CPU/RT 反馈（sentinel-golang 系统规则、kratos BBR） | 无需预设阈值；按 inflight 与 minRT×maxPass 估算容量 | 流量形态不可预测、混部机器 |

```go
// PerKey 为每个 key（IP、租户、API key）维护一个令牌桶。
// 用带 TTL 的 LRU 而不是 map：map 永不淘汰，攻击者换 IP 打一遍就把内存打满——限流器自己成了 DoS 面。
type PerKey struct {
	mu    sync.Mutex
	cache *expirable.LRU[string, *rate.Limiter]
	r     rate.Limit
	burst int
}

func NewPerKey(r rate.Limit, burst, maxKeys int, idle time.Duration) *PerKey {
	return &PerKey{cache: expirable.NewLRU[string, *rate.Limiter](maxKeys, nil, idle), r: r, burst: burst}
}

func (p *PerKey) get(key string) *rate.Limiter {
	p.mu.Lock() // Get+Add 不是一个原子操作，并发下同一 key 会建两个桶
	defer p.mu.Unlock()
	if l, ok := p.cache.Get(key); ok {
		return l
	}
	l := rate.NewLimiter(p.r, p.burst)
	p.cache.Add(key, l)
	return l
}

func (p *PerKey) Allow(key string) bool { return p.get(key).Allow() }
```

按 IP 限流的两个坑：`c.ClientIP()` 只有在 `SetTrustedProxies` 配对了才读 `X-Forwarded-For`，否则伪造头就能把限流打到别人身上，或全部用户共用一个代理 IP 的桶；限流器 map 不淘汰，攻击者换 IP 扫一遍就把内存打满。超限返回 429 + `Retry-After`（`retryAfterSeconds` 用 `math.Ceil(1/r)`，`r<1` 时整数除法会除零 panic）。`rate.Limiter` 零值拒绝一切请求（go doc），配置读取失败时不要落到零值；`NewPerKey` 的 `maxKeys` ≤ 0 时 `expirable.NewLRU` 视为无上限（go doc），恰好退化成被警告的无界 map，配置缺省同样不得落到 0。
