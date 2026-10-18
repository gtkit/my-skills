# proto-first 契约检查

已有 proto 的项目只在 proto 中维护契约；OpenAPI、pb、gateway 和客户端是生成产物。先读项目的 proto/Buf 约定，不用 REST schema 替换它。

## 最小验证顺序

1. 固定基线 commit、proto package/服务、消费者版本、buf.yaml/buf.lock、插件及 marshaler 配置；确认 OpenAPI 输出是 v2 还是 3.x。
2. 用项目实际命令运行 lint、对批准基线的 breaking 检查和生成；禁止自行选择一个更近基线来隐藏破坏。缺少 buf/插件时报告未验证，不临时安装最新版。
3. 对生成结果做 diff，确认只来自本次 proto 变更；字段编号不可重用，删除字段时按 protobuf 规则保留编号/名称。导出 OpenAPI v2 时检查 definitions，不加入 3.x 的 components。
4. 同时测试 protobuf 二进制与 gateway JSON；二进制兼容不自动证明 JSON 或客户端源码兼容。验证旧/新服务与旧/新客户端允许的组合。
5. 用真实 gateway 响应核对下表；记录 marshaler 是否输出默认值、使用 proto 字段名、忽略未知字段、将枚举转成整数等配置，不假设库默认值。
6. 验证鉴权、metadata/header、HTTP 状态及错误 envelope 的实际映射。原始字节验签等独立 HTTP 入口按项目路由保持原始输入。

| 边界 | 最小样本与证据 |
|---|---|
| int64/uint64 | 包括大于 JavaScript 安全整数上限的 ID；ProtoJSON 序列化为十进制字符串，PHP/Vue 不强转 number |
| 字段 presence | 缺省、显式零值、非零值、null；区分 optional/oneof 与隐式 presence，核对生成 client 和 marshaler |
| enum | 已知值、新增值、未知数字/名称；检查客户端穷举和 JSON 名称/数字配置 |
| bytes/时间 | base64、Timestamp 格式和精度；不用普通 JSON 的假设代替 ProtoJSON 语义 |
| 字段演进 | 新字段、改名、删除、旧响应与旧请求；JSON 未知字段行为与二进制不同，必须实测 |
| 失败路径 | InvalidArgument、鉴权/授权失败、deadline、取消及下游失败；核对实际 HTTP/gRPC 映射 |

## 完成记录

记录唯一源路径、输入 commit、旧/新矩阵、生成命令/插件版本、breaking 基线、产物 diff、真实响应与客户端解析结果。仅有规范或静态 diff 时只能写“设计/审阅完成，运行未验证”。

规范依据：[ProtoJSON](https://protobuf.dev/programming-guides/json/)、[proto3 更新规则](https://protobuf.dev/programming-guides/proto3/#updating)、[Buf breaking](https://buf.build/docs/breaking/)、[OpenAPI 3.0→3.1](https://learn.openapis.org/upgrading/v3.0-to-v3.1.html)。具体工具能力以项目锁定版本为准。
