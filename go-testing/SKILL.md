---
name: go-testing
description: Go 测试写法与工具：表驱动与 t.Parallel、断言取舍、fake/mock、Gin handler 与出站 HTTP 测试、testcontainers、契约测试、-race/goleak/synctest、Fuzz、golden、Benchmark。写或改测试、治 flaky 时使用。
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

## 按任务读取

以下内容按任务读取，只读本次需要的文件；核心规则与审查清单已覆盖其结论。

| 任务 | 读 |
|---|---|
| 写单元测试：表驱动、断言、fake/stub/mock、接口契约 suite | `references/unit.md` |
| 测 Gin handler 与出站 HTTP | `references/http.md` |
| 集成测试：testcontainers 与事务回滚隔离 | `references/integration.md` |
| 并发与时间：-race、goleak、synctest | `references/concurrency.md` |
| Fuzz、golden 文件、Benchmark | `references/fuzz-golden-bench.md` |

## 现代 testing API 速查

| API | 版本 | 用途 |
|---|---|---|
| `t.Context()` | 1.24 | 随测试结束取消的 ctx，替代 `context.Background()` |
| `for b.Loop()` | 1.24 | 自动排除 setup、防止结果被优化掉；不与 `b.N` 循环混用 |
| `t.Attr(k, v)` / `t.Output()` | 1.25 | 输出 CI 可解析的键值属性；返回与 `t.Log` 同流、带缩进的 `io.Writer` |
| `testing/synctest` | 1.25 | 假时钟气泡，替代 `time.Sleep` 等待（见并发测试节） |

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
