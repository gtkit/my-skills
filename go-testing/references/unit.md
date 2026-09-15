# 单元测试：表驱动、替身与契约

## 表驱动 + t.Parallel + 断言

```go
func TestParseAmount(t *testing.T) {
	t.Parallel()
	tests := []struct {
		name    string
		in      string
		want    int64
		wantErr error // nil 表示期望成功；非 nil 用 errors.Is 断言，不比对字符串
	}{
		{name: "integer", in: "7", want: 700},
		{name: "two decimals", in: "12.34", want: 1234},
		{name: "negative", in: "-0.05", want: -5},
		{name: "empty", in: "", wantErr: amount.ErrEmpty},
		{name: "double minus", in: "--5", wantErr: amount.ErrSyntax},
		{name: "three decimals", in: "1.234", wantErr: amount.ErrPrecision},
	}
	for _, tt := range tests { // Go 1.22 起每轮迭代变量独立，不需要 tt := tt
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			got, err := amount.ParseAmount(tt.in)
			if !errors.Is(err, tt.wantErr) {
				t.Fatalf("ParseAmount(%q) error = %v, want %v", tt.in, err, tt.wantErr)
			}
			if got != tt.want {
				t.Errorf("ParseAmount(%q) = %d, want %d", tt.in, got, tt.want)
			}
		})
	}
}
```

`errors.Is(nil, nil)` 为 true，成功与失败用例共用一个分支；`t.Fatal` 用于前置条件，`t.Error` 用于并列断言。

```go
func TestReceipt_Diff(t *testing.T) {
	t.Parallel()
	now := time.Now()
	want := Receipt{Cents: 1234, CreatedAt: now}
	got := Receipt{Cents: 1234, CreatedAt: now.Add(3 * time.Millisecond)}
	if diff := cmp.Diff(want, got, cmpopts.EquateApproxTime(10*time.Millisecond)); diff != "" {
		t.Errorf("Receipt mismatch (-want +got):\n%s", diff)
	}
}
```

| 断言方式 | 选择场景 | 代价 |
|---|---|---|
| 标准库 `if got != want` | 标量、错误、布尔；库代码零依赖 | 结构体差异要自己打印 |
| `go-cmp` `cmp.Diff` | 结构体/切片/map 比较；需要忽略字段（`cmpopts.IgnoreFields`）、近似时间、无序切片 | 未导出字段默认 panic，需 `cmpopts.IgnoreUnexported` 或 `cmp.AllowUnexported` |
| testify `require`/`assert` | 业务服务测试，可读性优先；`require.ErrorIs`、`require.JSONEq` 很省事 | `assert.Equal` 对 `time.Time` 与含 monotonic 的值会误判；`assert.Equal(t, int64(1), 1)` 因类型不同失败 |

## 测试替身：fake / stub / mock

- **fake**：有真实语义的轻量实现（内存 repo）。默认首选——测试读起来像业务，重构接口时改一处。
- **stub**：固定返回值的空壳，适合只需一个错误注入点的场景（`func` 类型实现接口最短）。
- **mock**：记录并断言交互（调了几次、传了什么）。只在"交互本身就是契约"时用（发了几条 MQ 消息、是否调了 Rollback）。

手写 fake 是一个带 `sync.Mutex` 的 `map[string]User` 加两个方法，二十行以内；它同时是契约测试的第一个被测实现。testify mock 的两条纪律——每个子测试独立实例、ctx 用 `mock.Anything`：

```go
func TestService_Profile_Mock(t *testing.T) {
	t.Parallel()
	t.Run("repo error is wrapped", func(t *testing.T) {
		t.Parallel()
		repo := new(MockRepo) // 每个子测试独立 mock，期望不串
		// ctx 用 mock.Anything：service 内部一旦派生 WithTimeout，精确匹配 ctx 必失败
		repo.On("Get", mock.Anything, "404").Return(double.User{}, double.ErrNotFound).Once()

		_, err := double.NewService(repo).Profile(t.Context(), "404")

		require.ErrorIs(t, err, double.ErrNotFound)
		repo.AssertExpectations(t)
	})
}
```

生成而不是手写：`mockery`（testify 模板参数 `with-expecter: true` 得到类型安全的 `EXPECT().Get(...)`）或 `go.uber.org/mock` 的 `mockgen -source=repo.go -destination=mock_repo_test.go -package=double_test`（原 golang/mock 已归档，用 uber 分叉）。生成文件放 `_test.go` 或 `internal/mocks/`，不进生产二进制。

**何时不该 mock**：被依赖方是纯函数或标准库（`time`、`json`）；接口方法 > 5 个且测试只关心结果不关心交互；数据库——mock SQL 字符串只是在测自己写的 SQL 字符串，用 testcontainers 跑真库。

## 契约测试：同一接口多实现共用一套 suite

```go
// RunRepositorySuite 是接口契约：任何 UserRepository 实现（内存 fake、pgx、GORM）都跑同一套。
// newRepo 每个子测试调用一次，保证实现之间、用例之间无共享状态。
func RunRepositorySuite(t *testing.T, newRepo func(t *testing.T) double.UserRepository) {
	t.Run("get missing returns ErrNotFound", func(t *testing.T) {
		repo := newRepo(t)
		_, err := repo.Get(t.Context(), "missing")
		require.ErrorIs(t, err, double.ErrNotFound)
	})
	t.Run("save then get", func(t *testing.T) {
		repo := newRepo(t)
		want := double.User{ID: "7", Name: "Bob"}
		require.NoError(t, repo.Save(t.Context(), want))
		got, err := repo.Get(t.Context(), "7")
		require.NoError(t, err)
		require.Equal(t, want, got)
	})
}

func TestMemoryRepo_Contract(t *testing.T) {
	RunRepositorySuite(t, func(t *testing.T) double.UserRepository { return double.NewMemoryRepo() })
}
```

真库实现在 integration 包里再调一次 `RunRepositorySuite`，`newRepo` 返回绑定了测试事务的 repo。fake 与真实现跑同一套 suite，才能保证"用 fake 测出来的绿"在生产实现上同样成立。
