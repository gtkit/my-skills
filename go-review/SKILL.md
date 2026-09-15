---
name: go-review
description: 审查 Go 代码：输入域枚举与调用方回审、并发/错误/资源/安全等七维度、置信度过滤、附修复代码。用户贴出 Go 代码、diff 或 PR 要求 review、找问题、查并发安全时使用。
---

# Go 代码专项审查

面向 Go 代码的多维度审查 + 置信度过滤：只报高置信度的真实问题，每个问题附修复代码。现代写法替换清单是 use-modern-go 的职责，本文件只引用；自己写代码时的门禁流程见 go-enterprise-quality。

## 目标 Go 版本

**默认：Go 1.27**。用户提供 `go.mod` 或明确指定版本时以用户为准；版本相关的判断（Timer GC、`b.Loop`、`new(expr)` 等）必须先确认 `go.mod` 的 `go` 指令。

## 核心理念

- **精准胜过全面**：只报告置信度 > 50 的真实问题，不输出"可能有问题"的噪音。
- **审查从代码出发，不从作者意图出发**：不只验证"想改的那件事成了"，而是排查"碰过的面还对不对"。
- **可操作**：每个问题附具体修复代码。
- **尊重作者意图**：理解改动目的再审查，不按个人偏好重写。

## 审查流程

### 第一步：快速理解

1. **变更范围**：这段代码做了什么？属于哪一层（handler / service / repository / middleware / 工具库）？
2. **依赖上下文**：用了哪些外部库（Gin、GORM、go-redis、gobreaker、gorilla/websocket、asynq 等）？
3. **并发模型**：有没有 goroutine？是否涉及共享状态？

上下文不足时先说明假设再开始。

### 第二步：输入域枚举与调用方回审

对 diff 中每个被新增或修改的函数，按以下四步执行，结果写进审查输出：

1. **逐个入参枚举边界值**：空字符串、元字符（glob / 正则 / SQL / 路径中的 `..`）、nil 与 typed-nil（`var p *T; var i any = p` 时 `i != nil`）、零值、负值、极大值（`int` 溢出、`len` 上限）、重复值。问"这个参数的全部合法取值里，哪些会让当前实现出错"，不问"作者传的那个值能跑通吗"。
2. **新失败模式回审全部调用方**：diff 引入了部分成功、新错误路径、新超时、新并发交错中的任何一种，就 `grep -rn "FuncName(" --include="*.go"` 找出全部调用方，逐个确认其错误分支是按"新世界"写的。旧调用方通常按"全成功或全失败"处理，遇到部分成功会把已写入的数据当作未写入。
3. **契约声明必须有反证测试**：注释或文档里出现"幂等""线程安全""最多执行一次""不阻塞""有界"等声明时，找对应的"若该声明为假就会失败"的测试；找不到，就把这条声明本身报为问题（置信度 ≥ 76），要求补测试或删声明。
4. **改过的函数整段重读**：不只看 `+` 行。重读整个函数体与它的直接调用链，检查新增行是否改变了原有分支的前提（锁范围、defer 顺序、提前 return 跳过了清理）。

### 第三步：七维度深度审查

#### 维度 1：并发安全

**数据竞争：**
- 多 goroutine 读写同一变量是否有同步保护？包级配置变量是否被并发读写而无 `atomic.Pointer[T]`？
- `sync.Mutex` 是否成对 Lock/Unlock？是否 `defer Unlock()`？锁是否按值拷贝（`go vet` 的 copylocks）？
- `sync.RWMutex` 读写锁是否用对？持读锁期间是否又申请写锁（自死锁）？
- `sync.Map` 是否用在写多、key 频繁变化的场景（应 `map` + `sync.RWMutex`）？

**Goroutine 泄漏：**
- 每个 goroutine 是否有明确退出路径（context cancel、done channel、超时）？
- `for { select {} }` 是否有 `case <-ctx.Done()`？
- `wg.Add(1)` / `wg.Done()` 是否匹配？Go 1.25+ 用 `wg.Go()`；`go vet` 的 `waitgroup` 分析器能查到部分错用。
- channel 发送端 / 接收端是否可能永远阻塞？HTTP handler 中启动的 goroutine 是否被追踪？

