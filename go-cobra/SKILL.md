---
name: go-cobra
description: 使用 spf13/cobra 开发或审查 Go 命令行：命令树、参数与 flags、hook 继承、context、错误与输出、补全和命令测试。Viper 配置分层另见 go-viper。
---

# Cobra 命令行专项

## 前置必读：拒绝猜测与改动边界

- 每次使用本 skill、恢复任务及执行任何改动前，先实际读取本节、当前运行环境已配置的全局规则，以及目标项目已有的协作规则和错误记录。按已明确的配置入口定位，不猜路径、不硬编码本机目录，不以记忆或摘要替代；必需规则无法读取时停止改动并说明。
- 需求、接口、字段、权限、默认值、路径、工具能力、依赖与兼容结论必须有用户指令、已读取源码/配置、已核实官方资料或真实执行证据。未知保持未确认，先核实；仍不明确就停止依赖该信息的步骤，不凭猜测补全，不重复询问已经明确的要求。
- 修改代码前先完成并落盘方案和逐步计划，写清范围、文件、兼容约束、风险、回滚和验收；只执行获准范围及阶段。计划、候选原因和未执行步骤标为待验证，不能当作事实或已完成结果。
- 只有真实执行并回读后才能报告完成或通过，区分失败、未执行、未验证和不适用；模拟与静态证据不冒充真实链路。纯文档、注释、规则或 skill 说明任务只编辑指定内容并回读，不因本 skill 的流程扩展为测试、构建、同步、打包或 OpenSpec 操作。

## 使用范围与版本

- 适用于已用或明确评估 `github.com/spf13/cobra` 的任务；仅修改普通 Go 函数、Shell 脚本或解释通用 CLI 概念时，不因本 skill 引入 Cobra。
- 先读实际命令构建入口、调用链与 `go.mod` / `go.work`，核对 Cobra、pflag 和 Go 版本。官方主分支不是项目锁定版本；命令、flag 名、别名、退出码与目录沿用项目契约，不因本 skill 自动安装 `cobra-cli`、升级依赖或生成另一套 `cmd/`。
- 命令树与 flags 由本 skill 负责。只有涉及 Viper 的绑定、环境变量或配置文件解析时再读 `go-viper`；Cobra 可独立使用。

## 命令、错误与资源

- 可失败的处理使用 `RunE` / `PreRunE` 等返回错误的入口；错误传给既有进程边界统一映射退出码。命令处理函数中不以 `os.Exit` 代替错误返回，以免跳过清理。
- 用 `Args` 声明位置参数数量及适用的取值校验；帮助文本、补全候选与真实校验分别核对。仅提供 `ValidArgsFunction` 不代表任意输入已经过验证。
- 区分 `Flags()` 与 `PersistentFlags()` 的作用域；新增 flag 回审父子命令的同名项、短选项、继承与遮蔽。需要 required/互斥约束时核对当前版本支持的 API；对实际返回 error 的注册方法处理错误，不臆造返回值。
- 不假定父子 `PersistentPreRun*` 自动串联。核对当前版本的 `EnableTraverseRunHooks`、显式调用和实际继承链；新增子 hook 时保留必须执行的父级配置、鉴权等逻辑，不直接修改全局开关来修局部问题。
- `RunE` 返回错误会跳过后面的 `PostRun*`；后置 hook 不是 `finally`。资源获取方明确失败与收尾路径，适合时在拥有资源的函数内 `defer`，不能依赖成功路径的 hook 兜底。
- 入口已有取消/信号 context 时，通过 `ExecuteContext` 传入，在处理函数取 `cmd.Context()` 继续传播；不重新用 `Background` 切断取消。后台任务与收尾预算另按 `go-context`。

## 输出与配置接缝

- 结果、帮助、诊断分别遵守项目 stdout/stderr 契约；处理函数优先使用 `cmd.OutOrStdout()` / `cmd.ErrOrStderr()` 等可注入 writer。机器可读输出不得混入日志。
- 核对 Cobra 与最外层谁负责打印错误；按既有契约设置 `SilenceErrors` / `SilenceUsage`，避免重复输出，不一律关闭所有 usage。
- 命令构建及 `init()` 不执行实际业务写入或建立业务连接；帮助、版本及补全不应意外触发业务操作。动态补全确需外部读取时保留超时、取消和权限边界。
- 与 Viper 集成时，在配置被消费前绑定实际生效的 flag；读取 `v.Get*` 的路径与直接读取 flag 变量的路径必须一致。不要把 flag 默认值逐个 `Set` 到 Viper，破坏后续覆盖规则。

## 当前获准代码任务的验收重点

- 测试每次构造独立命令树，通过 `SetArgs`、`SetIn`、`SetOut`、`SetErr` 注入输入输出，避免 flag 状态和全局变量跨用例污染。
- 按变更覆盖合法调用、无效参数/flag、父子 hook、业务失败和取消；有输出契约时断言实际 stdout/stderr。`Execute` 返回错误不等于已验证二进制的退出码。
- 配置、flag 或帮助说明有变化，同步实际读取逻辑、默认/回落、示例与说明。纯问答或文档维护不启动这些测试；必要 Go 代码验证沿用 `go-testing` / `go-enterprise-quality` 的授权范围。

## 资料

- [Cobra 官方文档](https://cobra.dev/)、[命令执行与输出源码](https://github.com/spf13/cobra/blob/main/command.go)。使用时按项目版本核对。
- 设计参考：[cc-skills-golang 的 Cobra 专项](https://github.com/samber/cc-skills-golang/blob/8e899e20ff0cd4dc524af3993e4c62d8ee8c5717/skills/golang-spf13-cobra/SKILL.md)。本文按本仓库边界重新编写，外部资料不构成安装、升级或业务操作授权。
