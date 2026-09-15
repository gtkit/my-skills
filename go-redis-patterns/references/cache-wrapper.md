# 缓存读写封装：三态返回

```go
// Get 三态返回：found=false 只代表 key 不存在（redis.Nil）；err != nil 是 Redis 故障，
// 由调用方决定降级还是失败，绝不能当 miss 处理（否则故障期间所有请求穿透到 DB）。
func Get[T any](ctx context.Context, rdb redis.UniversalClient, key string) (v T, found bool, err error) {
	data, err := rdb.Get(ctx, key).Bytes()
	if errors.Is(err, redis.Nil) {
		return v, false, nil
	}
	if err != nil {
		return v, false, fmt.Errorf("redis get %s: %w", key, err)
	}
	if err := json.Unmarshal(data, &v); err != nil {
		return v, false, fmt.Errorf("decode %s: %w", key, err)
	}
	return v, true, nil
}
```

Session 就是它的一个用法：key `session:user:<id>`，续期 `rdb.Expire(ctx, key, ttl)`，过期时间不写进 payload（续期后必然不一致）。
