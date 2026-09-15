# skills

面向生产环境的工程 skill 集合，每个子目录一个 skill（`<name>/SKILL.md`），可直接放入 `~/.claude/skills`、`~/.codex/skills`，或用 `pack.sh` 打包为 `.skill` 上传到 claude.ai。

目标水准：资深技术专家——不只把代码写对，还要给出架构判断、稳定性兜底、方案取舍，并且每条规则可证伪、每段代码可编译。

## 目录

### 判断层（先读：怎么想、怎么选）

| skill | 内容 |
|---|---|
| `senior-go-engineer` | Go 服务从需求到上线的决策框架：6 个必问数字、单体/模块化单体/微服务判定、分层与包设计、泛型边界、存储与缓存与 MQ 选型、分布式事务替代顺序、稳定性 4 问、容量与副本数 |
| `tech-design-review` | 技术方案文档模板（含非目标、候选方案对比、失败模式、上线与回滚）、ADR 模板、容量估算公式、评审清单与否决项；语言无关 |
| `senior-php-engineer` / `senior-python-engineer` / `senior-nodejs-engineer` / `senior-frontend-engineer` / `senior-rust-engineer` / `senior-lua-engineer` / `senior-openresty-engineer` / `senior-devops-engineer` | 各语言/领域的运行时行为、版本特性归属、生产事故高发点与选型判断；开头统一的"工作方式"段，其余全部是可证伪事实 |

### 规范层（写任何代码前生效）

| skill | 内容 |
|---|---|
| `use-modern-go` | 现代 Go 写法的单一真源：Go 1.0–1.27 每个"旧写法 → 现代写法"条目标注版本并经 `go doc` 核实；其他 Go skill 只引用它 |
| `use-modern-php` | PHP 8.0–8.5 语法与运行时特性，附实测报错原文 |
| `go-review` | Go 代码审查：输入域枚举与调用方回审 → 七维度审查 → 置信度过滤 → 输出格式；生态库（GORM/Gin/go-redis/gobreaker/gorilla）已知陷阱 |
| `go-enterprise-quality` | 写/改 Go 代码时的门禁流程：build / vet / lint / govulncheck / `-race` 测试、调用方影响分析、契约声明必配反证测试 |
| `code-simplifier` | 代码简化：行为等价性验证步骤、性能特征变化提醒、不动的边界（并发、金融精度、错误路径、安全校验） |

### Go 专项模式层（做具体事时读）

| skill | 内容 |
|---|---|
| `go-gin-api` | Gin 服务骨架：`http.Server` 超时、优雅关闭、请求体限制、DTO 校验、JWT、CORS、幂等接口、`/livez` `/readyz`、handler 内异步的正确姿势 |
| `go-error-handling` | `AppError`（`Error/Unwrap/Is`）、错误码分段、可重试分类、ctx 取消映射 499/504、跨服务错误映射、panic 边界、wrap 边界 |
| `go-concurrency` | 内存模型要点、goroutine 生命周期、有界并发三选一、worker pool、pipeline、singleflight、sync 原语适用条件、泄漏与死锁、`testing/synctest` |
| `go-testing` | 表驱动 + `t.Parallel`、`cmp.Diff`、fake/stub/mock 取舍、契约测试、Gin handler 测试、testcontainers + 事务回滚、goleak、fuzz、golden、`b.Loop`、CI 参数 |
| `go-database-patterns` | 驱动/ORM 选型、DSN 与连接池推导、查询正确性、GORM 陷阱、keyset 分页、索引与 EXPLAIN、大表变更、读写分离、ctx 与连接、建表规范 |
| `go-data-consistency` | 隔离级别与幻读、死锁/序列化失败重试、悲观锁 vs 乐观锁 vs 原子条件更新、幂等键状态机、Saga/TCC/Outbox 选型与实现、对账 |
| `go-redis-patterns` | go-redis v9 客户端语义（超时/重试/路由）、数据结构选型与大 key 口径、Pipeline/TxPipeline、Cluster 约束、Lua 脚本、单节点锁、Pub/Sub vs Streams |
| `go-cache-consistency` | 缓存写路径时序、延迟双删、binlog 失效、版本 CAS、穿透/击穿/雪崩、热 key 与本地二级缓存、大 key 渐进删除、Redlock 争议与 fencing token |
| `go-mq-patterns` | Kafka/RocketMQ/NATS/RabbitMQ 客户端选型、投递语义与消费幂等、顺序、重试与死信、位点提交、事务消息、延迟消息、积压处理、消息设计 |
| `go-microservice` | 优雅关闭与 k8s 发布时序、健康检查、幂等接口设计、HTTP 客户端、gRPC 拦截器/deadline/status 映射、超时预算传播、服务发现与网格选型 |
| `go-stability-engineering` | 超时预算、重试（单层/退避/预算）、熔断（`IsSuccessful`）、限流选型、隔仓与背压、降级与预案、灰度与回滚、SLO 与 burn-rate 告警、容量评估、故障演练 |
| `go-observability` | `gtkit/logger/v2` 初始化与字段规范、request_id 中间件、trace↔log 关联、OTel 初始化与自动埋点、Prometheus RED 指标与高基数禁令、慢 SQL、SLO PromQL |
| `go-performance` | pprof 安全暴露与读法、mutex/block profile、线上排障路径、`GOMEMLIMIT`、PGO、GOMAXPROCS 容器感知、逃逸分析输出解读、分配优化、Benchmark |
| `go-security` | 传输/入口/应用/数据/供应链分层：TLS、JWT v5 与密钥轮换、argon2id、IDOR、SSRF 安全客户端、解析炸弹、路径穿越、CSRF、安全头、`govulncheck` |
| `go-websocket-sse` | WS/SSE/长轮询选型、单读单写规则、纯 actor Hub、优雅关闭、背压策略、水平扩展、连接数预算、SSE `Last-Event-ID` 补发 |
| `go-engineering-governance` | `.golangci.yml`（v2）、CI 门禁流水线、依赖治理、`apidiff` 与兼容性、fail-closed 破坏性变更、发布纪律、PGO 流程、项目布局 |

