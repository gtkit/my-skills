# 版本、迁移与代码生成

## 已核实基线

以下是 **2026-11-03 的源码/元数据核对结果**，不是本地编译或运行结论。后续涉及“最新”时重新查官方稳定 release；普通维护沿用项目锁定版本。

| 对象 | 核对结果 | 使用边界 |
|---|---|---|
| 核心 | [v3.0.0 release](https://github.com/go-kratos/kratos/releases/tag/v3.0.0)，提交 `668db92c2c001e9552594ba5a8aede8456af6d7e` | 使用稳定 tag，不把 main 或预发布当作稳定版 |
| 模块/Go | `github.com/go-kratos/kratos/v3`；[go.mod](https://github.com/go-kratos/kratos/blob/v3.0.0/go.mod) 声明 `go 1.25.0` | 实际项目和选用依赖可要求更高版本，不沿用上游 skill 的 Go 1.18 基线 |
| 官方服务模板 | [kratos-layout](https://github.com/go-kratos/kratos-layout/tree/59ad406328acba9a70c9e7f426720a75a89a6b9f)，该快照声明 Go 1.25.7 | 模板使用 Wire、Ent、Buf/AIP；这些不是核心强制依赖 |
| CLI | `github.com/go-kratos/kratos/cmd/kratos/v3` | 独立嵌套模块，不写成 `kratos/v3/cmd/kratos` |
| HTTP / errors 插件 | `github.com/go-kratos/kratos/cmd/protoc-gen-go-http/v3`、`github.com/go-kratos/kratos/cmd/protoc-gen-go-errors/v3` | 分别核对版本和生成物，不把核心 tag 当作每个子模块的可安装 tag |
| OTel / JWT | `github.com/go-kratos/kratos/contrib/otel/v3`、`github.com/go-kratos/kratos/contrib/middleware/jwt/v3` | 仅在项目使用时引入，各自核对 go.mod 和版本 |

本次查询 Go module proxy 时，上述 CLI、两个生成器及 OTel/JWT 子模块的 `@latest` 均返回 `v3.0.0-20261026152050-dd0fb7df1e32`。这只是当日解析结果，不是统一推荐版本，更不能自动替换项目锁定项。[CLI 元数据](https://proxy.golang.org/github.com/go-kratos/kratos/cmd/kratos/v3/@latest) 和 [OTel 元数据](https://proxy.golang.org/github.com/go-kratos/kratos/contrib/otel/v3/@latest) 为动态地址；复现应保留实际解析值和提交。

## 新建、维护和迁移要分开

- 新建：确认用户指定的真实目录和允许的脚手架方式，先检查目标是否存在。`kratos new` 会获取模板，目标存在时可删除并重建；在禁止 clone、缓存副本或覆盖目录的环境中不能调用。直接在获准原目录按核实模板编写必要文件，不创建临时项目再拷回。
- 维护：读取实际 `go.mod` / `go.work`、生成配置和最近同类实现。v2 项目继续按对应 v2 API 工作，不把本文 v3 符号套进去。
- 迁移：只有明确升级授权后才制定变更；范围包括模块、手写代码、生成器、生成物、配置、JSON、错误、调用方和回滚。禁止全仓字符串替换后就声称兼容。
- 最新版核对失败时说明无法确认；可用已知基线做标明版本的方案，不能宣称那就是当前最新。

## v2 → v3 的关键差异

以 [官方迁移说明](https://github.com/go-kratos/kratos/blob/v3.0.0/docs/migration/v2-to-v3_zh.md) 和锁定版本源码为准。

| 领域 | v3 的处理 | 需要保住的契约 |
|---|---|---|
| JSON | 核心 `encoding/json` 是标准库 JSON；`encoding/protojson` 注册名为 `protojson`；contrib `encoding/json/v3` 提供旧兼容行为 | 请求/响应 Content-Type、字段名、64 位整数、enum、默认值、未知字段和客户端解码 |
| 日志 | `kratos.Logger`、logging middleware 接收 `*slog.Logger`；旧 `log.Helper`、`log.Logger`、`log.Valuer` 等不能直接搬用 | 日志字段、级别、脱敏、trace 关联；确需同名包时按真实包名设置清晰别名 |
| JWT | 移至 `contrib/middleware/jwt/v3` | 算法、claims、签名校验与鉴权策略；迁移导入不等于权限验收 |
| OTel | `contrib/otel/v3/{tracing,metrics,log}` | provider、传播器、指标与导出配置；不继续使用不存在的核心 tracing/metrics 路径 |
| 熔断 | 默认实现不再依赖 Aegis；定制实现核对 `WithBreakerFactory` | 失败分类、隔离键和已有策略；不为了升级重写策略 |
| HTTP binding | 导出的 `transport/http/binding` 已移除；手写 URL 构造核对 `http.BuildPath`，绑定用 HTTP Context 对应方法 | 路径变量、query/body 来源与转义；旧生成物须用匹配生成器重建 |

更换 JSON codec 时，不能认为注册包之后 `application/json` 会自动获得原先的 ProtoJSON 行为；核对实际 codec 选择、Accept/Content-Type 与生成器输出。相同注册名的实现会互相覆盖，不在同一程序无意混装标准 JSON 和兼容 JSON。

## 生成前读什么

按实际存在的文件读取 `Makefile`、`buf.yaml`、`buf.lock`、`buf.gen*.yaml`、工具声明和 `go:generate` 指令。检查插件完整模块路径、固定版本、输入、输出、远程调用及命令副作用。不要把另一模板的命令当成本项目入口。

当前官方模板快照的 `make api` 执行 `buf generate --template buf.gen.yaml`，`make config` 使用 `buf.gen.config.yaml`。`make generate` 包含 `go generate ./...` **以及 `go mod tidy`**；`make init` 安装 `@latest` 工具。以上只是快照行为，不能在未检查本地目标或未获准变更依赖时直接执行。

| 入口 | 实际用途与前置条件 |
|---|---|
| 项目已有 Buf/protoc 入口 | 优先复用；核对每个插件输出、选项及依赖锁定，不把 Buf 配置自身的 `version: v2` 当作 Kratos 主版本 |
| `kratos proto client <实际 proto 路径>` | v3 CLI 调 protoc 生成消息、gRPC、HTTP、errors、OpenAPI 相关文件；按 proto 和插件产生实际输出。缺少它检查的插件时会调用 `kratos upgrade`，可能安装/升级 `@latest` 工具 |
| `kratos proto server <实际 proto 路径> --target-dir=<已有 service 目录>` | 创建 service 实现骨架；目标目录要存在，已有同名文件会跳过，不会补齐新增 RPC |
| Wire / `go generate` | 先读本地指令，再从 injector/provider 源生成；不是 Kratos CLI 的通用 `wire` 子命令。`go generate ./...` 会执行任意声明命令，不能当作无副作用检查 |

`proto client` 的参数错误或生成失败可能只打印错误；既查退出状态，也看输出和预期文件是否更新。插件/导入缺失时先定位，不能默认运行 `kratos upgrade` 修复。需要新增工具时确定获准安装的模块和精确版本，不能为省事一并升级全部工具。

生成后只检查授权范围的差异：proto 字段、生成文件头、import 主版本、RPC/HTTP 注册函数、OpenAPI 与客户端。不手改 `*.pb.go`、`*_http.pb.go` 或 `wire_gen.go` 掩盖源配置错误；同目录并非所有 `.go` 都是生成物，按文件头与生成入口判断。

## 来源与适用范围

- 参考 skill：[上游固定提交](https://github.com/LittleMoreInteresting/kratos-skills/tree/a66e9de063bcb8b6294652ea68ee9509f4f95fa0)。用户给出的 `.claude/skills/kratos-skills` 在本次远程树中不存在，实际入口是根目录 `SKILL.md`；其目标为 2.x+，不作为 v3 API 依据。
- 这里保留按需加载主题的思路，重写为本仓库的维护约定；未导入上游整套示例或 Claude 工具权限。保留 [上游 MIT 许可](../LICENSE)。
- 核心 API 参考固定到 v3.0.0，模板参考固定到上述提交；子模块和未来 release 必须独立复核。本文命令描述未经本地执行，不代表生成、编译、业务或迁移验证通过。
