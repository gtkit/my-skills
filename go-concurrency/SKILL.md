---
name: go-concurrency
description: Go 并发工程实践：goroutine 生命周期与退出路径、Go 内存模型与 -race 局限、context 传播（WithoutCancel / AfterFunc）、errgroup.SetLimit / semaphore 有界并发、可编译的 worker pool（关闭后 Submit 报错、panic 隔离、背压）、pipeline / fan-out / fan-in、singleflight、sync 原语（Mutex/RWMutex/Map/Pool/Once/Cond/atomic）准确适用条件、time.After 与 channel 泄漏、goleak 与 testing/synctest 测试。当用户提到 goroutine、channel、select、sync.Mutex、WaitGroup、errgroup、worker pool、并发限制、goroutine 泄漏、死锁、data race、singleflight 时触发。与 go-testing 的分工：并发测试工具用法见 go-testing，本 skill 讲并发代码本身怎么写对。
allowed-tools: "Read, Write, Edit, Bash, Glob, Grep"
---

# Go 并发工程实践

goroutine、channel、sync 原语与 context 的正确用法及生产事故高发点。限流/熔断/超时预算见 `go-stability-engineering`；容器内 `GOMAXPROCS` 与 GC 调优见 `go-performance`；测试工具细节见 `go-testing`；现代语法以 `use-modern-go` 为准。

## 核心规则

1. 每个 goroutine 必须有可证明的退出路径（ctx 取消、输入关闭、显式信号三选一），且由启动者 `wg.Go` / `errgroup` 等待它结束——"启动即忘"的 goroutine 在优雅关闭时会被 `os.Exit` 硬杀。
2. channel 只由发送方关闭；多发送方时由协调者在 `wg.Wait()` 后关闭。接收方关闭 → 发送方 `panic: send on closed channel`。
3. 同时消费"输入 channel"和"ctx.Done"的循环，读侧和写侧都要 `select`；只在写侧 select、读侧用 `for range in` 的写法在上游不关闭时永久阻塞。
4. 锁内不做 I/O、不做 channel 操作、不调用可能回调持锁代码的函数。
5. 共享可变状态二选一：锁（数据）或单 goroutine 拥有 + channel 传消息（actor）。不要两者混用于同一份数据。
6. 有界并发是默认要求：无上限的 `go f()` 在流量尖峰时把下游打挂或 OOM 自己。
7. 从请求派生的后台任务用 `context.WithoutCancel(ctx)` + 独立超时，否则响应一返回任务就被取消。
8. 每条"并发安全"注释必须对应一个 `-race` 下运行、去掉同步机制就会失败的测试。

## Go 内存模型要点

- happens-before 边只来自同步原语：channel 发送先于对应接收完成；`close` 先于收到零值的接收；无缓冲 channel 的接收先于发送完成；`Unlock` 先于下一次 `Lock`；`wg.Go` 的 f 返回先于它解除的 `Wait` 返回；`Once.Do` 的 f 返回先于任何 `Do` 返回。
- `sync/atomic` 全部操作顺序一致（Go 内存模型原文：sequentially consistent）；原子操作 A 的效果被 B 观察到则 A 先于 B。所以"先写普通字段、再 `atomic.Store` 标志；读侧 `Load` 看到标志后再读字段"是合法发布模式，而读侧绕过原子变量直接读字段就是竞态。
- 存在数据竞争的程序不受内存模型保护：单字读只保证读到某个"先于或并发于它"的写入值（不一定是最新一次），多字值（string、slice、interface）可能撕裂成半新半旧，表现为莫名 nil 解引用或越界。
- `-race` 只报告实际执行到的交错，覆盖不到的分支不报；内存开销约 5–10 倍、耗时 2–20 倍（官方 race detector 文档）。TSan 对同时存活的 goroutine 数有硬上限，超限直接以 `race: limit on N simultaneously alive goroutines is exceeded, dying` 退出（Go 1.27 实测 100 万活跃 goroutine 仍未触发，旧资料里的 8128 已不适用）。它测不出"逻辑竞态"（分两次加锁的 check-then-act）。

## 生命周期与 context

