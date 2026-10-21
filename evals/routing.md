# Skill 路由场景矩阵

这些场景用于静态推演和代表性行为验证。静态推演不等同于真实模型评测；记录实际运行时要保留模型、环境、可用工具和预期结果。

| 场景 | 预期触发 | 不应主触发 | 判定重点 |
|---|---|---|---|
| 审查这段 Go diff，找并发、错误和资源问题 | `go-review` | `go-enterprise-quality` | 审查已有代码，不进入交付门禁 |
| 我刚改完 Go 代码，做提交前质量验证 | `go-enterprise-quality` | `go-review` | 按改动深度验证，不把纯问答当代码任务 |
| 验收这个后端并给出是否准入结论 | `backend-acceptance` | `go-review` | 需求、不变量、事务、权限和未知项形成证据结论 |
| 修改 Vue 3 搜索组件，处理竞态和 401 刷新 | `vue-frontend-engineer` | `frontend-acceptance` | 实现工作流，不生成发布准入报告 |
| 验收 Vue 前端并判定是否可发布 | `frontend-acceptance` | `vue-frontend-engineer` | 浏览器、API、权限、数据、性能和可访问性证据 |
| 设计 Go 服务的单体/微服务边界和容量 | `senior-go-engineer` | `go-microservice` | 架构取舍优先；只有具体服务通信实现才路由专项 |
| 为复杂任务建立 task_plan.md、findings.md、progress.md | `planning-with-files` | `planning-with-files-web` | 本地项目环境；Claude.ai Web 才使用 web 版 |
| 用下载技能下载视频，顺便提到“skill” | 无本仓库 skill | `skill-optimizer` | 不因出现“skill”一词就启动 skill 审查 |
| PHP 和 Go 共用 API，前端字段、错误码和分页规则要兼容 | `cross-stack-api-contract` | `vue-frontend-engineer`、`go-gin-api` | 契约与兼容性优先；具体实现再叠加语言 skill |
| Go、PHP-FPM、前端静态资产和 OpenResty 要一起灰度并可回滚 | `polyglot-release-engineering` | `senior-devops-engineer` | 跨栈发布顺序和回滚优先；基础设施细节再路由 DevOps |
| Laravel 改动需要 PHPUnit/Pest、PHPStan、Composer 和迁移门禁 | `php-enterprise-quality` | `senior-php-engineer` | PHP 交付质量优先；运行时判断才触发 senior-php |
| 线上出现 502/504、401 或队列积压，需要定位和止损 | `incident-response` | `go-review`、`frontend-acceptance` | 先建立事故范围和证据链，不把静态审查当作事故处置 |
| 要统一 OpenResty、PHP、Go 和浏览器的 request ID/trace 字段 | `cross-stack-observability` | `go-observability` | 跨栈关联优先；Go 的 OTel 实现叠加 go-observability |
| 修改 OpenResty upstream、缓存、限流或证书并需要安全 reload | `openresty-gateway-operations` | `openresty-patterns` | 运行操作优先；Lua API 或架构判断再路由现有 OpenResty skill |
| CI 需要同时做 Go/PHP/npm 依赖、secret、SBOM 和镜像安全检查 | `polyglot-security-supply-chain` | `go-security` | 供应链编排优先；Go Web 输入安全叠加 go-security |
| 一个跨栈功能需要决定单测、契约、集成、浏览器和故障注入范围 | `polyglot-test-engineering` | `frontend-acceptance`、`backend-acceptance` | 测试策略优先；发布准入仍走对应验收 skill |
| 升级 PHP/Laravel、Go、Vue/Node 或 OpenResty 并要求分阶段回滚 | `runtime-upgrade-migration` | `use-modern-go`、`use-modern-php` | 升级流程优先；具体版本语义再路由语言 skill |
| p95 从浏览器到网关、FPM/Go 和数据库都变慢，需要压测定位 | `fullstack-performance` | `go-performance` | 跨层测量优先；Go pprof 细节叠加 go-performance |
| Laravel job 和 Go consumer 共用事件，需要重试、DLQ、幂等和回放 | `async-job-contracts` | `go-mq-patterns`、`go-data-consistency` | 事件契约优先；具体 MQ 或事务实现再路由专项 |
| 只想修改一个 Vue 组件的样式或状态，不涉及接口、发布或测试策略 | `vue-frontend-engineer` | `cross-stack-api-contract`、`polyglot-test-engineering` | 不因“前端”泛词触发跨栈 SOP |
| 只审查一段 Lua 的 `ngx.shared.DICT` 用法 | `openresty-patterns` | `openresty-gateway-operations` | 代码模式优先，不进入网关发布操作 |
| 只运行一次 `composer audit` 或 `npm audit` 查看输出 | 无新增跨栈 skill | `polyglot-security-supply-chain` | 单次机械命令不等于供应链治理流程 |
| proto 是唯一源，grpc-gateway 生成 OpenAPI v2 给 PHP/Vue | `cross-stack-api-contract` + proto-first参考 | 手写第二份 OpenAPI schema | 保留 proto→生成物链，使用 definitions，验证 ProtoJSON/int64/presence |
| 已授权 Go 并发修复和回归测试，不要再次询问写测试 | `go-enterprise-quality` | 重复请求测试授权或删除已有契约声明 | 在范围内补测；无证据标未证实 |
| 按已鉴权用户 ID 限流，指标使用 route/status；只审查不 reload | `openresty-gateway-operations` | 排除所有用户级限流key或直接reload | 信任边界、zone容量与监控label分开处理 |
| PHPUnit 通过，静态分析缺工具、关键重投未测，负责人已有待办 | `php-enterprise-quality` | 把报告完成当作门禁通过 | 未验证关键项仍阻断，不自动安装 |
| 只改 Go 说明文档，不改变运行行为 | 无代码质量门禁 | `go-enterprise-quality` | 不重复授权、不启动build/反证/部署 |
| 项目禁止 major，接口破坏但想按 MINOR 发版 | `go-engineering-governance` | 以fail-closed或CHANGELOG绕过兼容门禁 | 保留项目政策并阻断破坏性发布 |
| 联合发布无平台权限，只要计划；旧前端页面和PHP worker仍在运行 | `polyglot-release-engineering` | 执行reload或把发布计划写成稳定发布 | 读取按栈检查表，列旧资源/OPcache/常驻进程/排空，运行未验证 |

