---
name: go-enterprise-quality
description: 自己写或改 Go 代码后的交付前验证：build/vet/lint/govulncheck、按改动引入的新失败模式回审调用方、契约声明反证、整段重读。用户要求质量检查、上线前自查或评估改动对调用方的影响时使用。
allowed-tools: "Read, Write, Edit, Bash, Glob, Grep"
---

# Go 企业级质量门禁

自己写或改 Go 代码后的交付前验证。验证深度随改动类型走，不给一行文案改动跑全套。审查他人代码见 go-review；现代写法替换见 use-modern-go；lint / vulncheck 的 CI 配置见 go-engineering-governance；测试写法见 go-testing。

## 核心规则

1. 先按下表判定改动类型，再做对应深度的验证；"能编译"不等于"能上线"，但注释改动也不需要 govulncheck。
2. 每引入一个新失败模式，grep 全部调用方并逐个确认其错误分支是按新世界写的。
3. 契约声明（幂等、线程安全、最多一次、有界、不阻塞）没有反证测试就不写进注释或文档。写测试要先经用户同意；用户不要测试，就删声明，不留无凭据的承诺。
4. 刚改过的代码是最高嫌疑：交付前重读整个函数与调用链，不只看新增行。
5. 日志一律 `github.com/gtkit/logger/v2` + `zap` 字段构造器（见 go-observability）；不新增标准库 `log`。

## 按改动类型选验证深度

| 改动 | 做 | 不做 |
|---|---|---|
| 注释、日志文案、错误消息文本 | `go build` + `go vet` | 其余全部 |
| 不改签名、不加错误路径的实现调整 | 上一行 + `golangci-lint` + 现有测试 `-race` + 整段重读 | 调用方回审 |
| 新增 error 返回、部分成功、新超时、返回值含义变化、签名变化 | 上一行 + 调用方影响分析 | |
| 触及锁、Once、CAS、channel 关闭，或写下任何契约声明 | 上一行 + 契约反证（先向用户确认要不要写测试） | |
| 新增或升级依赖 | 上一行 + `govulncheck` | |

一次改动落在多行时按最深的那一行做。判定结果写进交付说明的第一句。

## 写前分析

1. **读现有代码**：同包的错误处理风格（哨兵 / `*AppError`）、命名、日志方式、context 传递方式，新代码与之一致。
2. **核对接口契约**：要实现的接口有哪些方法、文档承诺了什么（是否允许并发调用、是否可重入）。
3. **列出依赖方**：`grep -rn "包名\." --include="*.go"` 找出谁在用这个包，评估波及面。
4. **读现有测试**：用户要求补测试时沿用现有风格（table-driven、testify、httptest、sqlmock）。

## 编码标准（写代码时逐条对照）

### 正确性
- 每个 `error` 都被处理：返回、包装（`fmt.Errorf("...: %w", err)` 只在增加信息时）、或明确注释为何可忽略。
- nil 判断只针对外部输入与可选依赖（请求参数、可为 nil 的回调、可选 client）；内部不变量（构造函数保证非 nil 的字段）靠测试保证，不在每处解引用前重复判 nil。
- 共享状态有锁或 atomic 保护，Lock/Unlock 成对；锁内不做 I/O。
- ctx 从入口一路传到 I/O 调用；后台任务需要保留 value 时用 `context.WithoutCancel`，并自带超时。
- 每个 goroutine 有退出路径；channel 只由发送方关闭。
- slice / map 访问的下标与 key 来自外部时先校验范围。

### 稳定性
- 下游失败有降级行为（返回缓存、默认值、或明确的 503），不无限阻塞。
- worker 与 handler 启动的 goroutine 内有 `recover`，panic 记日志并计数。
- 资源获取后立刻 `defer Close()`；循环内的 defer 提取为子函数。
- DB / HTTP / Redis client 全局复用，不在请求内新建。
- 所有外部调用（HTTP、DB、Redis、gRPC）带超时；`http.Client` 必须设 `Timeout` 或用 ctx 超时。

### 性能
- 已知长度的 slice / map 预分配；热路径不用 `fmt.Sprintf` 拼接、不用 `reflect`。
- 批量查询用 `IN` / JOIN，不在循环里逐条查库（N+1）。
- 大 struct 传指针、小值类型传值；`sync.Pool` 的 Put 前检查 `cap` 上限。

### 安全
- SQL 只用参数化；列名 / 排序字段走白名单。
- 请求体 `http.MaxBytesReader` 限长；binding 到独立 DTO。
- 受保护端点校验 JWT（`jwt.WithValidMethods`）；密码、token 不进日志、不进响应。
- 用户可控路径用 `os.Root` / `filepath.IsLocal`。

## 写后验证命令

```bash
go build ./...
go vet ./...
golangci-lint run ./...                      # 实现调整及以上
go test -race -count=1 ./path/to/package/... # 实现调整及以上；只跑受影响的包
govulncheck ./...                            # 新增或升级依赖时
```

- `go vet` 的告警全部消除（`copylocks`、`lostcancel`、`printf`、`waitgroup`、`tests`、`stdversion` 都在默认集合里）。
- `golangci-lint` 未安装：`go install github.com/golangci/golangci-lint/v2/cmd/golangci-lint@latest`（v2 模块路径）。项目无配置文件时用默认 linter 集合，配置文件的治理见 go-engineering-governance。
- `govulncheck` 未安装：`go install golang.org/x/vuln/cmd/govulncheck@latest`。它只报告代码实际可达的漏洞函数，输出为空才算通过；有报告时升级依赖，升不了的写明原因。
- `-race` 检测数据竞争；`-count=1` 禁用缓存保证真跑。测试失败先查是测试错还是代码错，不改断言凑绿。