```go
// fetchAll：首个错误取消派生 ctx，其余 goroutine 通过 ctx 感知并退出；SetLimit 限并发。
// Go 1.22 起循环变量每轮独立，不再需要 i, u := i, u。
func fetchAll(ctx context.Context, urls []string) ([]Response, error) {
	g, ctx := errgroup.WithContext(ctx)
	g.SetLimit(8)
	results := make([]Response, len(urls))
	for i, u := range urls {
		g.Go(func() error {
			resp, err := fetch(ctx, u)
			if err != nil {
				return fmt.Errorf("fetch %s: %w", u, err)
			}
			results[i] = resp // 各写各的下标，不需要锁
			return nil
		})
	}
	if err := g.Wait(); err != nil {
		return nil, err
	}
	return results, nil
}
```

`errgroup.WithContext` 的派生 ctx 在 `Wait` 返回后即取消，不要传给 `Wait` 之后还要用的对象；`SetLimit` 后 `g.Go` 会阻塞，`TryGo` 不阻塞。

```go
// Register 完成主事务后异步发欢迎邮件：脱离请求 ctx 的取消（否则响应一返回邮件就被取消），
// 但保留其 value（trace_id / request_id），并给后台任务独立的超时。
func (s *Service) Register(ctx context.Context, userID string) {
	bgCtx, cancel := context.WithTimeout(context.WithoutCancel(ctx), 5*time.Second)
	s.bg.Go(func() {
		defer cancel()
		_ = s.mailer.SendWelcome(bgCtx, userID)
	})
}

func (s *Service) Close() { s.bg.Wait() }

// readWithCtx：net.Conn.Read 不认识 ctx，用 AfterFunc 在 ctx 取消时关闭连接以打断阻塞读。
func readWithCtx(ctx context.Context, conn net.Conn, buf []byte) (int, error) {
	stop := context.AfterFunc(ctx, func() { _ = conn.Close() })
	defer stop() // 正常返回时撤销，避免误关连接
	return conn.Read(buf)
}
```

`context.AfterFunc`（Go 1.21）替代"起一个 goroutine 等 `<-ctx.Done()`"的旧写法：不用手写退出分支。`stop()` 返回 true 表示成功阻止回调运行；返回 false 表示回调已启动或此前已被停止，且它不等待回调结束（go doc）。

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

## Pipeline / fan-out / fan-in

```go
// stage 是 pipeline 的一级：ctx 取消或上游关闭都能退出。
// 读输入和写输出各自都要 select ctx.Done()：只在写侧 select、读侧用 range，
// 上游不关 channel 时 goroutine 会永久卡在 range 上——这正是最常见的泄漏形态。
func stage[In, Out any](ctx context.Context, in <-chan In, fn func(context.Context, In) Out) <-chan Out {
	out := make(chan Out)
	go func() {
		defer close(out)
		for {
			select {
			case <-ctx.Done():
				return
			case v, ok := <-in:
				if !ok {
					return
				}
				select {
				case out <- fn(ctx, v):
				case <-ctx.Done():
					return
				}
			}
		}
	}()
	return out
}
```

```go
// fanOut = 同一输入上起 n 个 stage，再 fanIn 汇聚。结果顺序不保证。
func fanOut[In, Out any](ctx context.Context, in <-chan In, n int, fn func(context.Context, In) Out) <-chan Out {
	outs := make([]<-chan Out, n)
	for i := range n {
		outs[i] = stage(ctx, in, fn)
	}
	return fanIn(ctx, outs...)
}
```

`fanIn` 与 `stage` 同构：每路输入一个 goroutine 做双侧 select，`wg.Wait()` 后由汇聚方关闭 `out`。反证测试：上游永不关闭、只取消 ctx，`for range out` 必须结束且 `goleak` 无泄漏。

## singleflight 与 Once

```go
// Get 合并同 key 的并发请求：只有第一个真正打到 repo，其余等待并共享结果。
// 共享调用运行在首个调用者的 ctx 上，若它取消，所有等待者都会收到 context.Canceled，
// 所以回源要脱离调用方取消并自带超时。
func (c *UserCache) Get(ctx context.Context, id string) (User, error) {
	v, err, _ := c.sf.Do(id, func() (any, error) {
		return c.repo.Get(context.WithoutCancel(ctx), id)
	})
	if err != nil {
		return User{}, err
	}
	return v.(User), nil
}
```

