---
name: go-stability-engineering
description: Go 服务稳定性工程：超时预算与逐跳递减、重试（退避/抖动/预算/单层重试）、熔断（sony/gobreaker/v2）、限流（令牌桶/滑动窗口/漏桶、单机 vs 分布式、自适应）、隔仓与背压、负载卸载、降级与预案、灰度/金丝雀/自动回滚、k8s 发布时序、SLO/错误预算/多窗口 burn-rate 告警、RED/USE 指标、容量评估与压测、GOMEMLIMIT、故障演练与混沌。触发词：timeout budget、retry、backoff、jitter、circuit breaker、gobreaker、rate limit、x/time/rate、bulkhead、semaphore、load shedding、backpressure、degrade、fallback、feature flag、canary、rollback、maxSurge、SLO、SLI、error budget、burn rate、capacity、压测、chaos。错误可重试性分类见 go-error-handling；metrics/日志/trace 的实现见 go-observability；优雅关闭与探针实现见 go-microservice。
---

# Go 稳定性工程

一个请求穿过"超时 → 重试 → 熔断 → 限流 → 隔仓 → 降级"六层时，每层怎么设、怎么叠加、什么时候不该加。实现放这里；错误分类（`Retryable`/`Permanent`）见 go-error-handling，打点见 go-observability。

## 核心规则

1. 超时从入口开始逐跳递减：下游 ctx 的 deadline 只能比上游早；本跳超时 = min(剩余预算 − reserve, 本跳上限)。
2. 重试只在一层做：客户端、网关、服务各重试 3 次 = 27 倍放大；重试流量 ≤ 正常流量 10%（预算），熔断打开时不重试。
3. 重试判定与 go-error-handling 的 `IsRetryable` 同序：`context.Canceled` 永不重试；显式 `Retryable()` 标记优先；网络超时（含单跳 `DeadlineExceeded`）算可重试，但每次尝试前先查调用方 `ctx.Err()`，总预算已尽就停。
4. 熔断器必设 `IsSuccessful`（4xx 语义算成功）与 `IsExcluded`（调用方取消不计），`ReadyToTrip` 先判样本数再算比率，且分母要减掉排除数。
5. 按 key 限流的容器必须有上限与淘汰（带 TTL 的 LRU），否则限流器本身是内存 DoS 面。
6. 每个下游一个并发上限（`semaphore.Weighted`）+ 有界等待队列；队列满立即拒绝，不无界排队。
7. 降级结果在响应里可辨认（`degraded=true`），兜底路径和主路径一样要有超时。
8. 告警按错误预算消耗速率（burn rate）多窗口触发，不按单点错误率。
9. 低 QPS（统计窗口内样本 < 20）不上熔断；单实例、单下游的内部服务不上限流——先量再加。

## 超时

| 决策 | 规则 | 为什么 |
|---|---|---|
| 单跳超时值 | 下游 P99 × 1.5~2，且 ≤ 下游 SLA 承诺 | 按 P50 定会把正常长尾全打成超时；按 max 定等于没设 |
| 入口总预算 | 客户端/网关愿意等的时长 − 网络往返 | 客户端 3s 放弃，服务端设 5s 只是在给已经没人等的请求耗资源 |
| reserve | 本跳返回后还要做的事（写 DB、序列化）的 P99 | 下游用完全部预算，本服务自己超时，等于白调 |
| DB/Redis | 单语句 ≤ 1s / ≤ 200ms，用 ctx 而非驱动全局超时 | 全局超时不随预算递减 |

```go
// WithDeadlineOnly 只给 ctx 加 deadline：超时后 handler 继续跑、客户端继续等，响应码由 handler 决定。
// 它的价值在于下游调用（DB/HTTP/gRPC）会因 ctx 超时提前返回，handler 应据此返回 504。
func WithDeadlineOnly(next http.Handler, d time.Duration) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		ctx, cancel := context.WithTimeout(r.Context(), d)
		defer cancel()
		next.ServeHTTP(w, r.WithContext(ctx))
	})
}

// Hard 用 http.TimeoutHandler：超时立即向客户端回 503（不是 504，Go 1.27 实测）并结束响应，
// handler 在后台继续跑但写响应会得到 http.ErrHandlerTimeout。不支持 Hijacker/Flusher：
// WebSocket、SSE 路由不能包在里面。
func Hard(next http.Handler, d time.Duration) http.Handler {
	return http.TimeoutHandler(next, d, `{"error":"timeout"}`)
}
```

