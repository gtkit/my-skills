# 有界并发与 worker pool

## 有界并发三选一

| 方案 | 选择场景 | 注意 |
|---|---|---|
| `errgroup.SetLimit(n)` | 任务集已知、需要收集首个错误并取消其余 | 限制不能在有活跃 goroutine 时修改 |
| `x/sync/semaphore.Weighted` | 长期运行的服务、排队时要能被 ctx 取消、任务权重不等 | `Acquire(ctx, n)` 失败返回 `ctx.Err()`，不改变信号量 |
| 带缓冲 channel 信号量 `make(chan struct{}, n)` | 零依赖、只在一个函数内用 | 排队等待不能被 ctx 打断，除非再套一层 select |

```go
// runBounded：semaphore 版有界并发。与 errgroup.SetLimit 的区别是 Acquire 接受 ctx，
// 排队等待期间 ctx 取消可立即放弃，且支持权重（大任务占多个槽）。
func runBounded(ctx context.Context, jobs []string, maxInflight int64, handle func(context.Context, string)) error {
	sem := semaphore.NewWeighted(maxInflight)
	var wg sync.WaitGroup
	for _, job := range jobs {
		if err := sem.Acquire(ctx, 1); err != nil {
			break // ctx 已取消：不再投递，但要等已在跑的结束
		}
		wg.Go(func() {
			defer sem.Release(1)
			handle(ctx, job)
		})
	}
	wg.Wait()
	return ctx.Err()
}
```

"有界"契约的反证测试：用 `atomic.Int64` 记录并发峰值，断言 `peak <= maxInflight`；去掉 semaphore 该测试必挂。`maxInflight <= 0` 时 `Acquire(ctx, 1)` 永远拿不到额度（实测一个任务都不会跑，只能等 ctx 到期），并发度来自配置就先校验。

## Worker pool

```go
// Pool 固定 worker 数 + 有界队列。Submit 在队列满时阻塞到调用方 ctx 超时（背压交给调用方），
// Shutdown 之后 Submit 返回 ErrPoolClosed 而不是向已关闭 channel 发送导致 panic。
type Pool struct {
	mu     sync.RWMutex // 保护 closed 与 close(tasks) 之间的临界区
	closed bool
	tasks  chan Task
	wg     sync.WaitGroup
	ctx    context.Context // 传给任务；Shutdown 超时后取消，让阻塞在 I/O 上的任务尽快退出
	cancel context.CancelFunc
}

func New(ctx context.Context, workers, queue int) *Pool {
	if workers < 1 {
		panic("workerpool: workers must be >= 1") // 0 个 worker 的池 Shutdown 会静默丢掉全部排队任务
	}
	ctx, cancel := context.WithCancel(ctx)
	p := &Pool{tasks: make(chan Task, queue), ctx: ctx, cancel: cancel}
	for range workers {
		p.wg.Go(p.worker)
	}
	return p
}

func (p *Pool) worker() {
	for task := range p.tasks { // 只有 Shutdown 会 close(tasks)，排队任务全部执行完 worker 才退出
		p.run(task)
	}
}

// run 隔离单个任务的 panic：一个任务崩溃不能带走 worker（更不能带走进程）。
func (p *Pool) run(task Task) {
	defer func() {
		if r := recover(); r != nil {
			logger.ErrorCtx(p.ctx, "worker task panicked", zap.Any("panic", r), zap.Stack("stack"))
		}
	}()
	task(p.ctx)
}

func (p *Pool) Submit(ctx context.Context, task Task) error {
	p.mu.RLock() // 持读锁期间 Shutdown 拿不到写锁，因此不可能 send 到已关闭 channel
	defer p.mu.RUnlock()
	if p.closed {
		return ErrPoolClosed
	}
	select {
	case p.tasks <- task:
		return nil
	case <-ctx.Done():
		return fmt.Errorf("workerpool: submit: %w", ctx.Err())
	}
}

// Shutdown 停止接收并等待排队任务跑完；ctx 到期则取消任务 ctx 并返回 ctx.Err()。
func (p *Pool) Shutdown(ctx context.Context) error {
	p.mu.Lock()
	if !p.closed {
		p.closed = true
		close(p.tasks)
	}
	p.mu.Unlock()

	done := make(chan struct{})
	go func() { p.wg.Wait(); close(done) }()
	select {
	case <-done:
		p.cancel()
		return nil
	case <-ctx.Done():
		p.cancel()
		return ctx.Err()
	}
}
```

配套测试（`-race` 下通过）：Shutdown 后 Submit 返回 `ErrPoolClosed`；panic 任务之后的任务仍执行；32 个 goroutine 持续 Submit 与 Shutdown 交错无 panic；Shutdown 超时后任务 ctx 被取消。`Submit` 持 RLock 期间只做非 I/O 的 channel 发送，Shutdown 的写锁在有 Submit 阻塞排队时会等到队列腾出位置或调用方 ctx 超时，因此 Submit 必须传带超时的 ctx。