`Do` 阻塞到首个调用完成，"等不及就放弃"用 `DoChan` + select ctx；key 要包含全部影响结果的参数（租户、版本）。

`sync.OnceValue` / `OnceValues`（Go 1.21）替代 `Once + 包级变量`；注意它把 error 也缓存——初始化失败后每次调用都返回同一个错误，需要"失败可重试"的初始化改用显式 mutex + 状态。

## sync 原语适用条件

| 原语 | 用 | 不用 |
|---|---|---|
| `Mutex` | 默认选择；临界区短 | 临界区含 I/O |
| `RWMutex` | 读远多于写且读临界区不短（否则 `Mutex` 更快） | 递归 RLock：有写者等待时新 RLock 阻塞，同 goroutine 二次 RLock 死锁 |
| `sync.Map` | 官方文档两种场景：键只写一次多次读（只增缓存）；多 goroutine 读写互不相交的键集 | 通用并发 map——`map + Mutex` 类型安全且通常更快 |
| `sync.Pool` | 高频短命大对象（buffer、编解码器） | 有状态对象、跨请求持有；Put 前必须 `Reset` 且检查 `Cap()` 上限 |
| `sync.Cond` | 多等待者需要 `Broadcast` 唤醒且条件复杂 | 需要 ctx 取消——`Cond.Wait` 无法 select；多数场景 channel 更简单 |
| `atomic.Int64/Bool/Pointer[T]` | 计数器、标志、无锁配置热替换 | 需要原子更新多个字段（用锁） |

```go
// putBuf：超过上限的 buffer 直接丢给 GC。否则偶发的大请求把大 buffer 留在池里，
// 之后每个小请求都拿到几 MB 的 buffer，进程 RSS 只涨不跌。
func putBuf(b *bytes.Buffer) {
	if b.Cap() > maxPooledBuf {
		return
	}
	b.Reset()
	bufPool.Put(b)
}
```

## 常见泄漏与死锁

```go
// consumeBad：热循环里每轮 time.After 都新建 timer + channel。Go 1.23 前未触发的 timer 无法被 GC，
// 在高频循环里等于持续泄漏；1.23 起可回收，但仍是每轮一次堆分配。
func consumeBad(in <-chan int, idle time.Duration) {
	for {
		select {
		case v, ok := <-in:
			if !ok {
				return
			}
			handle(v)
		case <-time.After(idle):
			return
		}
	}
}

// consumeGood：一个 timer 复用。Go 1.23 起 Timer.C 无缓冲，Reset 后不会再读到上一轮的旧值。
func consumeGood(in <-chan int, idle time.Duration) {
	timer := time.NewTimer(idle)
	defer timer.Stop()
	for {
		select {
		case v, ok := <-in:
			if !ok {
				return
			}
			handle(v)
			timer.Reset(idle)
		case <-timer.C:
			return
		}
	}
}
```

Go 1.23 前 `Reset` 必须先 `Stop` 并排空 `t.C`，否则可能读到旧超时；1.23 起 `Reset` 后保证收不到旧值（`GODEBUG=asynctimerchan=1` 回退旧行为）。

"取最快一个结果"时若用无缓冲 channel，只有第一个发送者被接收，其余 n-1 个 goroutine 永久阻塞在发送上（`goleak.VerifyNone` 可抓到）：

```go
// 修复：缓冲区 == 发送者数量，落选者的发送不会阻塞，goroutine 自然结束。
func waitFirst(ctx context.Context, n int, work func(context.Context) int) int {
	ch := make(chan int, n)
	for range n {
		go func() { ch <- work(ctx) }()
	}
	return <-ch
}
```

