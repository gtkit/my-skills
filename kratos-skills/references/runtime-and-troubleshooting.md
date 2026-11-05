# 生命周期、配置、观测与排障

## 启动和退出

Kratos [App](https://github.com/go-kratos/kratos/blob/v3.0.0/app.go) 负责 transport 的 Start/Stop、信号及注册/注销；[选项](https://github.com/go-kratos/kratos/blob/v3.0.0/options.go) 提供生命周期 hook、`StopTimeout` 和 `RegistrarTimeout`。先读目标项目如何装配和调用 `Run()`，不要再加一套相互竞争的信号处理。

- 应用 context、请求 context、构造/探活 context 的归属不同。业务 I/O 继续传请求 context，不能为避免取消统一换成 `Background()`。
- 停止预算要覆盖摘流、在途请求、transport Stop 和资源关闭，并小于外部终止预算。v3.0.0 只有 `StopTimeout > 0` 才为 server Stop 添加超时，不把默认值当成已设定有界收尾。
- `BeforeStop`、注册中心注销、server 停止和外部负载均衡传播之间有次序和失败路径。不要声称执行了某个 hook 就证明摘流完成；注册/注销失败后的行为以实际源码和项目补偿为准。
- `AfterStart` 或 `Run()` 返回成功不证明依赖可用；按项目分别定义 liveness/readiness。框架附带 gRPC health 不等于数据库就绪，鉴权/探活豁免也要显式核对。
- 资源清理不能提前关闭在途请求仍需要的连接。构造失败、启动失败、正常退出和超时强退分别说明实际覆盖范围。

## 超时和连接

v3.0.0 HTTP/gRPC server 的默认请求超时为 1 秒；它是版本事实，不是业务推荐值。核对配置是否覆盖，以及客户端、server、DB/RPC 每跳的有效 deadline。

`http.Timeout` 设置请求 context 的 deadline，不自动完成所有 socket 防护，也不能强制结束忽略 context 的业务逻辑。HTTP server 嵌入 `net/http.Server`，读头/读写/空闲超时、header/body 限额按项目与流式接口需求配置。gRPC 流检查单独的 stream middleware/interceptor、消息大小、取消与长连接策略。

出站 HTTP/gRPC 客户端按项目资源生命周期共享并关闭；调用预算与重试要符合幂等语义。发现型 endpoint 要核对协议、服务名、discovery 实现和实例 endpoint；不能把 `discovery:///…` 当普通 URL，也不能靠修改拼写排除注册中心问题。

依据：[HTTP server](https://github.com/go-kratos/kratos/blob/v3.0.0/transport/http/server.go)、[gRPC server](https://github.com/go-kratos/kratos/blob/v3.0.0/transport/grpc/server.go)、[HTTP client](https://github.com/go-kratos/kratos/blob/v3.0.0/transport/http/client.go)。

## 配置

先核对实际 source 顺序、合并规则、环境变量前缀、解析方式和默认值，不假定任意环境变量都会自动覆盖文件。读取 [config](https://github.com/go-kratos/kratos/blob/v3.0.0/config/config.go) 使用处的 `Load`、`Scan`、`Value`/`Get[T]`、`Watch`、`Close`。

- 类型和业务约束在启动时验证；必需配置缺失、无效地址、负超时等如何处理按项目规则确定，不默默回落掩盖错误。
- 改动配置字段时同步类型、生成物、真实配置、示例和说明：用途、作用对象、默认/留空回落、约束与关联项。
- `Scan` 得到的对象不能假定自动随 Watch 更新。热更新要验证新快照，再通过项目已有并发安全方式发布；不能边改共享配置边让请求读取。
- 配置有 watcher 需要清理；禁止将密钥、原始 DSN 或本机绝对目录写进日志、示例和报告。

## slog 与 OTel

v3 使用 `*slog.Logger`，核心 `log` 提供 builder 与 context 属性；不要继续生成 `log.NewHelper` 或要求迁移到其他技能示例中的日志库。参考 [log 文档](https://github.com/go-kratos/kratos/blob/v3.0.0/log/README.md)。

- 沿用现有 handler、级别、结构化字段和脱敏。v3 logging middleware 会提取请求参数；[recovery](https://github.com/go-kratos/kratos/blob/v3.0.0/middleware/recovery/recovery.go) 也记录 panic、请求和 stack。审查实际请求记录方式，不能默认敏感参数已被屏蔽。
- Trace/metrics/log 集成位于 [contrib/otel](https://github.com/go-kratos/kratos/blob/v3.0.0/contrib/otel/README.md)。只注册 middleware 不等于已经初始化 SDK provider、exporter 和传播器。
- HTTP 与 gRPC、客户端与服务端分别确认传播路径；避免框架 middleware 与额外 instrumentation 重复记录同一 span。gRPC stats handler 与 stream 拦截要按现有方案匹配。
- slog 的 context 属性与 trace 字段提取需要实际 handler 支持；当前模板使用 `log.WithExtractor(tracing.TraceAttrs)`，不能假定任意 `slog.New` 都会自动附带 trace ID。
- 指标限制高基数标签；OTel 指标与旧 Prometheus 指标名、单位和 bucket 不能仅凭同名假定兼容。检查 dashboard/告警实际查询；关闭 provider 使用独立且有界的收尾 context。

## 按症状定位

| 现象 | 先核对的证据 | 避免的误修复 |
|---|---|---|
| v3 编译报旧 Helper/binding/JWT 符号不存在 | go.mod、import、生成文件头、v3 迁移差异 | 重装全部 `@latest` 工具或手改生成物 |
| 生成失败或输出没变化 | 真实生成入口、工作目录、插件/依赖、stdout/stderr 和文件差异 | 仅凭退出码为 0 报生成完成 |
| Wire 缺 provider/重复绑定 | injector、ProviderSet、构造类型、build tag | 把资源改成全局变量绕过装配 |
| HTTP 404、405 或 gRPC Unimplemented | 实际注册、HTTP 注解/路径/方法、包/服务名与运行的二进制 | 先改业务方法或添加宽泛 catch-all |
| HTTP 正常、gRPC 校验或权限缺失 | 两个 server 各自链配置、stream 路径 | 把 HTTP 验证结果当作全协议证明 |
| JSON 字段/enum/整数变化 | codec 注册、Content-Type/Accept、客户端 decoder | 改 proto 字段编号迎合编码结果 |
| 一秒左右持续超时 | server 默认值、配置覆盖、有效 deadline、依赖调用 | 不查慢调用就关闭所有超时 |
| discovery 无实例或连接失败 | 注册/注销结果、服务名、实例 endpoint、网络与 resolver | 每次请求创建客户端或反复重启注册中心 |
| trace 丢失、日志无关联 | provider/propagator、client/server 接入、ctx 与 slog handler | 在单个中间件手造 trace ID |
| 退出挂住或丢在途请求 | hook、注销、StopTimeout、连接归属、cleanup 时机 | 立即 `os.Exit` 或提前关闭数据库 |

排障交付要区分观察事实、候选原因、定位证据和修复结果。源码阅读不能证明网络、注册中心、导出链路或生产收尾已验证；缺少运行条件时列出具体缺口，继续完成不依赖它的工作。
