---
name: cross-stack-api-contract
description: "Use when Go/PHP or gRPC/gateway APIs and clients need shared contracts, schema compatibility, generation, or contract tests."
---

# 跨栈 API 契约

## 适用场景

当 Go/PHP 后端、gRPC/gateway 与 Vue/React/PHP 客户端需要共同维护契约、错误、分页、时间、金额、鉴权或版本兼容规则时使用。目标是形成可审阅、可生成、可测试的接口事实来源；不负责具体 handler/controller 实现，也不替代 `backend-acceptance` 或 `frontend-acceptance` 的最终验收。

## 输入与前置事实

开始前收集并记录：

- 需求、现有请求/响应样例、状态码和错误码来源；缺少来源的字段或默认值标为“待确认”。
- 契约唯一源及版本：手写 OpenAPI/JSON Schema 或 proto；记录生成器、marshaler、插件和生成配置。若不存在，先确定存放位置和所有者。
- Go/PHP DTO、序列化设置、路由与鉴权中间件；前端 API client、类型生成方式和运行时校验方式。
- 分页排序、时区、金额精度、租户/权限语义和兼容窗口；这些值必须来自需求、代码、数据库或已批准的 ADR。
- 可运行的服务、测试数据和依赖；不能运行时只记录静态推演，不能把“未验证”写成通过。

## 按顺序执行

1. **划定接口集合**：列出方法、路径、请求头、query/path/body、成功响应、错误响应、鉴权要求和副作用。把同一路径的不同 content type 分开记录。
2. **按事实源建立 schema**：已有 proto 时先读取 `references/grpc-contracts.md`，保持 proto→生成代码/OpenAPI 的单向链，不手写第二份事实源。REST schema 遵循实际版本：OpenAPI v2 使用 `definitions`，3.x 使用 `components.schemas`；3.0 的 `nullable` 与 3.1 的含 `null` 类型不可混用。字段记录来源、必填性、空值、边界、扩展策略和示例。
3. **固定跨栈表示**：
   - 错误 envelope 至少记录稳定的错误标识、面向用户的消息、字段错误、request/correlation id 和可重试提示；具体字段名、状态码和错误码以现有契约为准。
   - 分页明确 page/limit 或 cursor 的一种协议、排序稳定性、总数是否存在、空结果和下一页条件；未获批准不得混用两种协议。
   - 时间明确传输格式、时区和精度；金额明确货币、最小单位或 decimal 字符串，禁止因语言默认浮点而丢精度。
   - 鉴权明确 token/cookie 位置、刷新/过期行为、CSRF 要求、租户或资源授权失败的响应语义；不要把客户端传入的内部身份头当作事实。
4. **定义兼容性**：按客户端版本和部署顺序列出新增、弃用、删除、改名、类型收窄、枚举变化、默认值变化及错误语义变化。默认采用“先兼容后删除”仅作为待批准策略；不能假定旧客户端会立即升级。
5. **对照实现**：逐字段比对 Go/PHP 的 DTO、序列化标签、校验器、错误映射和前端类型/解析器。差异写入追踪表，注明是契约错误、实现错误还是未决需求。
6. **生成与检查**：按唯一源和项目锁定的生成命令生成 Go/PHP 类型、前端 client 或校验器；proto 项目检查 buf lint/breaking 与 gateway/OpenAPI 生成链，普通 REST 项目检查 schema 和 client 生成。把命令、版本、输入 commit 和输出摘要写入证据；不手改生成结果。
7. **编写契约测试**：覆盖成功边界、缺字段、未知字段、枚举、分页游标、时间/金额序列化、鉴权失败和错误 envelope。后端用真实路由或测试 server 产生响应，前端用 schema 校验真实或固定回放响应；反向测试旧客户端可接受新增字段，前提是契约允许。
8. **评审兼容窗口**：与后端、前端和发布负责人确认部署顺序、灰度期间同时存在的版本、弃用通知和删除日期。任何无法证明的兼容结论标为“未验证”。

## 检查清单

- [ ] 每个接口都有方法、路径、输入、成功响应、失败响应和鉴权来源。
- [ ] schema 的必填、缺省、null、默认值、格式和未知字段策略符合所用规范版本与实现。
- [ ] 错误 envelope 可由前端稳定解析；5xx 不依赖内部异常文本。
- [ ] 分页、时间、金额在 Go、PHP、TypeScript/JavaScript 三侧具有相同序列化语义。
- [ ] 鉴权失败、租户隔离和资源越权的契约来自授权矩阵或测试证据。
- [ ] 破坏性变更有版本/兼容窗口、迁移步骤和回滚处理。
- [ ] 生成器版本和契约测试在 CI 中可复现；本次未运行的命令标为“未验证”。

## 失败与回滚

- schema 校验失败：停止生成和发布，保留失败输入、响应样例和差异；回到来源表确认规则。
- 生成结果与手写实现冲突：以已批准契约为准修正实现或契约，不能通过修改生成文件掩盖差异。
- 旧客户端在灰度中无法解析：暂停扩大流量，恢复兼容响应或回滚到上一个契约版本；记录受影响客户端版本和观测窗口。
- 测试环境不可用：不模拟“通过”，保留静态检查结果并标记运行验证缺失。

## 证据记录

在变更记录中保存契约文件路径与 hash、需求/ADR 链接、实现追踪表、生成命令和版本、契约测试命令及输出、兼容矩阵、未验证项和评审人。响应样例应脱敏；不要把 token、Cookie、个人数据或生产密钥写入证据。

## 完成条件

区分“契约文档/审阅完成”和“契约运行验证通过”。计划或审阅请求可以交付已完成的文档，并列出未验证项；只有适用的生成、兼容和契约测试实际通过，才能写“契约验证通过”。关键客户端或失败路径未验证时保留阻断项，不因补上负责人或待办而转绿。最终准入按变更面交给 `backend-acceptance` 与 `frontend-acceptance`。

## 按需资源

- proto/gRPC、grpc-gateway、ProtoJSON 或生成 OpenAPI：`references/grpc-contracts.md`。

## 不触发与路由

- 只写 Go/PHP handler、Laravel controller、Vue/React 组件或 OpenResty Lua：路由到 `go-gin-api`、`senior-php-engineer`、`vue-frontend-engineer` 或 `openresty-patterns`。
- 只做后端业务、事务、权限、并发或安全验收：路由到 `backend-acceptance`，再按语言进入 `go-enterprise-quality`、`go-data-consistency` 或 `go-security`。
- 只做前端发布验收：路由到 `frontend-acceptance`。
- 只设计跨语言事件或队列消息：路由到 `async-job-contracts`。
- 需要跨层发布顺序、迁移、灰度或回滚：追加 `polyglot-release-engineering`；不要把本 skill 当作发布批准。