其他高发点：`select` 里的 `default` 分支放在循环中是忙轮询，CPU 100%；两把锁在不同函数里以不同顺序获取——固定全局锁序或合并为一把；`wg.Add` 放在 goroutine 内部而非启动前（`wg.Go` 消除此问题）；`Mutex` 值拷贝（`go vet` 的 copylocks 会报）。检测：`defer goleak.VerifyNone(t)` 或包级 `goleak.VerifyTestMain(m)`；线上看 `runtime.NumGoroutine()` 曲线与 pprof `goroutine` profile 的阻塞栈。

## 测试并发代码

```go
// synctest 气泡：假时钟只在所有 goroutine 阻塞时推进，Sleep(3s) 瞬间完成且 tick 次数精确可断言。
// 气泡结束时若 Every 仍未退出（比如漏了 ctx.Done 分支），Test 直接报 deadlock 而非挂住。
func TestEvery_TicksAndStops(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		ctx, cancel := context.WithCancel(t.Context())
		var n atomic.Int32
		go Every(ctx, time.Second, func(context.Context) { n.Add(1) })

		time.Sleep(3*time.Second + time.Millisecond)
		synctest.Wait()
		if got := n.Load(); got != 3 {
			t.Fatalf("ticks = %d, want 3", got)
		}
		cancel()
		synctest.Wait()
	})
}
```

```go
// "Counter 并发安全"的反证测试：把 Inc 里的锁去掉，go test -race 必报 DATA RACE。
func TestCounter_ConcurrentInc(t *testing.T) {
	c := NewCounter()
	var wg sync.WaitGroup
	for range 64 {
		wg.Go(func() {
			for range 100 {
				c.Inc("k")
			}
		})
	}
	wg.Wait()
	if got := c.Get("k"); got != 6400 {
		t.Fatalf("Get = %d, want 6400", got)
	}
}
```

`synctest`（Go 1.25）约束：气泡内不可 `t.Run`/`t.Parallel`；只有气泡内创建的 channel/timer/WaitGroup 参与"持久阻塞"判断，`Mutex` 等待与网络 I/O 不算。工具组合与 flaky 抓取见 `go-testing`。

## 何时不该用 channel / 不该起 goroutine

| 场景 | 选择 | 理由 |
|---|---|---|
| 保护一个 map / 计数器 | `Mutex` / `atomic` | channel 版多一个 goroutine 和一次上下文切换 |
| 传递所有权、流式处理、扇出扇入 | channel | 所有权随消息移动，无共享状态 |
| 调用耗时 < 微秒级的函数 | 同步调用 | goroutine 创建 + 调度开销大于收益 |
| 请求内并行调 2–3 个下游 | `errgroup` | 有错误传播、有取消，不要手写 WaitGroup + 错误切片 |
| 后台定时任务 | 单 goroutine + `Ticker` + ctx | 每次 tick 起新 goroutine 会在任务变慢时堆积 |
| 等待条件且需要超时/取消 | channel + select | `sync.Cond` 不能 select |

## 审查清单

- [ ] 每个 `go` 语句能指出退出条件，且有 `wg.Go` / errgroup 等待它
- [ ] `for-select` 循环读输入与写输出两侧都监听 `ctx.Done()`
- [ ] channel 只由发送方（或 `wg.Wait` 后的协调者）关闭
- [ ] 无上限并发全部改为 `SetLimit` / semaphore / 有界队列
- [ ] worker 内有 `recover` 并记录 `zap.Stack`；关闭后 Submit 返回错误
- [ ] 请求派生的后台任务用 `WithoutCancel` + 独立超时，并被 `Close` 等待
- [ ] 锁内无 I/O、无 channel 操作；`RWMutex` 无递归 RLock
- [ ] `sync.Map` 只用于文档列出的两种场景；`sync.Pool` Put 前 `Reset` + `Cap()` 检查
- [ ] `OnceValues` 包裹的初始化不需要失败重试
- [ ] 无 `i, v := i, v`、无手写 `wg.Add/Done`、无 `for i := 0; i < n; i++`
- [ ] 每条"并发安全 / 有界 / 无泄漏"声明有 `-race` 下的反证测试；时间逻辑用 `synctest`
- [ ] CI 跑 `go test -race`、`go vet`（copylocks / lostcancel）、`goleak`
