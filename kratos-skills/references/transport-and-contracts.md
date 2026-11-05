# HTTP/gRPC、协议、错误与校验

以下框架符号以 Kratos v3.0.0 为基线；现有 v2 项目先按其依赖源码核对。代码生成的入口与副作用见 [版本与生成](version-and-generation.md)。

## 协议先于实现

- 沿用项目 `package`、`go_package`、服务命名和版本约定；核对 proto 文件所在模块，不凭业务目录猜 import 路径。
- 对 `google.api.http` 明确方法、路径变量、body/response_body 与额外映射。一个 RPC 有多条 HTTP 映射时都要检查，不能只看第一条。
- 新字段保留现有编号；移除字段保留编号/名称，不能重用。分别检查二进制、JSON 和生成客户端兼容性。
- 明确 proto3 隐式零值、`optional`、`oneof`、空消息、重复字段和更新掩码。PATCH 的未提供、写零值和清空不是同一操作。
- 分页上限、金额、时区、幂等键和租户身份遵循项目契约；proto 定义不能替代权限与业务规则。

## 两种协议要分别接入

从实际生成物定位 HTTP 的 `Register…HTTPServer`、gRPC 的 `Register…Server` 和对应接口。不要按服务名猜符号，也不要重写生成 handler。

同一 service 实现可以服务两种协议；构造成功后仍须在实际启用的 server 上注册。增加 RPC 后确认实现满足新生成接口，特别是 stream 方法签名。HTTP JSON 调用、二进制 gRPC 调用、各自校验/鉴权是独立核验项。

原生 `http.Handler`、文件下载、webhook、SSE 和 WebSocket 属于专门路径；检查是否有意绕开 RPC middleware、错误编码和统一响应。不要强行把流数据包装为普通 JSON 响应。

## JSON 与响应编码

[v3 迁移说明](https://github.com/go-kratos/kratos/blob/v3.0.0/docs/migration/v2-to-v3_zh.md) 区分标准 `json`、`protojson` 与 contrib 兼容 codec。为已有接口保留真实协议，而不是只修改 import。

检查请求 decoder、响应 encoder 和客户端 decoder 的整体配对：

- `Content-Type`/`Accept` 与实际选择的 codec；生成的 HTTP 客户端是否另行设置 codec 或 header。
- 字段名、64 位整数表示、enum、bytes、timestamp/duration、默认值输出及未知字段处理。不能用标准库 JSON 的直觉替代 ProtoJSON 契约。
- v3 核心 ProtoJSON 的默认配置为 `EmitUnpopulated: true`、`DiscardUnknown: true`；项目可覆盖，必须读实际设置。不能声称未知字段一定报错或默认值一定省略。
- `http.ResponseEncoder` / `http.ErrorEncoder` 改动是否同步影响生成客户端、OpenAPI、反向代理和现有调用方。未经需求不添加 `{code,data,message}` 响应壳或把错误统一改成 HTTP 200。
- `google.api.HttpBody`、重定向与流式响应有独立编码行为；自定义 encoder 要明确保留或有意改变哪些路径。

依据：[服务端编码](https://github.com/go-kratos/kratos/blob/v3.0.0/transport/http/codec.go)、[客户端解码](https://github.com/go-kratos/kratos/blob/v3.0.0/transport/http/client.go)、[ProtoJSON 选项](https://github.com/go-kratos/kratos/blob/v3.0.0/encoding/protojson/protojson.go)。

## 错误出口

Kratos 的 [errors](https://github.com/go-kratos/kratos/blob/v3.0.0/errors/errors.go) 使用 HTTP 风格 `Code`、稳定 `Reason`、面向调用方的 `Message` 与 `Metadata`；gRPC 状态经框架映射。HTTP 状态整数不是 gRPC `codes.Code` 的数值，不能强转。

- 沿用项目已有错误契约；如果已有 AppError 等模型，只在确认的边界适配，不创建并行的业务错误体系。
- 项目采用错误 proto 时维护源 enum/注解与对应生成入口；并非每个 v3 模板都使用 errors 插件生成 helper。
- 使用 `errors.Is/As`、`errors.FromError`、`errors.Code/Reason` 等读取错误链，不匹配字符串。v3 Kratos errors 包提供标准错误包装能力，import 别名只为真实冲突服务。
- `WithCause` 用于保留内部原因，`WithMetadata` 放可公开元数据；不要把 token、SQL、DSN、个人信息放入 Message/Metadata。
- 普通 Go error 经 `FromError` 转成 500 时，其 `err.Error()` 会成为消息；默认 HTTP encoder 不替你脱敏。外部响应要在实际错误出口处理，内部保留诊断原因。
- 把 not found、冲突、鉴权失败、资源耗尽、取消和超时映射到既有契约，HTTP 与 gRPC 分别核对；不要假定任意 context error 已自动获得期望业务状态。

## 校验不是写了注解就生效

v3 的 [validate.Validator](https://github.com/go-kratos/kratos/blob/v3.0.0/middleware/validate/validate.go) 先调用请求的 `Validate() error`，然后调用传入的各 `ValidatorFunc`。

| 项目方案 | 必须核对 |
|---|---|
| PGV | `validate/validate.proto` 导入、匹配插件与生成的 `Validate()`、middleware 是否挂载 |
| Protovalidate | 实际依赖、规则和运行时初始化；通过自定义 validator 验证 proto message，不能假定它会生成 PGV 风格方法 |
| AIP field behavior | 检查自定义 validator 的实现与覆盖范围；必填字段检查不能替代所有格式/跨字段/业务校验 |
| 自定义 DTO | 实际校验方法或自定义 validator 是否接受这个类型；解析成功不等于校验成功 |

HTTP 与 gRPC 各自挂载校验，stream 逐消息约束另行确认。默认校验错误会使用校验器的错误文本；需要脱敏时检查错误出口，而不是假定只有内部日志会看到它。非 HTTP 入口和内部复用路径仍须满足业务层不变量。

## 中间件、鉴权与入口限制

- RPC middleware 类型为 `func(middleware.Handler) middleware.Handler`；handler 接收 `context.Context` 与请求值。HTTP filter 包装 `net/http.Handler`，不能混作同一种签名。
- `middleware.Chain` 第一项包在最外层；入站正序、返回反序。明确追踪、日志、recovery、校验、鉴权所需顺序，不机械复制一串默认列表。
- 按 RPC operation 选择 middleware 时，以生成代码设置的完整 operation 为依据，不能把 HTTP URL 当作 RPC 名称。业务数据权限还要在查询/用例中落实。
- 原生 HTTP 路由、未命中路由、解码失败、gRPC stream 可能不经过同一链；分别检查过滤器或 interceptor。登录豁免须限于已确认 operation，不默认放行整个前缀。
- JWT 仅在项目采用时使用 v3 contrib 模块；认证身份写入项目认可的 context，不能用客户端 header 直接授予角色。token 校验通过不等于资源级权限通过。
- 请求体上限应在读取 body 前实施；HTTP deadline 不是 body 大小限制，也不是 socket 读写超时。流接口的限额和取消另外处理。

依据：[middleware 链](https://github.com/go-kratos/kratos/blob/v3.0.0/middleware/middleware.go)、[HTTP server](https://github.com/go-kratos/kratos/blob/v3.0.0/transport/http/server.go)、[gRPC server](https://github.com/go-kratos/kratos/blob/v3.0.0/transport/grpc/server.go)。本文仅提供源码核对要点，实际请求和兼容性仍须在获准任务中验证。
