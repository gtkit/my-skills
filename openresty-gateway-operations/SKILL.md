---
name: openresty-gateway-operations
description: Use when reviewing or operating Nginx/OpenResty gateways, upstreams, timeouts, buffering, certificates, traffic shifts, and rollback.
---

# OpenResty 网关运行操作

用于检查和执行可回滚的 Nginx/OpenResty 网关变更。重点是配置、连接、流量和运行证据，不把 Lua 代码模式或架构选型重复写进本 skill。

## 适用场景

- 修改或审查 `server`、`location`、`upstream`、timeout、buffering、cache、限流和 header 配置。
- 处理 WebSocket/SSE 长连接、TLS 证书、reload、灰度、流量切换或紧急回滚。
- 排查 4xx/5xx、upstream timeout、连接堆积、缓存错误、限流误伤和 reload 后异常。

## 输入与前置事实

先取得当前生效配置（如 `nginx -T` 或 `openresty -T` 的脱敏输出）、版本和启动方式、监听地址、upstream 成员及健康检查方式、请求类型（普通 HTTP、WebSocket、SSE、上传/下载）、超时预算、body/响应大小、缓存与限流契约、证书链和过期时间、当前流量与回滚版本。没有契约或容量数据时标记“未确认”，不要凭经验填阈值。只审查或输出计划时不执行 reload、摘流量或回滚；目标环境变更只执行本次用户已授权的动作。

## 按顺序执行

1. **建立变更快照**：保存 commit、模板输入、渲染后的配置、当前 worker/PID、upstream 状态、最近错误日志和基线指标。确认变更只覆盖预期的 `server/location/upstream`。
2. **做静态检查**：运行项目指定的 `nginx -t`/`openresty -t` 和配置 dump；检查 include 路径、变量来源、重复 directive、权限、证书和 key 文件可读性。语法通过不等于行为通过，保留退出码和完整输出位置。
3. **核对 upstream 与超时**：逐个 upstream 核对 DNS/IP、端口、协议、连接复用、健康检查、失败转移和 `proxy_connect_timeout`、`proxy_read_timeout`、`proxy_send_timeout`。将每个值与调用方 SLA 或下游预算对照，缺证据则不声称合理。
4. **核对 buffering/cache/限流**：确认 request/response buffering、上传大小、缓存 key、绕过条件、失效路径、拒绝状态码和 `Retry-After` 契约。将限流状态 key 与监控 label 分开检查：按用户限流可使用可信鉴权结果中的用户 ID，按 IP 限流需核对可信代理链；不直接信任客户端身份头。按 key 长度、活跃身份数、过期/淘汰行为估算 zone 容量，避免任意 URI/query 形成无界 key。指标 label 使用归一化路由、状态等有限集合，排除用户 ID 和原始 URI；具体缓存一致性转相关 skill。
5. **验证长连接**：对 WebSocket 检查 `Upgrade`/`Connection`、读超时和单连接资源；对 SSE 检查流式响应、缓冲关闭、心跳、代理超时和断线重连约定。使用真实客户端或受控脚本；只用 `curl` 不能证明 WebSocket 全链路。
6. **验证 TLS 与安全头**：用 `openssl s_client`、证书链检查工具和实际客户端核对 hostname、链、有效期、协议/密码策略及 OCSP/Stapling（若契约要求）。敏感 header 和来源策略以安全规范为准，记录未验证项。
7. **预演 reload 与流量切换**：在目标实例执行语法检查后按既定方式 `nginx -s reload` 或 `systemctl reload openresty`，观察新 worker、连接、错误率、延迟和 upstream 状态。灰度只扩大到下一批次前，先验证健康探针和一条真实业务流；切换条件必须来自发布或运行手册。
8. **完成回滚演练**：保留上一份完整配置和证书引用。若 reload 失败、错误率/延迟超预算或长连接异常，恢复上一版本并 reload，必要时将流量切回旧实例；回滚后重新执行健康、关键请求和指标检查。

## 失败、回滚与降级

- `-t` 失败：不 reload，修复模板或恢复快照并重新检查。
- 新 worker 启动但请求异常：停止扩大流量，按版本回滚并保留失败配置、日志和指标时间窗。
- 单个 upstream 故障：只在契约允许时摘除节点；不要无证据扩大重试或延长超时，避免重试放大。
- 证书或密钥错误：恢复上一份可用证书引用并确认权限；过期风险需升级证书流程，不在现场生成未经批准的长期密钥。
- 缓存、限流或长连接策略引发用户影响：先关闭新规则或切到旧 location，再记录受影响请求和数据是否需要清理。

## 证据记录

记录命令、版本、配置 diff/hash、语法检查输出、实例/PID、upstream 快照、证书检查结果、灰度批次、请求样本、状态码/延迟/连接数/错误日志、切换时间、回滚触发和回滚后的复查结果。每项用“通过 / 失败 / 未验证 / 不适用”；没有真实长连接客户端、生产流量或证书权限时明确写“未验证”。

## 完成条件

- 变更范围、超时/缓存/限流/长连接假设均有来源或标为未确认。
- 语法、关键路径和目标协议已在可用环境运行验证；不可运行项有补测条件。
- 灰度、reload、回滚和回滚后健康检查都可由另一位操作者复现。
- 关键指标、日志和配置快照已归档，未把 `nginx -t` 单独当成发布通过。

## 不触发与路由

- Lua API、执行阶段、`ngx.shared.DICT`、cosocket、timer 或代码模式转 `openresty-patterns`。
- 网关架构、WAF 方案、出站模型、容量和热更新设计转 `senior-openresty-engineer`。
- 主机、容器、Kubernetes、发布平台和 SLO 运维判断转 `senior-devops-engineer`。
- 跨组件 request/trace/log/metrics 关联转 `cross-stack-observability`；跨栈发布编排转 `polyglot-release-engineering`。