Gin 场景用 `gin-contrib/timeout`（见 go-gin-api）同样要注意 handler 与超时分支并发写响应的问题。预算传播代码（`ForHop`/`Inject`/`Extract`）见 go-microservice。

## 重试

```go
// Policy 的零值不可用；Do 对非法配置直接报错而不是退化成"零退避紧循环"。
type Policy struct {
	MaxAttempts int           // 含首次；3 表示最多重试 2 次
	BaseDelay   time.Duration // 首次退避，如 100ms
	MaxDelay    time.Duration // 单次退避上限；无上限时 1<<attempt 在几十次后溢出、等待变成分钟级
	Budget      *rate.Limiter // 全进程共享：重试流量 ≤ 正常流量的 10%，如 rate.NewLimiter(qps*0.1, qps*0.1)
}
```

```go
// backoff 返回第 attempt 次（从 0 起）重试前的等待：指数 + 全抖动，再压到 MaxDelay。
func (p Policy) backoff(attempt int, err error) time.Duration {
	if ra, ok := errors.AsType[RetryAfter](err); ok && ra.RetryAfter() > 0 {
		return min(ra.RetryAfter(), p.MaxDelay) // 尊重下游给的 Retry-After
	}
	exp := p.BaseDelay << min(attempt, 16) // 限制移位位数；BaseDelay 本身很大时仍会溢出成负数
	d := min(exp, p.MaxDelay)
	if d <= 0 { // 溢出兜底：rand.Int64N(0) 与负数都会 panic（Go 1.27 实测）
		d = p.MaxDelay
	}
	return time.Duration(rand.Int64N(int64(d))) // 全抖动 [0, d)：同一时刻失败的请求不会同一时刻重试
}
```

```go
// Do 只在一层做重试：客户端、网关、服务各重试 3 次会放大成 27 倍流量。
func Do[T any](ctx context.Context, p Policy, fn func(ctx context.Context) (T, error)) (T, error) {
	var zero T
	if p.MaxAttempts < 1 || p.BaseDelay <= 0 || p.MaxDelay <= 0 {
		return zero, ErrInvalidPolicy
	}
	var lastErr error
	for attempt := range p.MaxAttempts {
		if err := ctx.Err(); err != nil {
			return zero, errors.Join(err, lastErr) // 首次尝试前也检查：ctx 已取消就别发请求
		}
		if attempt > 0 && p.Budget != nil && !p.Budget.Allow() {
			return zero, errors.Join(ErrBudgetExhausted, lastErr)
		}
		v, err := fn(ctx)
		if err == nil {
			return v, nil
		}
		lastErr = err
		if !shouldRetry(err) || attempt == p.MaxAttempts-1 {
			break
		}
		t := time.NewTimer(p.backoff(attempt, err))
		select {
		case <-ctx.Done():
			t.Stop()
			return zero, errors.Join(ctx.Err(), lastErr)
		case <-t.C:
		}
	}
	return zero, lastErr
}
```

| 决策 | 规则 | 反面现象 |
|---|---|---|
| 重试位置 | 只在最靠近失败点的一层（通常是服务内对下游的调用） | 网关也重试：下游雪崩时流量按乘积放大 |
| 可重试判定 | 429/502/503/504、网络超时；4xx、500、校验失败、业务拒绝不重试；连接重置、`io.ErrUnexpectedEOF` 由客户端层显式标记 `Retryable()` 后才重试 | 对 400 重试 3 次，日志里同一错误刷 4 遍 |
| 非幂等写 | 没有幂等键就不重试（幂等设计见 go-microservice） | 扣款重试成双扣 |
| 退避 | 指数 + 全抖动 + 上限；`rand.Int64N` 的参数 ≤ 0 会 panic，退避为 0 与左移溢出为负都要防 | 无抖动：同一秒失败的请求同一秒重试，下游第二波尖峰 |
| 预算 | 全进程共享 `rate.Limiter`，重试 ≤ 10% | 无预算：下游越慢重试越多，正反馈 |
| `Retry-After` | 429/503 带该头时按头等待，不按自己的退避 | 忽略头继续打，触发对方封禁 |
| 熔断打开 | `ErrOpenState`/`ErrTooManyRequests` 直接走降级，不重试 | 重试抢光半开态探测名额，熔断永远合不上 |