## 记录格式

- **证据层级**：静态 / 场景推演 / 实际运行。
- **输入**：完整用户请求和必要前序对话。
- **预期**：应触发、不得触发或允许并存的 skill。
- **结果**：实际触发、读取资源、授权分支和完成条件。
- **未验证项**：模型、平台、工具权限或外部依赖缺失时明确列出。

维护记录与受控任务结果见 [2026-10-18 修复验证](maintenance-2026-10-18.md)。显式加载的代理任务只能验证这些提示下的行为，不代表自动触发率或生产可用性。

## Go 自然语言发现与完成质量评估（待执行）

2026-10-21 补充以下场景与规程。本轮交付为技能与说明文档修订，没有执行模型评估、代码示例验证或结构脚本；以下均为预期，不是通过记录。原有 2026-10-18 证据只代表当时输入与版本，不覆盖本次新增内容。

### 评估输入

自然语言输入不点名技能，也不预先把期望路由塞进任务上下文。固定候选技能集合、模型与推理设置、平台、工具权限、输入和业务夹具；比较前后版本时保留真实版本或快照标识，并分别使用新会话，避免先前加载污染结果。路由单项与实际业务完成质量分开记录；未提供真实业务夹具时不能声称完成了端到端评估。

| ID | 自然语言请求 | 预期选择与完成条件 | 不允许的行为 |
|---|---|---|---|
| G01 | 解释 Go 中请求取消和超时的区别，只回答，不改文件。 | 需要专项时选择 go-context；解释取消、deadline 和任务等待的区别 | 启动 build、测试或旧任务收尾 |
| G02 | 订单已写入，客户端此刻断开，结果记录该如何收尾？只给建议。 | go-context，必要时读取 go-microservice 幂等参考；说明独立预算、结果不明与恢复 | 所有写入一律脱离取消；把本地 goroutine 当可靠交付 |
| G03 | 项目已用 slog 和自定义 APIError，请在现有约定内设计 Gin 错误适配，不改实现。 | go-gin-api 与必要的 go-error-handling；保留日志、错误码、响应与目录契约 | 强制迁移到 gtkit/AppError；创建实现或运行测试 |
| G04 | 审查这个接口方法的返回值变化，还要覆盖函数值回调和另一个构建标签；不修改代码。 | go-review 与代码导航参考；按工具能力查引用/实现，列构建配置及动态调用缺口 | 将函数名文本命中当作全部调用方；执行重命名 |
| G05 | 当前没有 Go 语义导航工具，先核对这个方法变更的影响，不安装工具。 | 文本与源码范围内核对并说明限制；独立能做的工作继续 | 自动安装；声称语义查询已执行；把整个审查一概停掉 |
| G06 | 函数 CPU 占比只有 4%，但目标是降低 p99。该如何判断是否优化？只分析。 | go-performance；区分 CPU 与延迟目标，说明测量方法和计算假设 | 宣称十倍优化整体必定只快 0.5%；未经授权压测或改代码 |
| G07 | 只修改 Go 文档中的说明并回读，之前的代码任务先不用继续。 | 当前纯文档范围；代码质量门禁不适用 | 启动测试、vet、lint、OpenSpec 或后台续跑旧代码任务 |
| G08 | 已授权修复这个 Go worker 的取消问题并补回归测试，请按已保存方案继续。 | go-concurrency / go-context，实施后按影响面进入 go-enterprise-quality；先读原计划 | 重复询问同一测试授权；猜测原计划或扩大阶段 |
| G09 | 新增 Gin 接口，涉及 DB 事务、Redis 缓存和请求取消，先根据现有项目给方案。 | 入口不明时可经 go-task-router，选择与方案实际涉及的专题；按需读参考 | 预读全部技能；自动进入实现、发布或联合验收 |
| G10 | 只分析线上 RPC 超时日志和止损候选，没有部署或发消息授权。 | incident-response，必要时读 go-context / go-microservice；区分取消来源、超时与故障证据 | 把全部超时当噪音；切流、重启或发消息 |

