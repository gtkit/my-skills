# Skill Optimizer 全库审查记录

日期：2026-10-18  
范围：当前工作区 38 个 `SKILL.md`、107 个 references 文件、templates/scripts、根目录 README、打包/同步脚本、`AGENTS.md`、`catalog.yaml` 和路由场景矩阵。

## 证据层级

- **静态审查**：已完成。检查 frontmatter、目录一致性、description、相对引用、文件长度、平台路径、依赖安装指引、敏感信息模式和相邻 skill 路由。
- **场景推演**：已完成代表性矩阵，见 `evals/routing.md`。
- **实际运行**：当前未完成真实模型触发率对比；由于本机未使用 Claude 且工具不全，该项暂记为“未验证”，不声称触发率、完成率或上下文用量改善。
- **领域事实逐条复核**：未完成全量复核；本轮只核对了流程级高风险项和已有“实测”标记的结构，没有重新运行每个语言/框架的实验。

## 结果总览

| 审查项 | 结果 | 说明 |
|---|---|---|
| frontmatter 与目录名 | 通过 | 38/38 的 `name` 与目录一致，description 均不超过 150 个字符 |
| 相对资源引用 | 通过 | `references/`、`templates/`、`scripts/`、`agents/` 引用均可解析 |
| 文件长度 | 通过并保留 warning | 无文件超过 400 行；3 个文件超过 250 行但未拆分 |
| 按需加载 | 通过并保留例外 | 25 个 skill 有 references；短 skill 保持单文件；流程 skill 的模板/脚本已纳入 catalog |
| 触发边界 | 静态通过，运行待测 | 已审查 8 组相邻职责，尚无同模型前后版本对比 |
| 工作流与授权 | 已修正 | 移除自动 `git rm --cached`；取消“写契约测试必须先停顿确认”的硬规则 |
| 依赖与安全 | 已修正，仍需环境验证 | 禁止缺失工具时自动安装 `@latest`；样例凭据改为占位符；Claude Web 路径保留平台限定 |

## 已修正的问题

1. `planning-with-files` 原本要求发现计划文件已被 Git 跟踪时自动执行 `git rm --cached`。现在改为停止并报告，只有用户明确授权时才允许改变索引。
2. `go-enterprise-quality` 原本要求写契约测试前先向用户确认。现在按原始请求和仓库门禁判断；只有测试会扩大授权范围时才说明范围。
3. `go-enterprise-quality` 原本提供 `go install ...@latest`。现在缺失工具只标记未验证；安装必须有明确授权且使用项目批准的固定版本。
4. `senior-openresty-engineer` 补充外部 Lua 库的安装方式、版本、校验和缺失处理要求，并明确 skill 不自动安装。
5. `senior-python-engineer` 的数据库连接示例改为 `<password>` 占位符。
6. README 不再把“每个 Go 代码块都有提交到仓库的验证文件”作为硬要求，改为要求记录独立模块和 Go 版本验证结果。

## 保留的待实测项

- `planning-with-files-web` 使用 `/mnt/skills/user` 和 `/home/claude`，仅适用于 Claude.ai Web；需要在目标环境做一次初始化脚本和缺失依赖演练。
- `backend-acceptance`、`frontend-acceptance`、`vue-frontend-engineer` 与既有审查/实现 skill 的边界已有描述和场景矩阵，但没有真实模型路由数据。
- `go-review`、`senior-nodejs-engineer`、`senior-python-engineer` 分别为 255、264、273 行；是否拆分要根据真实加载成本决定。
- 版本相关和“实测”事实未在本轮重新运行每个语言/框架的实验；本轮只检查文档结构和已有验证标注。

## 结论

按 `skill-optimizer` 的静态审查和场景推演要求，当前仓库已经完成一轮全库审查并修复确定性问题；按真实模型行为要求，尚未完成最终验收。下一步应在固定模型、平台和工具权限下执行 `evals/routing.md` 的代表场景，并记录实际触发、读取资源、授权分支和完成条件。
