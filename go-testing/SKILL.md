---
name: go-testing
description: Go 测试工程实践：表驱动 + t.Parallel、go-cmp/testify/标准库断言取舍、fake/stub/mock 替身选择与 mockery 生成、Gin handler 与出站 HTTP 测试、testcontainers 集成测试隔离、接口契约测试、-race/goleak/testing/synctest 并发测试、Fuzz、golden 文件、b.Loop 基准与 CI 参数。当用户提到 Go testing、写单测、testify、mock、mockery、httptest、testcontainers、fuzz、benchmark、golden、覆盖率、flaky 测试时触发。与 go-enterprise-quality 的分工：那个 skill 定义交付前的质量门禁，本 skill 给出具体测试写法与工具选型。
---

# Go 测试工程实践

单元、集成、并发、模糊、基准测试的写法与工具选型。现代语法以 `use-modern-go` 为准；并发原语本身见 `go-concurrency`；数据库驱动/ORM 见 `go-database-patterns`。

## 核心规则

1. 测试内一律 `t.Context()`（Go 1.24），它在 Cleanup 运行前被取消；Cleanup 里要用 ctx 的操作（回滚、关连接）用 `context.WithoutCancel(t.Context())`。
2. 错误断言只用 `errors.Is` / `errors.AsType[T]`，不比对 `err.Error()` 字符串——上游改一个字，测试就红。
3. 含 `time.Time` 的结构体不用 `reflect.DeepEqual` / `assert.Equal` 直接比：`time.Now()` 带 monotonic 读数，序列化再反序列化后就不相等。用 `cmp.Diff` + `cmpopts.EquateApproxTime`。
4. `t.Parallel()` 与 `t.Setenv` / `t.Chdir` 互斥（两者都改整个进程的状态）：同一测试里两者并用直接 panic，文案为 `testing: test using t.Setenv, t.Chdir, or cryptotest.SetGlobalRandom can not use t.Parallel`（Go 1.27 源码常量 parallelConflict）。
5. 缺外部环境时 `t.Skip` 等于假绿：CI 里必须失败。用 `//go:build integration` 标签决定跑不跑，不用运行时 skip。
6. 集成测试的隔离单位是"一个测试一个事务（结束回滚）"或"一个测试一个 schema"，禁止共享一张表再靠 `DELETE ... LIKE 'test-%'` 清理。
7. Handler 测试必须走生产同一个路由装配函数（含错误中间件）；裸 `gin.New()` + handler 会把错误路径测成 200。
8. 契约声明（幂等、有界、线程安全）必须有"若为假就失败"的测试，且该测试在 `-race` 下跑。

## 现代 testing API 速查

| API | 版本 | 用途 |
|---|---|---|
| `t.Context()` | 1.24 | 随测试结束取消的 ctx，替代 `context.Background()` |
| `for b.Loop()` | 1.24 | 自动排除 setup、防止结果被优化掉；不与 `b.N` 循环混用 |
| `t.Attr(k, v)` / `t.Output()` | 1.25 | 输出 CI 可解析的键值属性；返回与 `t.Log` 同流、带缩进的 `io.Writer` |
| `testing/synctest` | 1.25 | 假时钟气泡，替代 `time.Sleep` 等待（见并发测试节） |

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

## Gin handler 测试：必须挂完整中间件栈

go-gin-api 约定 handler 出错只 `c.Error(err); return`，状态码由错误中间件映射。测试若绕过中间件，错误路径返回 200 空 body（Go 1.27 + gin v1.12 实测）。

```go
// NewRouter 是生产与测试共用的唯一路由装配点：测试若自己 gin.New() 只挂 handler，
// 错误路径会返回 200 空 body，测不出任何问题。
func NewRouter(h *Handler) *gin.Engine {
	r := gin.New()
	r.Use(gin.Recovery(), errorHandler())
	r.GET("/users/:id", h.GetUser)
	return r
}
```

