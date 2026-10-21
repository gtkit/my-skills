# skills

面向生产环境的工程 skill 集合，每个子目录一个 skill（`<name>/SKILL.md`）。同步脚本默认安装到 Codex 的 `~/.agents/skills`，并备份迁移旧 Codex 目录里的本仓库同名副本。其他支持 Agent Skills 的工具可按各自约定安装，也可用 `pack.sh` 打包为 `.skill`。

目标水准：资深技术专家——不只把代码写对，还要给出架构判断、稳定性兜底、方案取舍，并且每条规则可证伪、每段代码可编译。

## 目录

按语言和领域选择技能；每个技能只归入一个主分类，跨领域组合见下方“组合方式”。本节用于查找，技能目录继续保持根目录平铺，沿用现有技能名称、同步和打包方式。

`catalog.yaml` 的顶层 `categories` 定义分类标识与名称。按维护约定，每个 `skills[]` 条目必填一个 `category`，取下表标识，不设默认分类；新增技能或调整归属时，同步本节与分类元数据。分类用于导航与维护，沿用现有加载、同步和打包方式。

| 分类 | category 标识 | 范围 |
|---|---|---|
| [Go](#go) | `go` | 任务路由、架构判断、现代写法、专项模式、审查与质量门禁 |
| [PHP 与 Laravel](#php-与-laravel) | `php` | PHP 语法、Laravel 运行时与交付质量 |
| [前端与设计](#前端与设计) | `frontend` | Vue、跨框架前端工程、界面设计与前端验收 |
| [OpenResty 与 Lua](#openresty-与-lua) | `openresty-lua` | ngx_lua、网关运行操作与纯 Lua/LuaJIT |
| [其他语言](#其他语言) | `other-languages` | Python、Node.js 服务端与 Rust |
| [通用工程](#通用工程) | `general` | 方案评审、代码简化、后端验收、Shell 与运维 |
| [跨栈工程](#跨栈工程) | `cross-stack` | API 契约、发布、事故响应、可观测性、安全、测试、升级、性能与异步任务 |
| [流程工具](#流程工具) | `workflow` | 基于文件的任务规划与进度记录 |

### Go

| skill | 内容 |
|---|---|
| `go-task-router` | Go 跨专题或入口不明确的任务分流：按解释、实现、审查、排障、性能与方案选择最小技能组合；不新增阶段或自动启动门禁 |
| `senior-go-engineer` | Go 服务从需求到上线的决策框架：6 个必问数字、单体/模块化单体/微服务判定、分层与包设计、泛型边界、存储与缓存与 MQ 选型、分布式事务替代顺序、稳定性 4 问、容量与副本数 |
| `use-modern-go` | 现代 Go 写法的单一真源：Go 1.0–1.27 每个"旧写法 → 现代写法"条目标注版本并经 `go doc` 核实；其他 Go skill 只引用它 |
| `go-review` | Go 代码审查：输入域枚举与调用方回审 → 七维度审查 → 置信度过滤 → 输出格式；生态库（GORM/Gin/go-redis/gobreaker/gorilla）已知陷阱 |
| `go-enterprise-quality` | 写/改 Go 代码时的门禁流程：build / vet / lint / govulncheck / `-race` 测试、调用方影响分析、契约声明必配反证测试 |
| `go-gin-api` | Gin 服务骨架：`http.Server` 超时、优雅关闭、请求体限制、DTO 校验、JWT、CORS、幂等接口、`/livez` `/readyz`、handler 内异步的正确姿势 |
| `go-cobra` | Cobra 命令树、参数与 flags、父子 hook、context、错误/输出、补全与命令测试；不默认搭配 Viper |
| `go-viper` | Viper 来源优先级、flag/env 绑定、结构体解码、配置校验、重载与实例隔离；评估请求不自动引入依赖 |
| `go-lo` | samber/lo 集合、查找、条件与指针工具的 nil、顺序、重复 key、别名、错误与子包边界；不批量替换循环 |
| `go-error-handling` | `AppError`（`Error/Unwrap/Is`）、错误码分段、可重试分类、ctx 取消映射 499/504、跨服务错误映射、panic 边界、wrap 边界 |
| `go-context` | context 的传播、deadline、取消原因、请求级 value、后台任务与有界收尾；区分普通请求、必要收尾和可靠异步任务 |
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
| `go-engineering-governance` | `.golangci.yml`（v2）、CI 门禁流水线、依赖治理、`apidiff` 与兼容性、按项目版本政策阻断破坏性发布、PGO 流程、项目布局 |

### PHP 与 Laravel

| skill | 内容 |
|---|---|
| `senior-php-engineer` | PHP/Laravel 工程判断：PHP-FPM/OPcache/Octane 运行时、队列与事务锁、Eloquent 性能、安全、慢请求与超卖排查 |
| `use-modern-php` | PHP 8.0–8.5 语法与运行时特性，附实测报错原文 |
| `php-enterprise-quality` | PHP/Laravel 的 PHPUnit/Pest、PHPStan/Psalm、Pint、Composer、迁移、队列和 CI 质量门禁。 |

### 前端与设计

| skill | 内容 |
|---|---|
| `senior-frontend-engineer` | 跨框架前端工程判断：Core Web Vitals、React/Vue 渲染与水合、现代 CSS、Vite 构建与包体、安全和可访问性；Node 服务端由对应技能负责 |
| `vue-frontend-engineer` | Vue 3 + JavaScript/TypeScript 的生产开发工作流：组件、路由、状态、API 适配、异步竞态、令牌刷新、表单、测试、安全、性能与可访问性；不替代前端验收 |
| `frontend-acceptance` | 前端项目证据化验收：需求追踪、浏览器行为、API 契约、权限/租户、数据一致性、安全、性能、可访问性和准入报告；构建/截图不等于通过 |

#### 第三方设计技能

以下目录保留上游固定提交的原始内容、许可证及已有作者声明；本仓库新增的 `UPSTREAM.md` 记录来源、提交、导入日期和本地包装差异，不改写上游 `SKILL.md` 或调用策略。

| skill | 用途 | 许可证与来源 |
|---|---|---|
| `frontend-design` | 根据产品和受众确定视觉方向、字体、配色与布局 | Apache-2.0；[来源与提交](frontend-design/UPSTREAM.md) |
| `anti-ui-slop` | 产品界面、打磨、设计审查与视觉检查 | Apache-2.0；iOS 衍生材料另含 MIT 声明；[来源与提交](anti-ui-slop/UPSTREAM.md) |
| `high-end-visual-design` | 明确选择玻璃质感、大留白、柔和阴影与动效的视觉风格 | MIT；[来源与提交](high-end-visual-design/UPSTREAM.md) |

`high-end-visual-design` 保留上游显式调用策略，使用 `$high-end-visual-design` 指定。三个技能沿用现有单向同步：先维护本仓库，再执行 `./sync.sh frontend-design anti-ui-slop high-end-visual-design` 安装到 `~/.agents/skills`。上游更新应按明确提交重新导入，并同步更新来源记录；不从安装副本反向覆盖上游记录。

为保持原文，`frontend-design` 和 `anti-ui-slop` 的描述保留超过本仓库 150 字符约定的上游长度。现有 `scripts/validate.ps1` 没有第三方豁免，按其当前规则这两项会报描述长度错误；该差异不代表已通过全仓校验。

### OpenResty 与 Lua

| skill | 内容 |
|---|---|
| `senior-openresty-engineer` | OpenResty/ngx_lua 工程决策：阶段与 API 边界、timer/worker 模型、出站方式、shared dict、balancer 重试、超时、连接池与热更新 |
| `openresty-patterns` | ngx_lua 各阶段 API 可用性、shared dict 真实行为、三级缓存与击穿防护、cosocket 连接池、`ngx.re`、cjson、timer、阻塞排查——全部本机实测 |
| `openresty-gateway-operations` | OpenResty/Nginx 配置检查、upstream、超时、缓存、限流、长连接、证书、reload、流量切换和回滚。 |
| `senior-lua-engineer` | 纯 Lua/LuaJIT 工程判断：版本语义差异、table 边界、整数浮点、GC、FFI、沙箱和 Redis EVAL；Nginx 内 Lua 按 OpenResty 技能处理 |

### 其他语言

| skill | 内容 |
|---|---|
| `senior-python-engineer` | Python 工程判断：GIL 与 free-threading、asyncio、FastAPI/Django、SQLAlchemy async、打包分发、类型、lint 与安全 |
| `senior-nodejs-engineer` | Node.js 服务端工程判断：进程生命周期、ESM/CJS、事件循环与内存、Fastify/Express/NestJS、流与背压、事务和 npm 发包安全 |
| `senior-rust-engineer` | Rust 工程判断：所有权与生命周期、async/tokio 取消安全、内存序、错误边界、2024 edition、unsafe、Axum/sqlx 与 cargo 治理 |

### 通用工程

| skill | 内容 |
|---|---|
| `tech-design-review` | 技术方案文档模板（含非目标、候选方案对比、失败模式、上线与回滚）、ADR 模板、容量估算公式、评审清单与否决项；语言无关 |
| `code-simplifier` | 代码简化：行为等价性验证步骤、性能特征变化提醒、不动的边界（并发、金融精度、错误路径、安全校验） |
| `backend-acceptance` | Go/PHP/Node.js 等后端的生产风险审计：业务规则来源、调用链、不变量、事务、幂等、并发、权限、安全、索引、容量、失败补偿与证据门禁 |
| `shell-scripting` | Bash 脚本骨架、`set -e` 失效点、引用与数组、trap 与信号、getopts、锁与超时、macOS/BSD 与 GNU 差异、bash 3.2 兼容 |
| `senior-devops-engineer` | 运维/SRE 工程判断：Linux 内核参数、容器与 cgroup、Kubernetes、发布策略、Prometheus 告警、SLO、事故复盘与云成本 |

### 跨栈工程

| skill | 内容 |
|---|---|
| `cross-stack-api-contract` | Go/PHP、gRPC/gateway 与客户端的契约、proto-first/OpenAPI/JSON Schema、错误、分页、鉴权、兼容性和生成测试；不替代实现或最终验收。 |
| `polyglot-release-engineering` | Go、PHP-FPM/Octane、前端资产和 OpenResty 的统一发布、数据库 expand/contract、灰度、缓存、健康检查和回滚。 |
| `incident-response` | 浏览器、网关、PHP-FPM、Go、Redis、数据库的事故分级、止损、证据链、回滚、降级和复盘。 |
| `cross-stack-observability` | OpenResty、PHP、Go、浏览器间的 request ID、trace context、日志字段、脱敏、指标、采样和告警验证。 |
| `polyglot-security-supply-chain` | Go/PHP/npm 依赖、CVE、SBOM、secret、SAST/DAST、镜像和许可证治理。 |
| `polyglot-test-engineering` | 跨栈测试层次、契约/集成/E2E/故障注入、测试数据、flaky 管理和证据要求。 |
| `runtime-upgrade-migration` | Go、PHP/Laravel、Vue/Node、OpenResty 的版本升级、兼容矩阵、分阶段迁移和回滚。 |
| `fullstack-performance` | 浏览器到网关、PHP/Go、Redis、数据库和 MQ 的性能预算、基线、压测、定位和容量评估。 |
| `async-job-contracts` | Laravel Queue、Go MQ 和跨语言事件的 schema 版本、投递语义、幂等、重试、DLQ、顺序和回放。 |

### 流程工具

| skill | 内容 |
|---|---|
| `planning-with-files` / `planning-with-files-web` | 基于文件的任务规划（task_plan / findings / progress）；在 git 仓库内使用时把三个文件写入 `.git/info/exclude` |

## 与 harness-engineering / openspec-auto 的分工

- 本仓库负责**通用工程知识**：语言写法、框架用法、并发、数据、稳定性、安全、测试、性能。同一主题只在这里写全，`.harness/guides/` 不再复制一份。
- [harness-engineering](../harness-engineering) 负责**项目约定**：技术栈选型（gtkit 系列）、分层与依赖方向、DTO 与错误码、支付与迁移流程、门禁命令、错误记忆；其 guide 涉及通用知识时指向本仓库对应 skill。
- [openspec-auto-bootstrap](../openspec-auto-bootstrap) 负责**流程**：什么请求要先出 proposal / spec / tasks，改代码前后的守门与收口。
- 三者装进同一个项目互不覆盖：通用 skill 默认走 `~/.agents/skills`；harness 与 openspec-auto 的项目工作流 skill 走项目 `.agents/skills`，其余项目产物按各自安装器写入并由 `.git/info/exclude` 忽略。

## 组合方式

- Go 任务入口或跨专题组合不明确时先走 `go-task-router`；已明确单一专项的直接进入专项，不预读整库。实际编写或审查 Go 代码按 `use-modern-go` 核对版本；交付前验证走 `go-enterprise-quality`（按影响面分级；纯文档不触发，源码日志/错误文本修改才跑 build/vet）；审查走 `go-review`；架构与选型问题走 `senior-go-engineer`，方案文档走 `tech-design-review`。
- context 传播、取消、请求脱离与收尾边界统一走 `go-context`；goroutine 调度走 `go-concurrency`，deadline 传播实现走 `go-microservice`，预算数值走 `go-stability-engineering`。调用方定位由 `go-review/references/code-navigation.md` 提供共享指导，语义工具和文本搜索都须说明覆盖范围。
- Cobra 命令行任务直接走 `go-cobra`，只有涉及 Viper 配置绑定/解析时追加 `go-viper`；Viper 可独立用于服务配置。使用或审查 samber/lo 时选 `go-lo`，不因普通 Go 实现任务加载这三项或自动引入依赖。
- 前端开发走 `vue-frontend-engineer`（Vue 3 项目）或 `senior-frontend-engineer`（跨框架判断）；交付验收再走 `frontend-acceptance`。前端发现授权、事务、幂等或数据一致性问题时，升级到 `backend-acceptance`。
- 后端交付验收优先走 `backend-acceptance`，再按语言和风险路由到 `go-review`、`go-enterprise-quality`、`go-testing`、`go-data-consistency`、`go-security`、`go-database-patterns`、`go-stability-engineering`、`go-microservice` 或对应的 `senior-*` skill。
- Go/PHP/前端/OpenResty 的接口联调先走 `cross-stack-api-contract`；发布顺序、迁移、灰度或回滚走 `polyglot-release-engineering`；PHP 代码交付门禁走 `php-enterprise-quality`。
- 生产故障先走 `incident-response`；跨语言链路字段和告警走 `cross-stack-observability`；OpenResty 配置与流量操作走 `openresty-gateway-operations`。
- 跨语言依赖、密钥和镜像治理走 `polyglot-security-supply-chain`；测试层次和故障注入设计走 `polyglot-test-engineering`；版本升级走 `runtime-upgrade-migration`；跨层性能排查走 `fullstack-performance`；事件/任务契约走 `async-job-contracts`。
- 主题归属只有一处实现，其他 skill 引用而不重复：日志/metrics/tracing 在 `go-observability`；限流/熔断/重试/超时预算在 `go-stability-engineering`；缓存一致性在 `go-cache-consistency`；事务与分布式事务在 `go-data-consistency`；错误类型与错误码在 `go-error-handling`。

## 重复与近似职责审查

- `senior-frontend-engineer` 与 `vue-frontend-engineer` 不合并：前者是跨框架判断与参考，后者是 Vue 3/JS/TS 实现工作流。
- `go-review`、`go-enterprise-quality` 与 `backend-acceptance` 不合并：前两者是 Go 专项审查/门禁，后者跨 Go/PHP/Node.js 编排业务和生产证据。
- `go-microservice` 已覆盖 Go 微服务实现细节，保留为专项；`backend-acceptance` 只负责识别微服务验收风险并路由过去。
- `planning-with-files` 与 `planning-with-files-web` 的行为相似但运行环境不同，保留两份并在描述中区分使用环境。
- `openresty-patterns` 与 `senior-openresty-engineer` 分别承担可运行模式参考和架构判断，保留边界，不重复新增。
- `cross-stack-api-contract` 负责契约和兼容性，`frontend-acceptance`/`backend-acceptance` 负责发布准入；`polyglot-test-engineering` 负责测试策略，不替代两者的验收结论。
- `polyglot-release-engineering` 负责跨栈发布编排，`senior-devops-engineer` 负责基础设施判断，`go-engineering-governance` 负责 Go 包和版本发布纪律。
- `cross-stack-observability` 负责跨语言关联和证据，`go-observability` 负责 Go 的具体实现；`openresty-gateway-operations` 负责运行操作，OpenResty 两个现有 skill 负责 Lua/API 和架构。
- `php-enterprise-quality` 负责 PHP 交付门禁，`senior-php-engineer` 负责运行时和 Laravel 判断；`polyglot-security-supply-chain` 负责供应链，语言安全实现仍路由到对应安全 skill。
- `go-task-router` 只选择入口，不替代专项或强制加载所有技能；`go-context` 统一取消契约，不重复并发调度、预算计算或协议实现。语义导航先作为 `go-review` 的共享参考，暂不另建工具技能。

## 文件布局与描述规范

- `description` 只写"做什么 + 什么时候用"，本仓库约定每条不超过 150 个字符；这是可维护性门槛，不把它当成未经核实的平台硬限制。触发词长尾与分工说明放正文。
- 内容多的 skill 拆成"路由 + references/"：`SKILL.md` 只放核心规则、判断表、审查清单与"按任务读取"路由表，代码模板与逐版本速查放 `references/*.md`，按路由表只读本次任务需要的文件。超过 250 行时优先评估拆分收益；只有实际按需加载能减少无关上下文才拆，不机械按行数拆分。
- 同一条规则只在一处写全：审查四条（枚举输入域、回审调用方、契约反证、整段重读）完整版在 `go-review` 与 `go-enterprise-quality`，其他 skill 一句话引用。

## 通用原则与团队默认

- 本仓库默认目标 Go 1.27；实际项目先读 `go.mod` 与工具链政策，按项目声明版本使用 `use-modern-go`，不自动升级。
- 本仓库团队默认与示例采用 `github.com/gtkit/logger/v2`（包级 `*Ctx` 函数、zap 字段）及 `go-error-handling` 的 AppError 模型。目标项目已有日志、错误码、响应结构和依赖装配时沿用它们；技能示例不授权迁移日志库、错误模型、目录或依赖方向。
- `http.Server` 显式设置全部超时字段；`/livez` 不带依赖检查，`/readyz` 才带。
- 哨兵错误用 `errors.Is`；5xx 不回显内部错误；金额用 `int64`（最小货币单位）或 decimal。
- 新增或修改 Go 代码块要说明最低适用版本及证据状态。当前仅授权文档/skill 维护时只编辑并回读，未执行的编译、vet 与运行保持未验证；后续获准验证时记录独立模块、Go 版本、命令、退出码及结果。带“实测”标注的断言必须有对应复现记录，旧记录不能证明新片段已通过。

## 脚本

| 脚本 | 用途 |
|---|---|
| `pack.sh [name...]` | 打包为 `_dist/<name>.skill`（zip），排除 `.DS_Store` |
| `sync.sh [name...]` | 用 rsync 校验并镜像到 `~/.agents/skills`；备份旧内容，成功后迁移旧 Codex 同名副本；其他 skill 保持不动 |
| `sync.ps1 [name...]` | 同上，Windows 原生 PowerShell 版，用 robocopy /MIR；默认目标为 `%USERPROFILE%\.agents\skills` |
| `scripts/test-sync.sh` | 在临时目录验证同步、备份、选择同步、链接和非法目标保护，不改真实用户安装目录 |
| `scripts/validate.ps1` | 校验 frontmatter、目录名、相对引用、描述长度、文件长度和 `catalog.yaml` 覆盖范围 |
| `scripts/test-validate.ps1` | 有效输入和缺字段、坏引用、catalog 漂移等错误分支回归；读取层注入，无需修改真实 skill 或创建项目副本 |
| `scripts/check-harness-dependencies.ps1 [-HarnessRoot path]` | 核对相邻 harness-doctor 依赖清单中的技术 skill 源文件，缺失时失败；不证明安装或运行 |

## 同步到 Codex

在本仓库运行：

```bash
./sync.sh                         # 全量同步；仓库更新后再次执行
./sync.sh go-review go-testing    # 只更新并迁移指定 skill
```

Windows 原生 PowerShell 对应 `./sync.ps1` 和 `./sync.ps1 go-review go-testing`。

- `TARGETS` 控制实际同步位置，未设置或留空时只同步 `~/.agents/skills`，目录不存在会创建。Shell 版用空格分隔绝对路径，因此自定义路径不能含空格；PowerShell 版用分号分隔，可包含空格。默认目录本身支持带空格的用户路径。
- `CODEX_HOME` 用于定位旧的 `skills` 和备份目录；必须是绝对路径，未设置或留空时回落 `~/.codex`。例如 Shell 可用 `CODEX_HOME=/path/to/codex ./sync.sh`，PowerShell 可用 `$env:CODEX_HOME = 'C:\Codex'; ./sync.ps1`。它不改变默认同步目标 `~/.agents/skills`。
- 默认不写入或创建 Claude 的 skills 目录。自定义目标示例：`TARGETS="/tmp/skills-a /tmp/skills-b" ./sync.sh`；PowerShell 对应 `$env:TARGETS = 'C:\skills-a;D:\skills-b'; ./sync.ps1`。自定义目录还需由实际运行时发现，脚本不会替你配置运行时。
- 已有的同名目标在覆盖前整目录备份到 `$CODEX_HOME/skill-sync-backups/<唯一批次>/target-<序号>/<name>`。默认使用 `~/.codex/skill-sync-backups`，位于技能扫描目录之外；目标中的旧链接只移动链接本身，避免镜像更新修改链接指向的目录。`.DS_Store` 不同步。
- 全部目标同步并校验成功，且其中包含默认 `~/.agents/skills` 时，才把旧 `$CODEX_HOME/skills/<name>` 移到同批次的 `legacy/<name>`。只迁移本次选中的仓库 skill，不动 `.system`、插件或其他第三方 skill；旧 Codex skills 目录不能再作为同步目标。恢复时可从备份复制对应 skill 到 `~/.agents/skills/<name>`。
- Codex 先发现 skill 的名称和描述，按任务匹配后才加载正文。若当前列表仍显示旧路径或重复项，重启 Codex 并开启新会话。同步成功证明安装内容已更新，不能代替真实任务中的自动触发与执行证据。[官方说明](https://learn.chatgpt.com/docs/build-skills)
- harness 的技术 skill 路由会解析到这份用户级安装；同步不会改写任何业务项目的 `AGENTS.md` 或 `.harness/guides`，已有项目模板的更新仍由 harness 安装器负责。

## 维护入口

- `AGENTS.md` 只记录修改分级、必读文件、校验命令和发布边界，不承载领域知识或动态状态。
- `catalog.yaml` 记录 `categories` 分类定义、各 skill 的 `category` 主分类、状态、适用平台、references 和 Codex UI 元数据；技能正文与触发描述以各目录的 `SKILL.md` 为内容源，分类元数据在 catalog 中维护并与本页导航一致。`active` 表示内容源启用，不等于已安装、自动发现已通过或稳定发布。
- `evals/routing.md` 记录应触发、不应触发和边界场景；场景推演不等同于真实模型评测。
- harness 的阶段依赖见 `harness-engineering/skills/harness-doctor/references/skill-dependencies.md`（位于相邻仓库）；doctor 区分文件存在、运行时可发现与本次已执行。安装状态不能代替门禁结果。
- 维护按当前请求与全局规则确定边界：纯文档/skill 说明只编辑并回读，不自动运行脚本或评估。获准质量验证时使用 `pwsh -File scripts/validate.ps1`；路由、授权与跨 skill 语义的代表场景及自然语言评估方法见 `evals/routing.md`，未运行部分保持未验证。

## 维护规则

- 单文件 ≤ 400 行；示例只保留说明问题所必需的部分。
- 每条规则可证伪；版本相关事实标注版本；未核实的断言不写。
- 代码示例的编译与运行证据按上文记录；纯说明维护不启动额外验证，也不把回读写成测试通过。
- 引用其他 skill 只用真实目录名。
