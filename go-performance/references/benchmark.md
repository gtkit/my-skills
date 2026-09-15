# Benchmark

```go
func BenchmarkProcess(b *testing.B) {
	items := makeItems(1000) // setup 不计时：b.Loop 首次调用时才重置计时器
	b.ReportAllocs()
	for b.Loop() { // 循环体内的调用结果被编译器保活，不需要"赋给包级变量防优化"的老技巧
		Process(items)
	}
}

// 子基准的函数名必须与上面不同：同包重复声明 BenchmarkProcess 是编译错误。
func BenchmarkProcessSizes(b *testing.B) {
	for _, size := range []int{10, 1_000, 100_000} {
		b.Run(strconv.Itoa(size), func(b *testing.B) {
			items := makeItems(size)
			b.ReportAllocs()
			for b.Loop() {
				Process(items)
			}
		})
	}
}
```

`for b.Loop()`（Go 1.24+）：首次调用重置计时器、返回 false 时停表，setup / cleanup 都不计入；循环体内的函数参数与返回值被 `runtime.KeepAlive` 保活，编译器不会把整个循环体优化掉。`for i := 0; i < b.N; i++` 的写法两点都做不到。

```bash
go test -run='^$' -bench=. -benchmem -count=10 ./... > old.txt
# 改代码
go test -run='^$' -bench=. -benchmem -count=10 ./... > new.txt
go run golang.org/x/perf/cmd/benchstat@latest old.txt new.txt   # 看 delta 与 p 值，"~" 表示无显著差异
```

`-count=10` 不是可选项：单次结果受 CPU 频率、邻居进程影响，benchstat 需要样本算显著性。跑基准的机器上要关掉 IDE 索引、接电源、固定 `GOMAXPROCS`。
