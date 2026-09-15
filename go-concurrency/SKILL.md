---
name: go-concurrency
description: Go 并发代码怎么写对：goroutine 生命周期、context 传播、有界并发、worker pool、pipeline、singleflight、sync 原语适用条件、泄漏与死锁。涉及 goroutine、channel、锁、data race 时使用。
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

## 按任务读取

以下内容按任务读取，只读本次需要的文件；核心规则与审查清单已覆盖其结论。

| 任务 | 读 |
|---|---|
| goroutine 退出路径、context 传播、WithoutCancel / AfterFunc | `references/lifecycle.md` |
| 限制并发数、写 worker pool（关闭语义、panic 隔离、背压） | `references/bounded.md` |
| 写 pipeline / fan-out / fan-in，或用 singleflight 合并请求 | `references/pipeline.md` |
| 排查 goroutine 泄漏、channel 阻塞、死锁 | `references/leaks.md` |
| 用 -race、goleak、synctest 测并发 | `references/testing.md` |

## Go 内存模型要点

- happens-before 边只来自同步原语：channel 发送先于对应接收完成；`close` 先于收到零值的接收；无缓冲 channel 的接收先于发送完成；`Unlock` 先于下一次 `Lock`；`wg.Go` 的 f 返回先于它解除的 `Wait` 返回；`Once.Do` 的 f 返回先于任何 `Do` 返回。
- `sync/atomic` 全部操作顺序一致（Go 内存模型原文：sequentially consistent）；原子操作 A 的效果被 B 观察到则 A 先于 B。所以"先写普通字段、再 `atomic.Store` 标志；读侧 `Load` 看到标志后再读字段"是合法发布模式，而读侧绕过原子变量直接读字段就是竞态。
- 存在数据竞争的程序不受内存模型保护：单字读只保证读到某个"先于或并发于它"的写入值（不一定是最新一次），多字值（string、slice、interface）可能撕裂成半新半旧，表现为莫名 nil 解引用或越界。
- `-race` 只报告实际执行到的交错，覆盖不到的分支不报；内存开销约 5–10 倍、耗时 2–20 倍（官方 race detector 文档）。TSan 对同时存活的 goroutine 数有硬上限，超限直接以 `race: limit on N simultaneously alive goroutines is exceeded, dying` 退出（Go 1.27 实测 100 万活跃 goroutine 仍未触发，旧资料里的 8128 已不适用）。它测不出"逻辑竞态"（分两次加锁的 check-then-act）。

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