**Channel 使用：**
- 无缓冲 channel 是否可能死锁？是否只在发送方关闭？是否可能重复关闭？
- `select` 的 `default` 分支是否造成忙轮询？

**Context 传播：**
- 是否用 `context.Background()` 替代了本该传入的 `ctx`？后台任务需要保留 value 时是否用 `context.WithoutCancel`？
- context 是否被存进 struct 字段（应通过参数传递）？
- `WithCancel` / `WithTimeout` 的 cancel 是否被调用（`go vet` 的 lostcancel）？
- 测试中是否仍用 `context.Background()` 而非 `t.Context()`（Go 1.24+）？

#### 维度 2：错误处理

- 每个 `error` 返回值是否被检查？`_` 丢弃的 error 是否真的可以忽略？
- 包装是否只在增加信息时 `fmt.Errorf("...: %w", err)`，纯透传是否直接 `return err`？
- 哨兵比较是否用 `errors.Is`；类型匹配是否用 `errors.AsType[T]`（Go 1.26+）？
- `defer f.Close()` 忽略的 error 在写文件场景是否会吞掉落盘失败？
- library 代码是否 panic 而不是返回 error？`recover` 是否只在 goroutine 边界与 worker 内？
- `context.Canceled` / `DeadlineExceeded` 是否被当成服务端错误记 ERROR 日志（应降为 WARN，HTTP 映射 499 / 504）？
- 错误分类见 go-error-handling。

#### 维度 3：资源管理

- **数据库**：`*sql.Rows` 是否 `defer rows.Close()` 并检查 `rows.Err()`？GORM 的 `Rows()` 同理。
- **HTTP 响应体**：`resp.Body` 是否 `defer Close()`？错误分支是否也关闭？
- **文件句柄**：`os.Open` 后是否 `defer f.Close()`？
- **定时器**：Go 1.23 起 Timer 与 Ticker 未被引用即可被 GC，`time.After` / `time.Tick` 不再泄漏，`Stop()` 不是防泄漏必需，只在需要提前终止时调用；Go 1.23 前（看 `go.mod`）的 `defer Stop()` 是必要的。
- **锁**：`Lock()` 后是否 `defer Unlock()`？临界区是否包含了 I/O（锁内做网络调用）？
- **事务**：是否 `defer tx.Rollback()` 保底 + 成功后 `tx.Commit()`？GORM 是否用 `db.Transaction(fn)`？
- **循环中的 `defer`**：`defer` 是函数级别的，循环体内的 `defer` 累积到函数返回才执行，必须提取为子函数。

#### 维度 4：性能陷阱

- **热路径分配**：`fmt.Sprintf` 拼接 → `strings.Builder` / `strconv.Append*`；循环内重复 `make([]byte)` → 预分配或 `sync.Pool`（Put 前检查 `cap` 上限）。
- **Slice 陷阱**：`append` 是否意外改写共享底层数组？大 slice 的小切片是否长期持有阻止 GC（`slices.Clone` / `Clip`）？已知长度是否 `make([]T, 0, n)`？
- **Map 陷阱**：是否预估大小 `make(map[K]V, n)`？map 值为大 struct 时是否应存指针？
- **反射与 JSON**：热路径是否有 `reflect`、`json.Marshal` 多一次拷贝（可用 `json.NewEncoder(w)` 直写）？
- **接口装箱**：小值类型在热路径是否被装箱为 `any` 造成逃逸？
- 量化判断见 go-performance（先 profile 再优化，不凭感觉）。

#### 维度 5：Go 惯用法与现代特性

**现代写法**：现代写法替换项以 `use-modern-go` 的审查清单为准，逐条对照；每条命中都标注所需最低 Go 版本并核对 `go.mod`。

**命名规范：**
- 导出函数 / 类型是否有以其名字开头的 doc comment？
- 单方法接口是否以 `-er` 结尾？包名是否简短、小写、无下划线？
- receiver 名是否为一两个字母且全文件一致（非 `this` / `self`）？
- 哨兵错误是否以 `Err` 前缀、自定义错误类型是否以 `Error` 后缀？