```go
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			req := httptest.NewRequestWithContext(t.Context(), http.MethodGet, tt.path, nil)
			rec := httptest.NewRecorder()
			router.ServeHTTP(rec, req)
			require.Equal(t, tt.wantCode, rec.Code)
			require.JSONEq(t, tt.wantBody, rec.Body.String())
		})
```

`gin.SetMode(gin.TestMode)` 放 `TestMain`；响应体用 `require.JSONEq` 断言，不比对字符串。

## 出站 HTTP：httptest.NewServer 与 fake RoundTripper

```go
// httptest.NewServer：走真实 TCP 与 http.Transport，适合验证超时、重试、状态码语义。
func TestClient_Ping_Upstream5xx(t *testing.T) {
	t.Parallel()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusServiceUnavailable)
	}))
	t.Cleanup(srv.Close)

	err := outbound.NewClient(srv.URL, "tok", srv.Client()).Ping(t.Context())
	require.ErrorIs(t, err, outbound.ErrUpstream)
}

type roundTripFunc func(*http.Request) (*http.Response, error)

func (f roundTripFunc) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }

// fake RoundTripper：不开端口，直接断言出站请求的形状（header、path），单测里更快更稳。
func TestClient_Ping_SendsBearer(t *testing.T) {
	t.Parallel()
	hc := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		require.Equal(t, "Bearer tok", r.Header.Get("Authorization"))
		require.Equal(t, "/ping", r.URL.Path)
		return &http.Response{StatusCode: http.StatusOK, Body: io.NopCloser(strings.NewReader(""))}, nil
	})}
	require.NoError(t, outbound.NewClient("http://api", "tok", hc).Ping(t.Context()))
}
```

客户端必须接受注入的 `*http.Client`；fake `Response` 的 `Body` 不能为 nil。

## 集成测试隔离：testcontainers + 每测试事务回滚

```go
var pool *pgxpool.Pool

// 一个包一个容器（TestMain 起），一个测试一个事务（结束回滚）：用例之间零残留、可并行。
// Docker 不可用时 postgres.Run 直接报错 -> 测试失败，而不是 t.Skip 造成 CI 假绿。
func TestMain(m *testing.M) {
	ctx := context.Background()
	ctr, err := postgres.Run(ctx, "postgres:16-alpine",
		postgres.WithDatabase("app"), postgres.WithUsername("app"), postgres.WithPassword("secret"),
		postgres.BasicWaitStrategies())
	if err != nil {
		logger.Fatal("start postgres container", zap.Error(err))
	}
	dsn, err := ctr.ConnectionString(ctx, "sslmode=disable")
	if err != nil {
		logger.Fatal("connection string", zap.Error(err))
	}
	if pool, err = pgxpool.New(ctx, dsn); err != nil {
		logger.Fatal("open pool", zap.Error(err))
	}
	code := m.Run()
	pool.Close()
	logger.LogIf(testcontainers.TerminateContainer(ctr))
	os.Exit(code)
}

// txForTest 返回测试专用事务；t.Context() 在 Cleanup 前已被取消，回滚要用 WithoutCancel。
func txForTest(t *testing.T) pgx.Tx {
	t.Helper()
	tx, err := pool.Begin(t.Context())
	require.NoError(t, err)
	t.Cleanup(func() { _ = tx.Rollback(context.WithoutCancel(t.Context())) })
	return tx
}
```

`TestMain` 没有 `t`，是唯一允许 `context.Background()` 的地方。运行：`go test -tags integration -race ./integration/`。事务回滚测不到跨事务可见性与 `COMMIT` 触发的延迟约束/触发器，这类用例改用每测试独立 schema（`CREATE SCHEMA t_<name>` + `search_path`）。

