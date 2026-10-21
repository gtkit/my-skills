# 幂等

幂等键的存储与事务实现见 go-data-consistency；这里只定义接口与状态机（`State` 取值 `StateNone/StateProcessing/StateDone`；processing 记录必须带过期时间，执行中进程崩溃留下的 processing 过期后由 `Begin` 接管视同 none，因此 `fn` 必须可重入）。存储首选 DB 唯一键；Redis 主从切换会丢 key，只能做 DB 前面的加速层。

这个 `Store` 是**通用应用层幂等**：`fn` 的业务写入与 `Done` 是两次独立提交，两者之间有窗口——业务已落库而 `Done` 失败时记录停在 processing，靠过期接管重做，调用方拿到的错误不代表"未执行"。窗口只能消除、不能靠这个接口收窄：业务写入与幂等键在同一个库时，把 `INSERT idempotency_key` 放进业务事务本身，唯一键冲突即重复，此时不需要 processing 态、也不需要 `Done`（实现见 go-data-consistency）。跨库或写入在下游服务时才用本接口，并接受"可重入"这个前提。

取消与收尾契约见 `go-context`。下面是 Go 1.21+ 的示意片段，本次文档修订未编译或运行；`cleanupTimeout` 是调用方根据项目契约提供的正收尾预算，无默认值，不得直接作为未验证的项目实现。`Store.Fail/Done` 的实现还须遵守 ctx 取消，timeout 本身不能强制中断忽略 ctx 的存储调用。

示例仅在 `fn` 返回 error 能确认本次业务失败时调用 `Fail`；若提交结果不明或已有部分副作用，不得据 error 删除占位以允许盲目重做，应按项目状态机保留记录并恢复或对账。

```go
var ErrInProgress = errors.New("idempotent request in progress")

// Store 的实现见 go-data-consistency：首选 DB 唯一键；Redis 只做 DB 前面的加速层。
type Store interface {
	// Begin 原子地把 key 置为 processing；已存在时返回当前状态与缓存结果。
	Begin(ctx context.Context, key string) (State, []byte, error)
	// Done 写入结果并置为 done。它与业务写入是两次独立提交：业务已落库而 Done 失败时，
	// 记录留在 processing，等过期后被下一次 Begin 接管重做——所以 fn 必须可重入。
	Done(ctx context.Context, key string, result []byte) error
	// Fail 删除 processing 记录，允许调用方重试。只在业务确定失败时调用。
	Fail(ctx context.Context, key string) error
}

// Execute 是幂等执行的唯一入口：processing 返回 ErrInProgress（HTTP 409），done 返回缓存结果。
func Execute(ctx context.Context, st Store, key string, cleanupTimeout time.Duration, fn func(ctx context.Context) ([]byte, error)) ([]byte, error) {
	if cleanupTimeout <= 0 {
		return nil, errors.New("cleanup timeout must be positive")
	}
	state, cached, err := st.Begin(ctx, key)
	if err != nil {
		return nil, err
	}
	switch state {
	case StateDone:
		return cached, nil // 重放：返回首次的响应，而不是再执行一次
	case StateProcessing:
		return nil, ErrInProgress // 绝不能 return nil：那是把"别人正在做"报告成"已成功"
	}
	result, err := fn(ctx)
	cleanupCtx, cancel := context.WithTimeout(context.WithoutCancel(ctx), cleanupTimeout)
	defer cancel()
	if err != nil {
		if ferr := st.Fail(cleanupCtx, key); ferr != nil {
			return nil, errors.Join(err, ferr)
		}
		return nil, err
	}
	// fn 已产生副作用：Done 使用独立收尾预算；失败仍需状态恢复或对账。
	if err := st.Done(cleanupCtx, key, result); err != nil {
		return nil, err
	}
	return result, nil
}
```

原实现 `SetNX(key, "processing")` 失败即 `return nil`，三个独立缺陷叠加成 P0：并发第二个请求在第一个仍在处理时被告知"成功"（实际可能失败）；进程在 SetNX 与 Del 之间崩溃，key 残留 10 分钟内所有重试都被当作已成功；没存结果，重放无法返回原响应，调用方只能拿到空成功。