**结构组织：**
- 是否有不必要的 `else`（提前 return 消除嵌套）？
- `init()` 是否有隐藏副作用（连接外部服务、读环境变量）？
- 导出函数是否返回未导出类型？参数是否用 `*zap.Logger` 之类具体日志类型（应用 gtkit logger 包级函数或接口）？

#### 维度 6：生态库已知陷阱

**GORM：**
- `First` / `Find` 是否先检查 `result.Error` 再看 `RowsAffected`？
- `Save` 是否意外全字段更新（应 `Updates` / `Select`）？upsert 是否用 `clause.OnConflict`？
- 事务中是否误用 `db` 而非 `tx`？链式调用是否有条件泄漏（缺 `Session(&gorm.Session{})`）？
- 排序字段 / 列名是否来自用户输入且未走白名单？N+1 是否用 `Preload` / `Joins`？

**Gin：**
- `ShouldBind*` 后是否检查 error？是否绑到独立 DTO 而非 GORM model？
- `c.JSON` / `c.AbortWithStatusJSON` 之后是否缺 `return`？middleware 是否调用了 `c.Next()` 或 `c.Abort()`？
- 5xx 响应是否回显了 `err.Error()`（泄漏内部信息）？错误响应是否带 `request_id`？
- goroutine 中是否直接使用 `*gin.Context`（须 `c.Copy()`，并用 `context.WithoutCancel(c.Request.Context())`）？
- 是否设置了 `SetTrustedProxies`、`http.MaxBytesReader`？

**go-redis：**
- `Err()` 是否检查？`redis.Nil` 是否用 `errors.Is` 判断？
- `MaxRetries`（默认 3）对读超时也会重试：`INCR` / `LPUSH` / `SET NX` 等非幂等命令可能重复执行——非幂等路径要么 `MaxRetries: -1`，要么命令本身幂等化。
- 类型是否用 `redis.UniversalClient`？`KEYS` 是否应为 `SCAN`？分布式锁是否有超时、续期，`Release` 是否用 `context.WithoutCancel`？

**gobreaker：**
- 未设置 `IsSuccessful`（v2 另有 `IsExcluded`）时所有非 nil 错误都计为失败，客户端 `context.Canceled` 也会把熔断器打开——必须把 ctx 取消与业务 4xx 排除在失败计数外。
- `Execute` 返回 `ErrOpenState` / `ErrTooManyRequests` 时是否有降级路径而不是直接 500？

**gorilla/websocket：**
- 单个 `*Conn` 只允许一个并发 writer 与一个并发 reader（`WriteMessage` / `WriteJSON` / `NextWriter` / `SetWriteDeadline` 都算写）；广播场景必须每连接一个发送 goroutine + channel 串行化，否则 panic 或帧交错。
- 是否设置了 `SetReadLimit`、读写 deadline 与 pong handler？`CheckOrigin` 是否放行了所有来源？

**asynq / 队列消费：**
- handler 是否幂等？payload 反序列化失败是否返回 `asynq.SkipRetry`？长任务是否检查 `ctx.Done()`？

**net/http：**
- `http.Client` 是否设置 `Timeout`（默认无超时）？是否复用而非每请求新建？
- `http.Server` 是否设置 `ReadHeaderTimeout`；SSE / 长连接路由 `WriteTimeout` 是否为 0 或用 `ResponseController.SetWriteDeadline`？
- `/livez` 是否误做了依赖检查（依赖检查只属于 `/readyz`）？

#### 维度 7：安全

- SQL 是否参数化？`Where("id = ?", id)` 而非字符串拼接；列名 / 排序字段是否白名单？
- 用户输入是否在 handler 边界校验？路径是否用 `os.Root` / `filepath.IsLocal` 防穿越？
- 是否硬编码密钥、token、密码？日志是否输出了敏感字段？
- JWT 是否用 `jwt.WithValidMethods` 限定算法、校验 `exp` / `iss` / `aud`？密码哈希是否 argon2id 或 bcrypt cost ≥ 12？
- 随机数在安全场景是否用 `crypto/rand`？
- 详见 go-security。