## 熔断

```go
// New 为一个下游建一个熔断器；不同下游绝不共用，否则 A 挂了会把 B 也熔断。
func New[T any](name string) *gobreaker.CircuitBreaker[T] {
	return gobreaker.NewCircuitBreaker[T](gobreaker.Settings{
		Name:         name,
		MaxRequests:  5,                // 半开态放行数；0 表示只放 1 个
		Interval:     10 * time.Second, // 闭合态计数清零周期；0 表示永不清零
		BucketPeriod: time.Second,      // 滚动窗口，避免 Interval 边界上计数突然清零
		Timeout:      30 * time.Second, // 打开态持续时间；0 时库默认 60s
		ReadyToTrip: func(c gobreaker.Counts) bool {
			// 被 IsExcluded 排除的请求仍计入 Requests（gobreaker v2.4.0 实测），分母必须减掉，
			// 否则大量调用方取消会稀释失败率，该熔断时不熔断。
			effective := c.Requests - c.TotalExclusions
			if effective < 20 { // 先判样本数：QPS 低时 2/3 失败就是 66%，不是故障
				return false
			}
			return float64(c.TotalFailures)/float64(effective) >= 0.5
		},
		// 不设 IsSuccessful 时所有非 nil error 都算失败：调用方取消、下游 4xx 都会把熔断器打开。
		IsSuccessful: func(err error) bool {
			if err == nil {
				return true
			}
			p, ok := errors.AsType[Permanent](err)
			return ok && p.Permanent() // 下游正常工作并拒绝了请求，算下游"健康"
		},
		// 调用方取消不计入成功也不计入失败（gobreaker v2.4.0 起）
		IsExcluded: func(err error) bool { return errors.Is(err, context.Canceled) },
		OnStateChange: func(name string, from, to gobreaker.State) {
			logger.Warn("circuit breaker state changed", zap.String("name", name),
				zap.String("from", from.String()), zap.String("to", to.String()))
		},
	})
}
```

```go
// Call 统一处理两种拒绝：ErrOpenState（打开态）与 ErrTooManyRequests（半开态超过 MaxRequests）。
// 两者都应立刻走降级，绝不重试——重试会把半开态探测名额抢光。
func Call[T any](cb *gobreaker.CircuitBreaker[T], fn func() (T, error)) (T, error) {
	v, err := cb.Execute(fn)
	if errors.Is(err, gobreaker.ErrOpenState) || errors.Is(err, gobreaker.ErrTooManyRequests) {
		return v, errors.Join(ErrUnavailable, err)
	}
	return v, err
}
```

已验证的行为（gobreaker v2.4.0，Go 1.27 实测）：不设 `IsSuccessful` 时所有非 nil error 计失败；`IsExcluded` 排除的请求 `Requests` 仍加 1、`TotalExclusions` 加 1，比率分母必须用 `Requests - TotalExclusions`；半开态超过 `MaxRequests` 的并发调用立即得到 `ErrTooManyRequests`；半开态连续成功数达到 `MaxRequests` 才回到 closed 并清零计数，期间任一失败立刻重回 open；`Timeout` 为 0 时默认 60s，`MaxRequests` 为 0 时只放 1 个。`Permanent()` 由 go-error-handling 的 `*AppError`（4xx 且非 429）、`Permanent(err)` 包装以及 go-microservice 的 `StatusError` 实现；5xx、429、网络错误不实现或返回 false，计入失败。

何时不该用：QPS < 1 的下游，10s 窗口凑不齐 20 个样本，比率毫无统计意义，改用超时 + 降级；同一个熔断器包多个下游，一个挂全部熔断。

## 限流

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

## 隔仓与背压

```go
// Do 的三段：满且队列满 → 立即拒绝（快速失败，让上游熔断/降级），否则排队到拿到槽位或 ctx 超时。
func (b *Bulkhead) Do(ctx context.Context, fn func(ctx context.Context) error) error {
	if !b.sem.TryAcquire(1) {
		if b.waiting.Add(1) > b.maxQueue {
			b.waiting.Add(-1)
			return ErrOverloaded // 有界队列：无界排队只是把超时从下游搬到本服务
		}
		err := b.sem.Acquire(ctx, 1)
		b.waiting.Add(-1)
		if err != nil {
			return err // ctx 超时/取消：等待期间已耗掉预算，不再调用下游
		}
	}
	defer b.sem.Release(1)
	return fn(ctx)
}
```