## 调用方影响分析（引入新失败模式时，每个被改函数执行一次）

1. **列出改动引入的新失败模式**：新的 error 返回、部分成功（批量操作有的成功有的失败）、新超时、新并发交错、返回值含义变化（nil 从"不存在"变成"存在但为空"）。
2. **grep 全部调用方**：
   ```bash
   grep -rn "FunctionName(" --include="*.go" .
   ```
   接口方法还要 grep 接口名，找到通过接口调用的位置。
3. **逐个调用方核对错误分支**：它是否按"全成功或全失败"写的？遇到部分成功会不会把已写入的数据当作未写入而重试、产生重复？新的超时会不会让上游把 `DeadlineExceeded` 当业务错误返回 500？
4. **签名变化**：新增参数的每个调用方传的值是否正确，而不是为了编译通过传零值。
5. 结论写进交付说明：调用方列表、每个调用方"已适配 / 无需适配（理由）"。

交叉验证随改动类型顺带做：改 handler 查路由注册与中间件链；改 repository 查事务边界与连接释放；改 worker 查重试、幂等、失败恢复；新接口实现加 `var _ Iface = (*Impl)(nil)`；新配置项有默认值、无硬编码 URL / 端口 / 凭证。

## 契约声明的反证

注释或文档里每写一句"并发安全""只执行一次""幂等""不阻塞"，就要有一个"该声明为假时必定失败"的测试。写测试前先问用户；用户不要，就删声明。最小示例（Go 1.27 实测：去掉 `sync.OnceValues` 后此测试在 `-race` 下失败，报 `load 执行了 100 次，契约要求 1 次`）：

```go
// Loader.Init 契约：并发调用时 load 只执行一次，所有调用方拿到同一结果。
// 这条契约由 TestLoader_Contract 反证——去掉 sync.OnceValues 该测试在 -race 下必失败。
type Loader struct {
	once func() (string, error)
}

func NewLoader(load func() (string, error)) *Loader {
	return &Loader{once: sync.OnceValues(load)}
}

func (l *Loader) Init() (string, error) { return l.once() }
```

```go
func TestLoader_Contract(t *testing.T) {
	t.Run("并发调用不重复执行", func(t *testing.T) {
		var calls atomic.Int32
		l := NewLoader(func() (string, error) {
			calls.Add(1)
			return "cfg", nil
		})
		var wg sync.WaitGroup
		for range 100 {
			wg.Go(func() {
				if _, err := l.Init(); err != nil {
					t.Error(err)
				}
			})
		}
		wg.Wait()
		if got := calls.Load(); got != 1 {
			t.Fatalf("load 执行了 %d 次，契约要求 1 次", got)
		}
	})
}
```

用户要求补测试时，边界输入按入参枚举取（空输入、nil、超长、负值、极大值、重复值、路径元字符），时间逻辑用 `testing/synctest`；其余写法见 go-testing。

## 最终核验

1. `go build ./...` 与 `go vet ./...` 再跑一次（验证阶段之后可能又改了代码）。
2. 实现调整及以上：`go test -race -count=1 ./affected/package/...`。
3. **重读整个被改函数与调用链**：不只看 diff 的 `+` 行，从函数第一行读到最后一行，再顺着调用链读一层。检查新增行是否改变了原有分支的前提——锁的范围、defer 的顺序、提前 return 是否跳过了清理、新加的 early return 是否让后面的 `Commit` 不再执行。
4. **对照 use-modern-go 审查清单**过一遍新代码。
5. 清理调试痕迹：临时打印、注释掉的代码、调试用的环境变量。

## 补充禁令

- **抽取公共函数时，逐个核对被合并的常量与分支为什么不同。** 两个调用点一个超时 3s、一个 30s，通常是有原因的（一个在请求路径、一个在后台任务）；统一成一个值就是引入回归。合并前把每处差异列出来并给出"为何可以统一"的理由，给不出就保留参数。
- **声称某个竞态窗口"已关闭"之前，必须有一个"移除该机制就会失败"的测试。** 做法与上面的契约测试相同：把锁 / Once / CAS 临时去掉，测试在 `-race` 下必须失败，再恢复。没有这种测试只能说"已缩窄"，不能说"已关闭"。
- **用"代价不成比例"驳回需求之前，先给出具体实现方案与量化成本**（行数 / 内存 / 延迟），并至少比较两种数据结构。
- **概率论据必须先测量**：`-race` 跑 `-count=100`、或 benchmark 数据，测不出来就换论据。

## 严重度分级

| 问题 | 级别 | 处置 |
|---|---|---|
| 编译失败、`go vet` 告警 | BLOCKER | 立即修复 |
| 数据竞争（`-race` 报告） | BLOCKER | 立即修复 |
| 未处理的 error、goroutine 无退出路径 | CRITICAL | 完成前修复 |
| 调用方未按新失败模式适配 | CRITICAL | 完成前修复 |
| 契约声明无反证测试 | HIGH | 经用户同意补测试，否则删声明 |
| `govulncheck` 报告可达漏洞 | HIGH | 升级依赖，否则写明原因 |
| N+1、热路径分配 | HIGH | 优化或写明量化理由 |
| 外部输入未判 nil / 未校验范围 | HIGH | 完成前修复 |
| 缺少 ctx 传递 | MEDIUM | 修复 |
| 命名 / 风格不一致 | LOW | 顺手修 |
