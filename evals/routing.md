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

## 记录格式

- **证据层级**：静态 / 场景推演 / 实际运行。
- **输入**：完整用户请求和必要前序对话。
- **预期**：应触发、不得触发或允许并存的 skill。
- **结果**：实际触发、读取资源、授权分支和完成条件。
- **未验证项**：模型、平台、工具权限或外部依赖缺失时明确列出。