```go
func (s *Shedder) Admit(p Priority) (release func(), ok bool) {
	n := s.inflight.Add(1)
	if (n > s.hard && p < Critical) || (n > s.soft && p == Low) {
		s.inflight.Add(-1)
		return nil, false
	}
	return func() { s.inflight.Add(-1) }, true
}
```

构造函数与 `retry.Policy` 一样 fail-closed：`New(limit, maxQueue)` 在 `limit <= 0`（TryAcquire 永远失败、Acquire 阻塞到 ctx 超时，现象是"下游没挂但本服务全 504"）或 `maxQueue < 0` 时返回 `ErrInvalidLimits`；`NewShedder(soft, hard)` 在 `soft <= 0` 或 `hard < soft`（优先级反转：Normal 比 Low 先被拒）时返回 `ErrInvalidLevels`。`limit` ≈ 该下游连接池大小；`maxQueue` 取 limit 的 1~2 倍。无界排队只是把下游的慢搬到本服务：goroutine 与内存随排队增长，最终整体超时而不是局部失败。负载卸载的优先级要在入口就定（header 或路由），过载时先丢预取、埋点、推荐，保住下单、支付。

## 降级与预案

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

## 发布

k8s 时序（默认 `terminationGracePeriodSeconds: 30`，倒计时含 preStop）：readiness 翻红 → `preStop sleep 5` 等 endpoint 摘除 → SIGTERM → `Shutdown(20s)` 排空 → 关依赖（余量 5s）→ 30s 到 SIGKILL。进程内实现见 go-microservice。

| 项 | 规则 |
|---|---|
| 灰度 | 先 1 个 Pod / 1% 流量，按用户分组（内部 → 白名单 → 百分比），每级观察 ≥ 1 个完整业务周期 |
| 金丝雀指标 | 与基线对比：5xx 率、P99、下游错误率、业务指标（下单成功率）；任一恶化超阈值即回滚 |
| 自动回滚 | `progressDeadlineSeconds` 兜底；Argo Rollouts/Flagger 按 Prometheus 查询判定 |
| `maxSurge`/`maxUnavailable` | 默认 25%/25%；连接池预热慢的服务用 `maxUnavailable: 0`，避免容量瞬时缩 25% |
| 连接池预热 | 新 Pod 在 `startupProbe` 通过前建好 DB/Redis/gRPC 连接，否则第一波流量全在建连 |
| 回滚 | 镜像回滚 + 配置回滚 + 数据迁移前向兼容（新版本能读旧数据，旧版本能读新数据） |

## SLO 与告警

| 项 | 规则 |
|---|---|
| SLI | 从用户视角选：可用性 = 非 5xx 请求 / 总请求；延迟 = P99 < 阈值的请求占比；不用 CPU、内存做 SLI |
| SLO | 99.9%/30 天 → 错误预算 43.2 分钟；99.95% → 21.6 分钟 |
| RED | 每个服务：Rate（QPS）、Errors、Duration（直方图）；USE 用于资源：Utilization、Saturation、Errors |

多窗口 burn-rate 告警（SLO 99.9%，错误率阈值 = burn rate × 0.1%）：

| 长窗口 | 短窗口 | burn rate | 错误率阈值 | 消耗预算 | 级别 |
|---|---|---|---|---|---|
| 1h | 5m | 14.4 | 1.44% | 1h 烧掉 2% | 电话 |
| 6h | 30m | 6 | 0.6% | 6h 烧掉 5% | 电话 |
| 3d | 6h | 1 | 0.1% | 3d 烧掉 10% | 工单 |

长窗口判"确实在烧"，短窗口判"还在烧"（恢复后短窗口先回落，告警自动消退）；两个窗口同时超阈值才触发。单点错误率告警在低流量时段几个请求就能触发，是噪音的主要来源。

## 容量评估

