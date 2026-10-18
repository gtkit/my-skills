# 2026-10-18 Skill/Harness 修复验证

## 修改范围

修复 Go 测试授权/已有声明冲突、网关限流key与指标label混用、proto-first缺口、发布按栈检查遗漏、报告完成与验证通过混淆、validator错误分支、harness外部依赖诊断、通用Go版本政策。

维护直接在两个原仓库进行，未创建工作树、替代项目副本或提交。运行数据和示例检查文件位于当前skills仓库，`.local/`仅保存本地备份/检查产物并在git本地exclude中忽略。

## 结构与可执行检查

| 检查 | 证据 | 结果 |
|---|---|---|
| 正常输入、缺name、缺description、缺引用、catalog漂移 | [validator记录](artifacts/validator-2026-10-18.txt) | 5例通过；维护前受保护Error变量下4个错误分支崩溃 |
| skill结构、引用及catalog | [结构记录](artifacts/structure-2026-10-18.txt) | 49项，0错误，3个既有长度提示 |
| harness技术skill依赖源覆盖 | [依赖记录](artifacts/dependencies-2026-10-18.txt) | 24项，无缺失；错误manifest路径实测退出1 |
| AGENTS/CLAUDE模板同步 | Git Bash执行sync-claude-from-agents.sh --check | 退出0；未刷新任何业务项目 |
| 两仓diff空白检查 | git diff --check | 退出0 |
| 治理示例 | [Go记录](artifacts/go-example-2026-10-18.txt) | 见记录；只提取原示例在本仓库检查，没有更改Go实现 |

## 模型行为证据

[完整输入、答复摘录及实际资源读取](artifacts/behavior-2026-10-18.md)。维护前6项显式加载基线、修改后8项显式加载任务、1项doctor授权实施补充回测和7项目录选择任务；均只读回答，没有执行目标业务。

基线代理已能依靠用户上下文避开部分错误规则，不能据此宣称修复提升了触发率/完成率。修改后记录证明这些具体提示下能读取新参考、保留proto事实源、区分限流key和监控label、尊重授权并保持关键未验证项阻断；不证明所有未来请求或平台自动触发。

## 本机同步

用户已授权处理安装缺口。11个新增SOP与2个修订Go skill同步至现有Claude/Codex/agents三个用户skill目录，共39份。[逐文件清单及SHA256核对记录](artifacts/installation-2026-10-18.txt)一致；旧副本已备份至本仓库`.local/skills-before-sync-20261018-234959.zip`，没有修改用户运行时配置。

这只是本地工作区版本同步，不是从发布commit构建的稳定发布。文件存在/hash一致不证明当前会话立即发现新skill；自动发现需新会话实际观察。

## 人工复核栏

状态：待用户审阅。重点核对测试授权不重复询问、生产操作边界、缺skill与缺运行证据不转绿、major发布政策及旧页面/worker兼容窗口。用户批准前不把本次维护结果标为稳定发布。
