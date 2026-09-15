# Pipeline、fan-out/fan-in 与 singleflight

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