| 项 | 方法 |
|---|---|
| 峰值 QPS | 日均 QPS = 日请求量 / 86400；峰值 = 日均 × 峰值系数（用历史 P99 分钟 QPS / 日均实测，常见 3~8；无数据取 5） |
| 单机容量 | 阶梯压测：并发逐级加，记录 P99 与错误率，取 P99 不劣化、CPU ≤ 70% 的最大 QPS；机器数 = 峰值 / 单机容量 × 1.5（N+1 与冗余） |
| 连接数 | 每 Pod 连接 = 下游数 × 每下游池大小；反过来 DB 侧 max_connections ≥ Pod 数 × 池大小 × 1.2 |
| 文件句柄 | 每连接 1 个 fd；`ulimit -n` 与容器 `nofile` 要 ≥ 2 × 峰值连接数 |
| goroutine | 每在途请求 ≈ 1~3 个；初始栈 2KB 起（Go 1.19 起按历史平均动态调整）；10 万 goroutine ≈ 数百 MB 起步 |
| `GOMAXPROCS` | go.mod 语言版本 ≥ 1.25 时自动感知 cgroup CPU 配额并周期性更新（go doc；≤ 1.24 默认 `containermaxprocs=0`），不再需要 automaxprocs |
| `GOMEMLIMIT` | 软上限，不自动读 cgroup；设为容器 limit 的 80~90%，为非 Go 内存（cgo、内核 socket 缓冲）留余量；到限后 GC 频繁而非 OOM |

## 故障演练

最小方法：用 toxiproxy/`tc netem` 或 Istio fault injection 对**单个**下游注入延迟（P99 × 3）、错误（50% 5xx）、不可用（拒连），每次只改一个变量，在预发或 1% 流量做。

演练脚本里制造 CPU/负载的部分必须自带有界寿命：看门狗 + `ulimit -t` 两道独立保险叠加，不依赖清理代码被执行（写法见 shell-scripting）。演练留下的负载进程比被演练的故障更难排查。

检查项：本服务 P99 是否被 ctx 超时钳住（而不是跟着下游涨）；重试次数是否在预算内；熔断是否在样本数够时打开、下游恢复后是否合上；降级路径是否触发且响应带 `degraded`；readiness 是否保持 up（依赖抖动不该让 Pod 被摘掉）；告警是否按 burn rate 触发而非风暴。

## 何时不该做

| 场景 | 不做什么 | 理由 |
|---|---|---|
| 单实例 + 单下游的内部工具 | 熔断、限流 | 加一层状态机与阈值调参，故障面积不变；超时 + 降级足够 |
| 下游 QPS < 1 | 熔断 | 窗口内凑不齐样本，比率判定是随机的 |
| 已上 Istio | SDK 侧重试/熔断/超时 | 两层叠加：重试次数相乘，超时互相覆盖 |
| 无幂等键的写 | 重试 | 双写事故比失败一次严重 |
| 没有基线指标 | 自适应限流 | 阈值无从校准，误限比不限更糟 |

## 稳定性审查清单

- [ ] 每个下游调用的 ctx 由预算派生（`ForHop`），deadline 只减不增；有 reserve
- [ ] 重试只在一层；重试判定与 go-error-handling `IsRetryable` 同序（`Canceled` 先于标记）；`MaxDelay` > 0；有全进程共享的重试预算
- [ ] `Retry-After` 被尊重；熔断打开/半开拒绝不重试
- [ ] 熔断器每下游一个；`IsSuccessful` 与 `IsExcluded` 都设了；`ReadyToTrip` 先判样本数，分母减 `TotalExclusions`
- [ ] 按 key 限流用带 TTL 的 LRU；反向代理后 IP 取自可信 `X-Forwarded-For`；429 带 `Retry-After`
- [ ] 每个下游有 `Bulkhead`，`maxQueue` 有界；构造期校验非法参数（fail-closed，同 `retry.Policy`）；过载优先级在入口已定
- [ ] 降级响应可辨认；兜底路径有超时；开关可热更新且有审计
- [ ] 预案表四列齐全且近一季度演练过
- [ ] 发布有 `preStop sleep`、`startupProbe`、金丝雀指标与自动回滚条件
- [ ] SLO 已定义；告警是多窗口 burn-rate；每个服务有 RED 三指标
- [ ] 峰值 QPS、单机容量、连接数/fd/goroutine 预算有数字；`GOMEMLIMIT` 已设
