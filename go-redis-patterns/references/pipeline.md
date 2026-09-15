# Pipeline 与 TxPipeline

- `Pipeline()` 只是把命令一次发出、一次读回，中间可插入其他客户端的命令；`TxPipeline()` 额外包 `MULTI/EXEC`，保证不被插队，但没有回滚：EXEC 里一条失败其余照常执行。Cluster 上 `Pipeline` 按 key 所在节点拆成多组并行发送（`osscluster.go` `mapCmdsByNode`），`MOVED` 自动重试；`TxPipeline` 要求全部 key 同 slot。Lua 在 pipeline 里 `NOSCRIPT` 无法回退（Redis 文档），用 `Eval` 或先 `Script.Load`。

```go
// BatchGetUsers：pipe.Exec 只返回第一个错误，必须逐 cmd 检查 Err()；redis.Nil 是 miss，其他错误是故障。
func BatchGetUsers(ctx context.Context, rdb redis.UniversalClient, ids []int64) (hit map[int64]User, miss []int64, err error) {
	pipe := rdb.Pipeline() // 只是打包发送；要 MULTI/EXEC 原子性用 rdb.TxPipeline()
	cmds := make(map[int64]*redis.StringCmd, len(ids))
	for _, id := range ids {
		cmds[id] = pipe.Get(ctx, fmt.Sprintf("user:profile:%d", id))
	}
	if _, err := pipe.Exec(ctx); err != nil && !errors.Is(err, redis.Nil) {
		return nil, nil, fmt.Errorf("pipeline exec: %w", err) // 第一个错误是网络级：整批失败
	}
	hit = make(map[int64]User, len(ids))
	for id, cmd := range cmds {
		data, err := cmd.Bytes()
		switch {
		case errors.Is(err, redis.Nil):
			miss = append(miss, id)
		case err != nil: // 第一个错误是 Nil 时，后面的真实错误只能在这里发现
			return nil, nil, fmt.Errorf("get user %d: %w", id, err)
		default:
			var u User
			if err := json.Unmarshal(data, &u); err != nil {
				return nil, nil, fmt.Errorf("decode user %d: %w", id, err)
			}
			hit[id] = u
		}
	}
	return hit, miss, nil
```

Cluster 约束：hash tag `order:{1001}:items` 与 `order:{1001}:status` 按 `1001` 计算 slot，多 key 命令（`MGET`、`SINTER`、`RENAME`）、`MULTI/EXEC`、Lua 声明的 KEYS 都要同 slot；`SCAN` 只扫单节点，全量遍历用 `ClusterClient.ForEachMaster`；Cluster 上 Pub/Sub 是全节点广播，Redis 7 起改用 `SPUBLISH`/`SSubscribe`；`MaxRedirects` 默认 3。