### 其他语言/领域专项

| skill | 内容 |
|---|---|
| `openresty-patterns` | ngx_lua 各阶段 API 可用性、shared dict 真实行为、三级缓存与击穿防护、cosocket 连接池、`ngx.re`、cjson、timer、阻塞排查——全部本机实测 |
| `shell-scripting` | Bash 脚本骨架、`set -e` 失效点、引用与数组、trap 与信号、getopts、锁与超时、macOS/BSD 与 GNU 差异、bash 3.2 兼容 |

### 流程工具

| skill | 内容 |
|---|---|
| `planning-with-files` / `planning-with-files-web` | 基于文件的任务规划（task_plan / findings / progress）；在 git 仓库内使用时把三个文件写入 `.git/info/exclude` |

## 组合方式

- 任何 Go 代码：`use-modern-go` 常驻；交付前验证走 `go-enterprise-quality`（验证深度按改动类型分级，文案改动只跑 build/vet）；审查走 `go-review`；架构与选型问题走 `senior-go-engineer`，方案文档走 `tech-design-review`；具体领域再叠加对应的 go-* 专项。
- 主题归属只有一处实现，其他 skill 引用而不重复：日志/metrics/tracing 在 `go-observability`；限流/熔断/重试/超时预算在 `go-stability-engineering`；缓存一致性在 `go-cache-consistency`；事务与分布式事务在 `go-data-consistency`；错误类型与错误码在 `go-error-handling`。

## 文件布局与描述规范

- `description` 只写"做什么 + 什么时候用"，每条 150 字以内。Claude Code 对全部 skill 描述有总字数预算，超出后靠后的 skill 描述会被截空、不再触发；触发词长尾与分工说明放正文。
- 内容多的 skill 拆成"路由 + references/"：`SKILL.md` 只放核心规则、判断表、审查清单与"按任务读取"路由表，代码模板与逐版本速查放 `references/*.md`，按路由表只读本次任务需要的文件。判定标准：`SKILL.md` 超过 250 行，或含 3 段以上代码模板就拆。目前 22 个已拆，其余正文都在 300 行以内。
- 同一条规则只在一处写全：审查四条（枚举输入域、回审调用方、契约反证、整段重读）完整版在 `go-review` 与 `go-enterprise-quality`，其他 skill 一句话引用。

## 全仓公共约定

- 目标 Go 1.27；写法以 `use-modern-go` 为准。
- 日志一律 `github.com/gtkit/logger/v2`（包级 `*Ctx` 函数），字段构造器用 `go.uber.org/zap`。
- `http.Server` 显式设置全部超时字段；`/livez` 不带依赖检查，`/readyz` 才带。
- 哨兵错误用 `errors.Is`；5xx 不回显内部错误；金额用 `int64`（最小货币单位）或 decimal。
- 每个 Go 代码块都对应一个 `go vet` 通过的验证文件；带"实测"标注的断言都有本机复现。

## 脚本

| 脚本 | 用途 |
|---|---|
| `pack.sh [name...]` | 打包为 `_dist/<name>.skill`（zip），排除 `.DS_Store` |
| `sync.sh [name...]` | 把 skill 目录同步到 `~/.claude/skills` 与 `~/.codex/skills`（`TARGETS` 可覆盖）；目标目录里仓库没有的 skill 保持不动 |
| `sync.ps1 [name...]` | 同上，Windows 原生 PowerShell 版，用 robocopy /MIR 镜像到 `%USERPROFILE%\.claude\skills` 与 `%USERPROFILE%\.codex\skills`（`$env:TARGETS` 可覆盖，分号分隔） |

## 维护规则

- 单文件 ≤ 400 行；示例只保留说明问题所必需的部分。
- 每条规则可证伪；版本相关事实标注版本；未核实的断言不写。
- 新增或修改 Go 代码块时，先在独立模块里 `go vet` 通过，再粘贴进 SKILL.md。
- 引用其他 skill 只用真实目录名。
