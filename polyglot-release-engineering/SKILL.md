---
name: polyglot-release-engineering
description: "Use when Go, PHP, frontend assets, and OpenResty must be released, migrated, canaried, or rolled back together."
---

# 跨语言发布工程

## 适用场景

当 Go binary、PHP-FPM/Octane、前端静态资产和 OpenResty 配置需要同一发布窗口协同变更时使用，覆盖构建产物、配置、数据库 expand/contract、发布顺序、灰度、health/readiness、缓存和回滚。它编排发布证据，不替代 `senior-devops-engineer` 的基础设施判断、`go-microservice` 的 Go 生命周期实现或 OpenResty 具体配置操作。

## 输入与前置事实

收集发布 commit/tag、组件版本矩阵、构建脚本与锁文件、镜像或归档摘要、配置来源、数据库迁移、缓存键/失效策略、健康检查、监控指标、灰度入口、回滚版本和授权人。确认生产写入权限；没有明确授权时只做只读检查和发布计划。

业务兼容性、迁移可逆性、阈值和等待时间必须来自需求、契约、历史基线或批准的发布方案。缺少数据时写“假设/待批准”，不自行发明阈值。

## 按顺序执行

1. **锁定版本与产物**：固定 commit、Go/PHP/Node/OpenResty 版本、依赖 lockfile 和构建参数。生成 Go binary、PHP 依赖归档或镜像、前端静态资产、OpenResty 配置包，记录 SHA-256、来源和可复现命令。
2. **审查配置**：列出环境变量、secret 引用、feature flag、上游地址、超时和证书引用。验证模板渲染、必需项、敏感值来源和旧配置回退；禁止把凭证写进日志或产物。
3. **设计数据库 expand/contract**：先增加可兼容的列/索引/表或双写路径，再部署能读旧新形态的应用，观察回填和一致性证据，最后在无旧消费者后清理旧结构。每一步声明锁表风险、回滚条件和不可逆动作；具体迁移语义以项目数据库工具和批准方案为准。
4. **确定顺序**：通常先部署兼容后端与迁移，再切换前端资产和网关；若项目契约要求其他顺序，写出原因和验证点。每步列出 health/readiness、日志、错误率和依赖检查。
5. **预演与门禁**：在与生产拓扑相近的环境执行构建、启动、迁移、静态资产加载、OpenResty 配置检查和关键请求；记录命令、版本、响应和未验证项。健康检查的依赖范围以服务定义为准，不能把 `/livez` 或 `/readyz` 的含义擅自改写。
6. **灰度**：选择有代表性的流量/租户/实例集合，先验证路由、鉴权、契约、错误率、延迟、资源和缓存命中；扩大范围前保存每个阶段的观测窗口和批准记录。发现回滚条件时停止扩大流量。
7. **缓存处理**：列出受影响的 key、TTL、版本前缀、预热或失效动作和回滚后的兼容性。只执行已授权的清理/预热，记录影响范围和结果；不要用全量删除代替原因分析。
8. **收口**：确认所有实例运行目标产物、迁移状态、静态资产引用、OpenResty reload/restart 结果、readiness、关键业务探针和监控告警。关闭弃用开关前检查旧版本流量已归零并保留回滚包。

## 失败与回滚

- 构建、签名、配置或迁移门禁失败：停止发布，保留产物和日志，不推进下一组件。
- 新版本未 ready 或灰度指标超出批准阈值：停止扩散，恢复上一稳定产物/配置，必要时关闭 feature flag；回滚顺序必须遵守数据库 expand/contract 的可兼容阶段。
- 已执行不可逆迁移：不能声称可自动回滚；启用兼容代码或按批准的补偿迁移处理，并把风险升级给负责人。
- 缓存导致旧响应：先恢复兼容读路径和版本前缀，再按授权执行定向失效；记录缓存证据。
- 发布平台不可用：不把计划或静态配置检查当作成功，标记“未验证”并保留人工执行步骤。

## 证据记录

发布记录至少包含 commit/tag、组件版本矩阵、产物 hash、构建/扫描命令、配置校验、迁移状态、顺序与批准、灰度批次和窗口、health/readiness 响应、核心指标快照、缓存动作、回滚点、未验证项和最终负责人。敏感值只记录引用名或脱敏摘要。

## 完成条件

所有目标组件都使用可追溯产物，迁移和配置处于批准状态，灰度证据满足发布方案，健康检查和关键指标已观测，回滚包与步骤可执行，未验证项已显式升级；否则保持“进行中/阻断”，不标记稳定发布。

## 不触发与路由

- 只判断 Kubernetes、容器、云网络、SLO 或基础设施容量：路由到 `senior-devops-engineer`。
- 只实现 Go 优雅关闭、探针、HTTP/gRPC 客户端：路由到 `go-microservice`。
- 只写或审查 OpenResty Lua/API 阶段代码：路由到 `openresty-patterns` 或 `senior-openresty-engineer`；网关 reload、流量切换等操作另走 `openresty-gateway-operations`。
- 只做 Go 代码质量门禁、PHP 质量门禁或前端验收：分别路由到 `go-enterprise-quality`、`php-enterprise-quality`、`frontend-acceptance`。
- 只做跨栈接口 schema 和兼容测试：路由到 `cross-stack-api-contract`。
