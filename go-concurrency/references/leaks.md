# 常见泄漏与死锁

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
