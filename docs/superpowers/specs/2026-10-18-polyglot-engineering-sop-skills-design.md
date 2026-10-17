# Polyglot Engineering SOP Skills Design

## Goal

为 Go + PHP + 前端 + OpenResty 开发者补齐跨语言协作和生产交付 SOP，避免继续把已有 Go、Vue、OpenResty 专项知识重复拆分。

## Scope

新增 11 个通用 skill，按三批交付：

- P0：`cross-stack-api-contract`、`polyglot-release-engineering`、`php-enterprise-quality`、`incident-response`
- P1：`cross-stack-observability`、`openresty-gateway-operations`、`polyglot-security-supply-chain`、`polyglot-test-engineering`
- P2：`runtime-upgrade-migration`、`fullstack-performance`、`async-job-contracts`

每个 skill 负责一个可复用 SOP，包含触发条件、输入与前置事实、执行顺序、失败/回滚路径、证据要求、完成条件和不触发边界。

## Boundaries

- 现有 Go 专项继续负责 Go 内部实现；新 skill 只做跨栈编排或明确缺失的 PHP/发布流程。
- `frontend-acceptance` 继续负责前端发布验收；`polyglot-test-engineering` 负责测试策略和测试层次选择，遇到准入结论时路由到验收 skill。
- `openresty-patterns` 和 `senior-openresty-engineer` 继续负责 Lua/API 和架构判断；新 skill 负责网关配置发布、流量和运行操作。
- 项目专属命令、目录、gtkit 约定不写入通用 skill，留给项目 harness。
- 不把静态推演写成真实触发率或完成率。

## Shared operating model

所有新 skill 使用相同的 SOP 骨架：

1. 锁定范围、版本、环境和授权目标。
2. 收集契约、配置、依赖、指标或需求来源。
3. 建立不变量、失败模式和回滚点。
4. 执行最小可证伪检查，记录命令、版本、输出和未验证项。
5. 输出结论、阻断项、风险接受条件和下一步。

## Validation

- `scripts/validate.ps1` 校验 frontmatter、描述长度、引用和 catalog 覆盖。
- `evals/routing.md` 新增每个 skill 的代表场景和负向边界。
- 由于本次没有配置可运行的目标项目、真实浏览器、生产环境或模型评测平台，只做结构检查和静态路由推演；真实触发率、耗时、上下文用量保持未验证。
