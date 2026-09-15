# 测试并发代码

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
