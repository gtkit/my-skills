# goroutine 生命周期与 context

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
