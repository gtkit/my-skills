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
