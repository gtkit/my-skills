---
name: php-enterprise-quality
description: "Use when PHP/Laravel changes need CI gates for tests, static analysis, Composer, migrations, queues, or security checks."
---

# PHP 企业级质量门禁

## 适用场景

当 PHP/Laravel 代码、依赖、迁移、队列或 CI 配置需要交付前质量检查时使用。覆盖 PHPUnit/Pest、PHPStan/Psalm、Pint、Composer、迁移、队列和静态安全检查；不替代 `senior-php-engineer` 的 PHP-FPM/Octane、Laravel 运行时判断，也不直接给出 `backend-acceptance` 的最终后端验收结论。

## 输入与前置事实

先记录 PHP、Laravel、Composer 版本，`composer.lock`、测试脚本、分析配置、代码风格配置、数据库引擎/迁移状态、队列驱动、CI 环境和安全扫描工具。确认本次改动范围及需求/契约来源；工具未安装、环境不可用或命令未运行都标为“未验证”，不推断通过。

项目没有统一命令时，先读取 `composer.json` scripts、CI workflow 和贡献指南，再选择实际命令。不要凭经验改动 PHP 版本、分析级别、忽略规则或安全基线。

## 按顺序执行

1. **锁定变更与依赖**：检查 `git diff`、`composer.json`/`composer.lock`、自动加载和脚本钩子；执行 `composer validate` 或项目等价检查。依赖变更记录来源、版本约束、许可证和锁文件差异。
2. **运行快速门禁**：按项目脚本运行 Pint（或既定 formatter/linter）和单元测试；PHPUnit/Pest 的过滤、并行和环境参数必须写入证据。失败时先保存首个可复现错误。
3. **运行静态分析**：执行 PHPStan 或 Psalm 的项目命令，确认 baseline/ignore 规则没有掩盖新增问题。新增 suppression 必须有原因、范围和评审记录。
4. **覆盖行为风险**：针对改动补足或检查测试：请求验证与错误 envelope、授权分支、事务边界、幂等、序列化、时间/金额、异常路径、队列重试和重复消费。业务规则来自需求、API 契约或已有不变量，缺来源时标待确认。
5. **验证迁移**：在临时或测试数据库上按项目命令执行迁移、回滚（若支持）和空库初始化；记录锁表、数据转换、索引和 expand/contract 兼容性。不能在未授权的生产数据库执行迁移。
6. **验证队列**：在隔离环境检查 job 序列化、失败/重试、超时、幂等和 dead-letter/failed_jobs 处理；需要真实 broker 或 worker 时记录环境和运行结果，无法启动则标未验证。
7. **执行安全检查**：按项目已有工具运行依赖审计、secret 扫描、SAST/规则扫描和输入/输出安全测试；结果按工具版本、数据库更新时间和误报处置记录。安全实现问题路由到对应安全 skill，不以“扫描无告警”代替审查。
8. **回审调用方与契约**：检查路由、中间件、DTO、前端或异步消费者调用方；接口变化追加 `cross-stack-api-contract`。高风险后端行为再交给 `backend-acceptance`。

## 检查清单

- [ ] PHP/Laravel/Composer 和工具版本来自项目文件或实际命令输出。
- [ ] Composer 依赖可解析，lockfile 与自动加载状态一致。
- [ ] PHPUnit/Pest、Pint、PHPStan/Psalm 命令和结果可复现。
- [ ] 新增/修改业务分支有需求或契约来源，异常路径和权限路径有反证。
- [ ] 迁移在隔离数据库验证过；不可逆或生产迁移有批准与回滚/补偿方案。
- [ ] 队列 job 的失败、重试、幂等和重复投递证据已记录。
- [ ] 安全扫描、依赖审计和 secret 检查的工具版本与未验证项已记录。
- [ ] 未运行的门禁显示“未验证”，没有用 CI 配置存在代替实际结果。

## 失败与回滚

- 测试、静态分析或格式检查失败：保留命令、环境、首个失败和修复范围，修复后从失败门禁重跑。
- 依赖解析或安全审计失败：停止合并/发布，回退锁文件或升级到已批准版本；不要扩大 ignore 范围来消除红灯。
- 迁移失败：停止后续写入，保留数据库日志和迁移版本；按批准的回滚或补偿步骤处理，无法证明可逆时升级负责人。
- 队列兼容性失败：暂停新 job 投递或消费（需授权），保留失败载荷摘要并验证旧/新 worker 的兼容窗口。

## 证据记录

保存 commit、PHP/Composer/tool 版本、命令和退出码、测试报告、静态分析报告、formatter diff、依赖和安全扫描摘要、迁移前后版本、队列运行日志、调用方回审结果、未验证项和评审人。日志、载荷和报告必须脱敏，不记录 token、Cookie、密码或个人数据。

## 完成条件

所有适用门禁均执行并通过，或每个失败/未验证项都有明确责任人、阻断级别和后续动作；依赖、迁移、队列和安全变更已有证据；调用方影响已回审。只有 `backend-acceptance` 完成后才能把结果写成后端生产准入。

## 不触发与路由

- 只讨论 PHP-FPM/OPcache/Octane、Eloquent 性能、运行时锁或 Laravel 设计：路由到 `senior-php-engineer`。
- 只做 Go 代码质量：路由到 `go-enterprise-quality`。
- 只做接口 schema、版本兼容或契约测试：路由到 `cross-stack-api-contract`。
- 只做后端业务不变量、授权、事务和生产风险验收：路由到 `backend-acceptance`。
- 只做供应链范围的跨语言依赖、SBOM、镜像或许可证治理：追加 `polyglot-security-supply-chain`。
