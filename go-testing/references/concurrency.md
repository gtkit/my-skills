# 并发与时间：-race、goleak、synctest

```go
// goleak.VerifyTestMain：包内任何测试泄漏 goroutine，整个包失败。
func TestMain(m *testing.M) {
	goleak.VerifyTestMain(m)
}

// synctest 气泡内 time 是假时钟：Sleep 不真等待，且只在所有 goroutine 都阻塞时推进，
// 所以能对"总耗时 == 100ms + 200ms"做精确相等断言，测试毫秒级完成、零 flaky。
func TestRetry_Backoff(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		start := time.Now()
		calls := 0
		err := timing.Retry(t.Context(), 3, 100*time.Millisecond, func() error {
			calls++
			if calls < 3 {
				return errors.New("transient")
			}
			return nil
		})
		if err != nil {
			t.Fatalf("Retry() = %v, want nil", err)
		}
		if got := time.Since(start); got != 300*time.Millisecond {
			t.Fatalf("elapsed = %v, want exactly 300ms", got)
		}
	})
}
```

synctest 约束：气泡内不能 `t.Run` / `t.Parallel`；只对气泡内创建的 channel、timer、`WaitGroup` 生效，网络 I/O 与 `Mutex` 等待不算"持久阻塞"（需要网络用 `net.Pipe`）；气泡结束时仍有 goroutine 阻塞直接报 deadlock，本身就是泄漏检测。抓 flaky：`go test -race -count=20 -run TestX ./pkg/`，`-shuffle=on` 暴露顺序依赖。单测级泄漏检测 `defer goleak.VerifyNone(t)`，`httptest.Server`、`sql.DB` 的后台 goroutine 要在 Cleanup 里关掉再验。