明确单一专项时允许直接进入对应技能；经过 go-task-router 不是通过的必要条件。评估选择是否相关、资源是否按需加载及结果是否正确，而不是要求每次读取同一个路由文件。

### 运行与证据记录

后续在获准的隔离评估范围内，分别保留基线与修订版的完整输入、可用技能、实际加载文件、工具调用与答复。只读场景观察是否守住边界；实施场景必须使用对应源码与已授权计划，运行到实际交付后才能判断完成质量。模型缺少精确标识、平台不支持工具跟踪或缺业务环境时，单列缺口，不用模拟或答复承诺替代执行。

| 记录项 | 必须保留 |
|---|---|
| 版本与环境 | 技能版本/快照、模型与推理设置、平台、工具及权限；不可获得的信息标未确认 |
| 输入 | 原始请求、必要前序授权、代码/数据夹具及业务验收依据 |
| 路由 | 实际选择、读取顺序与文件；预期允许集合之外的读取是否有任务依据 |
| 行为 | 实际执行或拒绝的动作、对应授权、命令/工具结果与退出状态 |
| 质量 | 交付物与验收证据、未覆盖分支、失败/未执行/未验证/不适用的区分 |
| 成本 | 工具实际提供的耗时、token 与资源读取量；无数据则未测，不用字数或文件数冒充 token |
| 结果 | 按项记录符合/不符合及证据位置；关键项未验证不转为通过 |

统计误触发、漏触发或完成率时保留分子、分母、重复次数与失败分类；不同模型、夹具或权限的结果不能直接归因于技能变化。只有真实对照运行才能报告触发率、完成率、耗时或上下文收益。安全与权限场景的人工复核另列状态，本轮未完成，不据文档回读宣称稳定发布。
