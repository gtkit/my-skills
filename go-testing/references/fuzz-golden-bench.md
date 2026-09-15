# Fuzz、Golden 文件与 Benchmark

## Fuzz

```go
// 运行：go test -run=^$ -fuzz=FuzzParseAmount -fuzztime=30s ./amount/
// 失败输入自动写入 testdata/fuzz/FuzzParseAmount/，之后作为回归语料随普通 go test 运行。
func FuzzParseAmount(f *testing.F) {
	for _, seed := range []string{"0", "12.34", "-0.05", "", "1.234", "--5"} {
		f.Add(seed)
	}
	f.Fuzz(func(t *testing.T, in string) {
		cents, err := amount.ParseAmount(in)
		if err != nil {
			// 只允许出现已定义的哨兵错误；出现其他错误或 panic 即为缺陷
			if !errors.Is(err, amount.ErrEmpty) && !errors.Is(err, amount.ErrSyntax) &&
				!errors.Is(err, amount.ErrPrecision) && !errors.Is(err, amount.ErrRange) {
				t.Fatalf("unexpected error type: %v", err)
			}
			return
		}
		// 性质：解析成功的值经 Format 再 Parse 必须回到同一数值
		back, err := amount.ParseAmount(amount.FormatAmount(cents))
		if err != nil || back != cents {
			t.Fatalf("round trip %q -> %d -> %q -> %d, %v", in, cents, amount.FormatAmount(cents), back, err)
		}
	})
}
```

Fuzz 断言性质（不 panic、错误集合封闭、往返一致），不是具体值；`-fuzz` 一次只能匹配一个 Fuzz 函数，CI 不带 `-fuzz`、只回放语料。

## Golden 文件

输出里含时间戳、随机 ID 的先归一化再比；golden 进 git，diff 即评审材料。

```go
var update = flag.Bool("update", false, "rewrite golden files")

// 更新：go test ./golden/ -run TestRenderReceipt -update ；golden 文件进 git，diff 即评审材料。
func TestRenderReceipt(t *testing.T) {
	got := golden.RenderReceipt([]golden.Line{{Item: "coffee", Cents: 450}, {Item: "bagel", Cents: 325}})
	path := filepath.Join("testdata", t.Name()+".golden")
	if *update {
		require.NoError(t, os.MkdirAll(filepath.Dir(path), 0o755))
		require.NoError(t, os.WriteFile(path, got, 0o644))
	}
	want, err := os.ReadFile(path)
	require.NoError(t, err, "golden missing: run with -update to create")
	if diff := cmp.Diff(string(want), string(got)); diff != "" {
		t.Errorf("RenderReceipt mismatch (-want +got):\n%s", diff)
	}
}
```

## Benchmark

```go
func BenchmarkParseAmount(b *testing.B) {
	inputs := make([]string, 1024) // 数据在热循环外预生成：否则测的是 Sprintf/rand 的分配
	for i := range inputs {
		inputs[i] = strconv.FormatInt(rand.Int64N(1_000_000), 10) + ".99"
	}
	b.ReportAllocs()
	i := 0
	for b.Loop() { // Go 1.24 起：自动排除 setup 时间，且循环体内结果不会被编译器优化掉
		_, _ = amount.ParseAmount(inputs[i%len(inputs)])
		i++
	}
}
```

对比：`go test -bench . -benchmem -count 10 > new.txt` 后 `benchstat old.txt new.txt`；`count < 10` 时置信区间不可信。基准不与 `-race` 同跑。
