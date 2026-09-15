# Lua 脚本与库存扣减

## Lua 脚本

- `redis.NewScript(src)` + `script.Run(ctx, rdb, keys, args...)`：先 `EVALSHA`，遇 `NOSCRIPT` 自动回退 `EVAL`。脚本缓存在重启、主从切换、`SCRIPT FLUSH` 后清空，所以永远不要裸调 `EvalSha`。
- 时间用 `redis.call('TIME')` 取服务端时钟，不由每个 app 实例传 `time.Now()`——多实例时钟漂移会让窗口忽大忽小。
- 唯一值必须由 Go 传入。Redis < 5.0 默认整段脚本复制，`math.random` 每次执行用相同种子（官方文档："always uses the same seed for every execution"）；Redis 5.0 起默认、7.0 起只有效果复制，PRNG 每次调用随机播种（Redis 8.0.0 实测三次 `EVAL "return math.random(1000000)"` 返回不同值）。随机不等于唯一，用 `math.random` 拼 ZSET member 在旧版本上必然重复，在新版本上会小概率重复。
- 写命令用 `HSET`（多字段）而不是废弃的 `HMSET`；脚本要短，Redis 单线程，5ms 的脚本就是 5ms 的全局停顿。Cluster 模式下带 `#!lua` shebang 的脚本（7.0+）访问未声明的 key 会受同 slot 校验（单机不校验，Redis 8.0.0 实测），任何版本都以声明全部 KEYS 为准。

### 滑动窗口限流 + 令牌桶

```go
// 滑动窗口。KEYS[1] 限流 key；ARGV[1] 窗口毫秒；ARGV[2] 上限；ARGV[3] 唯一 member（Go 侧生成）。
var slidingWindow = redis.NewScript(`
local t = redis.call('TIME')
local now = t[1] * 1000 + math.floor(t[2] / 1000)  -- 服务端时钟：多实例时钟漂移不影响窗口
local window, limit = tonumber(ARGV[1]), tonumber(ARGV[2])
redis.call('ZREMRANGEBYSCORE', KEYS[1], 0, now - window)
local count = redis.call('ZCARD', KEYS[1])
if count >= limit then
  return {0, 0}
end
redis.call('ZADD', KEYS[1], now, ARGV[3])
redis.call('PEXPIRE', KEYS[1], window)
return {1, limit - count - 1}
`)
```

```go
// AllowSliding：window 内最多 limit 次。member 唯一由 Go 侧保证；同一 member 重试 ZADD 只更新分值，重试幂等。
// window ≤ 0 会让脚本里的 PEXPIRE 立刻删 key、限流形同虚设（Redis 8.0.0 实测），所以先拦。
func (l Limiter) AllowSliding(ctx context.Context, key string, limit int64, window time.Duration) (bool, int64, error) {
	if limit <= 0 || window <= 0 {
		return false, 0, fmt.Errorf("ratelimit %s: limit %d and window %v must be positive", key, limit, window)
	}
	member := strconv.FormatInt(time.Now().UnixNano(), 36) + "-" + strconv.FormatUint(rand.Uint64(), 36)
	res, err := slidingWindow.Run(ctx, l.rdb, []string{"rl:sw:" + key}, window.Milliseconds(), limit, member).Int64Slice()
	return pair(res, err)
}

// AllowBucket：rate 每秒补充、capacity 突发上限、n 本次申请。读超时重试会重复扣令牌，用 MaxRetries=-1 的 client。
// n ≤ 0 不拦：负数在脚本里等于补充令牌，桶会超过 capacity（Redis 8.0.0 实测 cap=5 时 n=-3 得到 8）。
func (l Limiter) AllowBucket(ctx context.Context, key string, rate, capacity, n int64) (bool, int64, error) {
	if rate <= 0 || capacity <= 0 || n <= 0 {
		return false, 0, fmt.Errorf("ratelimit %s: rate %d, capacity %d and n %d must be positive", key, rate, capacity, n)
	}
	res, err := tokenBucket.Run(ctx, l.rdb, []string{"rl:tb:" + key}, rate, capacity, n).Int64Slice()
	return pair(res, err)
}
```

令牌桶脚本（同文件 `tokenBucket`）：`HMGET tokens ts` → 按 `(now-ts)/1000*rate` 补充、`math.min(cap, ...)` 截断 → 够则扣 → `HSET`+`PEXPIRE`，返回 `{ok, 剩余}`。限流策略（单机 vs 分布式、失败开/闭）见 go-stability-engineering。

## 库存扣减（Lua 原子 + 幂等）

```go
var deductScript = redis.NewScript(`
if redis.call('EXISTS', KEYS[2]) == 1 then
  return {2, tonumber(redis.call('GET', KEYS[1]) or '0')}
end
local stock = tonumber(redis.call('GET', KEYS[1]) or '0')
local n = tonumber(ARGV[1])
if stock < n then
  return {0, stock}
end
local left = redis.call('DECRBY', KEYS[1], n)
redis.call('SET', KEYS[2], 1, 'EX', ARGV[2])
return {1, left}
`)

// Deduct 原子扣减。orderID 作幂等 token，让 MaxRetries 重试 / 上游重发都只扣一次。
func Deduct(ctx context.Context, rdb redis.UniversalClient, sku, orderID string, n int64) (ok bool, left int64, err error) {
	if n <= 0 { // DECRBY 负数会加库存
		return false, 0, fmt.Errorf("deduct %s: quantity %d must be positive", sku, n)
	}
	if orderID == "" { // 空 token 让所有请求共用一个 dedup key，第二单起全部被判为重复
		return false, 0, fmt.Errorf("deduct %s: empty order id", sku)
	}
	keys := []string{"stock:sku:{" + sku + "}", "stock:dedup:{" + sku + "}:" + orderID} // hash tag 保证 Cluster 同槽
	res, err := deductScript.Run(ctx, rdb, keys, n, 86400).Int64Slice()
	if err != nil {
		return false, 0, fmt.Errorf("deduct %s: %w", sku, err)
	}
	if len(res) != 2 {
		return false, 0, fmt.Errorf("deduct %s: unexpected reply %v", sku, res)
	}
	return res[0] != 0, res[1], nil
```

单 SKU 一个 key 是天然热 key，大促下单节点 CPU 打满；分段库存（`stock:sku:{id}:0..n`，扣减随机选段、失败换段）与热 key 检测见 go-cache-consistency。