### 第四步：置信度评分与过滤

| 分数 | 含义 | 标记 |
|------|------|------|
| 0-50 | 假阳性、nitpick、或需要更多上下文 | **不输出** |
| 51-75 | 真实问题但影响有限 | [注意] |
| 76-90 | 高置信度，影响功能或可靠性 | [问题] |
| 91-100 | 确定的严重 bug，必须修复 | [严重] |

**只输出置信度 > 50 的问题。**

### 第五步：输出格式

```
## Go Code Review

### 概要
<一句话总结变更内容和整体评价>

### 输入域与调用方回审
- <函数名>：枚举了哪些边界值、发现什么；新失败模式波及的调用方列表与结论
- 契约声明：<声明> → 有/无反证测试

### 发现的问题

**[严重] <问题标题>** (置信度: XX)
- **位置**: `函数名` / 第 N 行
- **问题**: <简明描述>
- **影响**: <会导致什么线上后果>
- **修复**:
  ```go
  // 修复代码
  ```

**[问题] <问题标题>** (置信度: XX)
- **位置** / **问题** / **修复** 同上

**[注意] <问题标题>** (置信度: XX)
- **位置** / **问题** / **建议**

### 现代化建议
<对照 use-modern-go 审查清单命中的旧模式，标注最低版本>

### 总结
- 严重: X 个 | 问题: X 个 | 注意: X 个
<若无问题：代码质量良好，未发现显著问题。>
```

## 假阳性过滤规则（必须严格遵守）

以下情况 **不要报告**：

1. **golangci-lint / go vet / gofmt 能捕获的问题**（格式、未使用变量、import 排序）
2. **已有问题**：不是这次变更引入的（除非变更让它从潜伏变成可触发）
3. **迂腐的 nitpick**：资深 Go 工程师不会在 PR 中提的
4. **通用建议**："建议加测试"、"建议加文档"——契约声明缺反证测试除外，那是具体问题
5. **nolint 注释压制的问题**
6. **有意为之的设计**：不要把作者的架构选择当 bug
7. **纯风格偏好**：tab vs space、行长度等主观分歧

## 特殊场景

### 只有一个函数
- 聚焦 bug、错误处理、并发安全与入参边界，弱化架构评审
- 明确说明缺少调用方上下文可能导致误判

### diff / patch 格式
- 聚焦 `+` 行，但按第二步第 4 条重读被改函数全文；`-` 行用于判断行为是否变化
- 只审查变更引入的问题

### 上传 .go 文件
- 按完整文件审查，关注包级设计（exported API、init 副作用、全局状态）

### 多文件审查
- 关注文件间接口一致性与依赖方向；error 类型是否在包边界正确传播

## 与其他 Go Skills 的配合

| 领域 | 对应 Skill |
|------|-----------|
| 现代语法替换清单 | use-modern-go |
| 自己写代码时的质量门禁 | go-enterprise-quality |
| Gin API 模式 | go-gin-api |
| 数据库操作 | go-database-patterns |
| 并发模式 | go-concurrency |
| Redis 客户端用法 | go-redis-patterns |
| 缓存一致性、穿透 / 击穿 / 雪崩 | go-cache-consistency |
| 事务隔离、Saga / outbox | go-data-consistency |
| 限流、熔断、重试、超时预算 | go-stability-engineering |
| 错误类型 / 错误码 / HTTP 映射 | go-error-handling |
| 安全编码 | go-security |
| 日志 / metrics / tracing | go-observability |
| 测试编写 | go-testing |

## 沟通原则

1. **对事不对人**：指出代码问题，不评价开发者水平
2. **给修复代码**：不只说"这里有问题"，给出 Go 惯用的修复方式
3. **区分严重等级**：让作者知道哪些必须改、哪些可以后续优化
4. **承认不确定**：缺少上下文时诚实说明，不硬判
5. **结论以事实为准**：写得好就说好，不为凑数量报低质量问题
