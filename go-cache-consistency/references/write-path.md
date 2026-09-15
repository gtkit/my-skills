# 写路径：怎么让缓存和 DB 一致

Cache-Aside 四种时序，只有"先更 DB 后删缓存"的脏窗口是毫秒级且可被延迟双删覆盖：

| 方案 | 并发下的问题 | 结论 |
|---|---|---|
| 先删缓存，再更新 DB | 删后、DB 提交前，读请求 miss → 读旧值 → 写回缓存；脏到下次失效 | 不用 |
| 先更新 DB，再更新缓存 | 写 A、写 B 到 DB 顺序 A→B，到缓存顺序 B→A，缓存永久停在 A；写多读少时白算 | 不用 |
| 先更新 DB，再删缓存 | 读请求在 DB 提交前查到旧值、在删之后才写回——需要"读比写慢"，窗口毫秒级 | 默认方案 |
| 延迟双删 | 提交后删一次，延迟 500ms~1s 再删一次，覆盖上面的窗口 | 补丁：延迟值凭经验，读请求 GC 停顿超过延迟仍会脏 |

```go
// UpdateName：先更 DB（提交），后删缓存，再投递延迟二删。
// 不"先删后更"：删完到提交之间并发读把旧值写回缓存，脏到下次失效。
// 不"更新缓存"：两个写请求 DB 顺序 A→B、缓存顺序 B→A，缓存永久停在 A。
// 不在事务内删：Del 后到 Commit 前的读把旧值写回，等于没删。
func (w Writer) UpdateName(ctx context.Context, id int64, name string) error {
	tx, err := w.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	if _, err := tx.ExecContext(ctx, `UPDATE users SET name = ?, version = version + 1 WHERE id = ?`, name, id); err != nil {
		return errors.Join(err, tx.Rollback())
	}
	if err := tx.Commit(); err != nil {
		return fmt.Errorf("commit: %w", err)
	}
	key := fmt.Sprintf("user:profile:%d", id)
	if err := w.rdb.Del(ctx, key).Err(); err != nil {
		// DB 已提交，不能回滚。脏窗口 = 缓存剩余 TTL，必须补偿：延迟队列重试 + binlog 订阅兜底
		logger.ErrorCtx(ctx, "cache invalidate failed", zap.String("key", key), zap.Error(err))
	}
	select {
	case w.delay <- key: // 延迟双删：覆盖"读请求在提交前查到旧值、在 Del 之后才写回"的窗口
	default:
		logger.WarnCtx(ctx, "delay-delete queue full", zap.String("key", key))
	}
	return nil
}
```

- 延迟任务投递到队列（本地 channel 只是示意）：`time.AfterFunc` 在发布重启时任务全丢；有 MQ 就用延迟消息。
- binlog 订阅（MySQL 用 Canal，MySQL/PG 用 Debezium）：消费 row 变更事件 → 按主键删 key。优点是覆盖所有写入口（DBA 脚本、批处理、别的服务），业务代码零侵入；代价是 ms~s 级延迟、需要按主键分区保序、消费者必须幂等。它是兜底，不是替代应用层删除。
- 版本号防 ABA：慢读请求拿着旧版本 DB 结果回来写缓存，会覆盖新值。缓存值携带 `version`（DB 行的 version 列或 `updated_at` 微秒），写回用 Lua 比较：

```go
var setIfNewer = redis.NewScript(`
local cur = redis.call('HGET', KEYS[1], 'v')
if cur and tonumber(cur) >= tonumber(ARGV[1]) then
  return 0
end
redis.call('HSET', KEYS[1], 'v', ARGV[1], 'd', ARGV[2])
redis.call('PEXPIRE', KEYS[1], ARGV[3])
return 1
`)
```

| 策略 | 一致性 | 复杂度 | 适用 |
|---|---|---|---|
| Cache-Aside + 提交后删 | 最终一致，脏窗口 ms 级 | 低 | 默认；读多写少 |
| + 延迟双删 | 缩小窗口 | 低 | 对脏读敏感但容忍秒级 |
| + binlog 订阅失效 | 最终一致，兜底所有写入口 | 中（多一套消费者） | 多写入口、大团队 |
| + 版本号 CAS 写回 | 杜绝旧值覆盖新值 | 中 | 读慢（复杂查询）且并发写 |
| Read-Through（缓存组件代读） | 同 Cache-Aside | 低 | 想把回源逻辑收口到一处 |
| Write-Behind（先写缓存异步刷 DB） | 缓存宕机丢写 | 高 | 计数器、点赞等可丢场景 |
| 读 DB | 强一致 | 无 | 支付结果、库存校验等读己之写 |

### 缓存与事务

事务内 `Del`：Del 到 Commit 之间的并发读查到未提交的旧行，写回缓存，等于没删；上面的 `UpdateName` 把 Del 放在 `Commit` 之后。提交后 Del 失败时 DB 无法回滚，只能记录 + 重试 + binlog 兜底；要保证"提交即一定失效"，把失效事件写进同事务的 outbox 表（见 go-data-consistency）。
