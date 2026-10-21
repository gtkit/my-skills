# Benchmark

运行前先核对项目已批准的 Go、benchstat 版本与实际工具入口，记录被比较的代码版本、构建参数和环境。使用现有的固定版本，不通过示例自动下载 `@latest`；缺工具或版本未确认时将对比标为未验证，安装与升级另按当前授权和项目政策处理。

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
benchstat old.txt new.txt  # 使用上文已核对的固定版本；保留完整输出与样本警告
```

每组 10 次是本仓库的起始采样建议，不是置信区间可信与否的通用分界。根据噪声、效应大小及 benchstat 警告决定是否增加样本；没有显著差异也不证明两版等价。

两组使用同一数据与测量条件，记录 CPU/平台、供电与后台负载、Go/工具版本、`GOMAXPROCS`、GC/PGO 和构建参数；多种输入规模分别比较。微基准的 ns/op、B/op、allocs/op 只证明该基准范围，不能代替 API 吞吐、p99 或发布收益。端到端目标另取对应基线。

统计工具依据：[benchstat 官方文档](https://pkg.go.dev/golang.org/x/perf/cmd/benchstat)。本文件中的命令是待按授权运行的示例，不表示本轮文档维护已执行基准。