| 方案 | 选择场景 | 代价 |
|---|---|---|
| testcontainers-go 模块（postgres/mysql/redis） | 主流；`Run` 内置就绪等待，`ConnectionString` 直接给 DSN | 依赖 Docker；首次拉镜像慢，CI 要缓存镜像层 |
| ory/dockertest | 已有存量、不想引入 testcontainers 的重依赖 | 就绪等待要自己写 retry；API 偏底层 |
| 共享外部库 + `TEST_DATABASE_URL` | 团队有常驻测试库、无 Docker 的环境 | 必须每测试独立 schema，否则并行互相污染 |

## 并发与时间：-race、goleak、synctest

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

## 内部测试包 vs 外部测试包

- `package amount_test`（外部）：只用导出 API，倒逼接口可用性，可避免 import 环。默认用它。
- `package amount`（内部）：测复杂私有算法（解析器状态机、哈希分片）时用。折中做法是 `export_test.go`：

```go
// export_test.go 属于内部测试包（package amount），只在 go test 时编译，
// 把私有函数暴露给同目录的外部测试包（package amount_test）。
var ParseFraction = parseFraction
```

"不测私有函数"不是规则：私有函数有独立复杂度且公开 API 难以覆盖全部分支时就该测，代价是重构时同步改测试。

## CI 参数速查

| 参数 | 作用 |
|---|---|
| `-race -covermode=atomic -coverprofile=cover.out` | 竞态检测；`-race` 下覆盖模式默认即 `atomic`，显式指定 `set`/`count` 会报错 |
| `-coverpkg=./...` | 统计被测包之外的代码覆盖（集成测试覆盖 service 层） |
| `-count=1` | 绕过测试缓存；`-count=N` 抓 flaky |
| `-shuffle=on` | 随机化顶层测试与子测试顺序，输出 seed 可复现 |
| `-run 'TestParseAmount/negative'` | 正则匹配，`/` 分隔子测试 |
| `gotestsum -- -race ./...` | 机器可读输出（内部走 `go test -json`）；汇总失败、重跑 flaky；已有 json 文件用 `--jsonfile` 回放 |
| `-tags integration` | 启用带 build 标签的集成测试 |
| `-bench . -benchmem -count 10` | 基准 + 分配统计，配 benchstat |

## 何时不该用 / 选型判断

| 场景 | 选择 | 理由 |
|---|---|---|
| 库代码、零依赖包 | 标准库 + go-cmp | testify 会进下游的 go.sum |
| 依赖是数据库/Redis | 真实例（testcontainers） | mock 出来的 SQL 字符串没有任何验证价值 |
| 断言"被调用了 N 次" | mock | 这是唯一 mock 优于 fake 的场景 |
| 等待异步结果 | synctest 或 channel 通知 | `time.Sleep` 在慢 CI 上必 flaky |
| 验证输出格式 | golden | 内联长字符串不可读、不可评审 |

## 审查清单

- [ ] 测试内无 `context.Background()`（TestMain 除外）、无 `b.N` 循环、无 `tt := tt`
- [ ] 错误断言用 `errors.Is` / `AsType`，无 `strings.Contains(err.Error(), ...)`
- [ ] `t.Parallel()` 的测试里没有 `t.Setenv` / `t.Chdir` / 包级可变状态
- [ ] 每个子测试的 mock 独立创建；`On(...)` 的 ctx 参数是 `mock.Anything`
- [ ] handler 测试通过生产路由装配函数构造，错误路径断言了 4xx/5xx 与响应体
- [ ] 集成测试有 build 标签；无 `t.Skip` 兜底；每测试事务回滚或独立 schema
- [ ] 同一接口的多个实现跑同一套契约 suite
- [ ] 时间相关逻辑用 synctest；包级 `goleak.VerifyTestMain` 或单测 `VerifyNone`
- [ ] 每条"线程安全 / 幂等 / 有界"注释都能指向一个 `-race` 下运行的反证测试
- [ ] 基准的数据准备在 `b.Loop()` 之外；对比用 `benchstat` 且 `-count ≥ 10`
- [ ] CI 命令含 `-race -shuffle=on -count=1 -covermode=atomic`
