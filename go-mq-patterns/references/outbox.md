# 事务消息与 Outbox

RocketMQ 事务消息 = 半消息（消费者不可见）→ 本地事务 → Commit/Rollback；客户端没回应时 broker 回查 `CheckLocalTransaction`（broker 侧默认半消息 6s 后开始回查、每 30s 一次、最多 15 次：`transactionTimeOut` / `transactionCheckInterval` / `transactionCheckMax`，BrokerConfig 源码）。

```go
// orderTxListener 实现事务消息的两个回调。半消息先到 broker（消费者不可见），
// 本地事务成功才 Commit 让消息可见；本地事务结果未知时 broker 会回查。
type orderTxListener struct{ db *sql.DB }

func (l *orderTxListener) ExecuteLocalTransaction(msg *primitive.Message) primitive.LocalTransactionState {
	// 本地事务必须把 msg 的业务键（如 msg.GetKeys()）一起落库，回查才有依据
	if err := l.createOrder(context.Background(), msg); err != nil {
		logger.Error("本地事务失败", zap.String("keys", msg.GetKeys()), zap.Error(err))
		return primitive.RollbackMessageState
	}
	return primitive.CommitMessageState
}

func (l *orderTxListener) CheckLocalTransaction(msg *primitive.MessageExt) primitive.LocalTransactionState {
	var n int
	err := l.db.QueryRowContext(context.Background(), `SELECT COUNT(1) FROM orders WHERE order_no = $1`, msg.GetKeys()).Scan(&n)
	switch {
	case err != nil:
		return primitive.UnknowState // 查不出来就继续 Unknown，等下一次回查；不要在不确定时 Rollback
	case n > 0:
		return primitive.CommitMessageState
	default:
		return primitive.RollbackMessageState
	}
}

func NewTxProducer(nameServers []string, group string, db *sql.DB) (rocketmq.TransactionProducer, error) {
	return rocketmq.NewTransactionProducer(&orderTxListener{db: db},
		producer.WithNsResolver(primitive.NewPassthroughResolver(nameServers)),
		producer.WithGroupName(group),
		producer.WithRetry(2),
	)
}
```

- 回查查不出就返回 `UnknowState` 等下次，不能因为查询失败 Rollback；本地事务必须把消息业务键落库，否则回查无据。
- Kafka 没有半消息。"写 DB + 发消息"的原子性用 Outbox：业务事务内写 outbox 表，relay 轮询或 CDC 发到 Kafka 后标记已发。relay 的失败模式：发成功但标记失败 → 重发（消费端幂等兜底）；多 relay 并发 → `SELECT ... FOR UPDATE SKIP LOCKED` 或单实例主备。实现见 go-data-consistency。
