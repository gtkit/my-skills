# 分层、依赖装配与数据访问

## 从现有调用链开始

先追踪一个真实接口：协议与生成代码 → server 注册 → service 方法 → 用例 → 数据实现；再单独查看 Go import 关系。下表是 [官方模板快照](https://github.com/go-kratos/kratos-layout/tree/59ad406328acba9a70c9e7f426720a75a89a6b9f) 的职责定位，不是目录重构命令。

| 常见位置 | 修改什么 | 避免什么 |
|---|---|---|
| `api/` | 协议、HTTP 注解及对应生成物 | 把数据库实体直接充当外部请求/响应 |
| `internal/server/` | HTTP/gRPC 创建、配置与服务注册 | 把业务状态转换放入协议中间件 |
| `internal/service/` | 协议参数转换、调用用例、响应转换 | 为两种协议复制两套业务和权限规则 |
| `internal/biz/` | 业务规则、用例、由使用方需要决定的 Repo 契约 | 为尚未出现的实现提前加通用框架 |
| `internal/data/` | 持久化、外部客户端、Repo 实现和资源清理 | 把 ORM 查询错误或内部数据直接返回外部调用方 |
| `internal/conf/` 与 `configs/` | 配置类型/源、示例与说明 | 修改字段却漏掉生成、加载或回落逻辑 |
| `cmd/<实际入口>/` | 装配、应用生命周期、初始化失败处理 | 假定入口永远叫 `server` 或 `main` |

常见模式由 biz 声明消费的 Repo 接口、data 实现；运行时虽调用 data，biz 不必 import data。目标项目若已有其他边界，按它实现。官方模板也存在 biz 引用 API enum 的选择，不能声称所有 Kratos 项目严格禁止这种依赖；要解耦时先解释实际影响与所需授权。

## 增加一个用例

1. 读取项目同类用例，确认模型、错误、用户/租户来源、状态转换与持久化契约。业务规则来自需求或已有实现，不从 Todo 示例发明规则。
2. Repo 方法按调用方实际需要定义。读写继续传入 `context.Context`；记录不存在、冲突、重复请求、影响行数与依赖故障的真实语义。
3. service 保留外部 DTO 与内部对象的转换；proto 的零值、nil、显式清空和更新掩码不能因转换丢失区别。不要依赖两个 enum 当前数值相同就随意强转。
4. 当新增能力真正需要事务或幂等时，复用现有边界和事务载体，不为所有方法引入新的通用事务框架。
5. 根据实际装配补 provider/构造参数，再逐项确认要求的 HTTP/gRPC 注册和调用方。

## Wire 是一种装配方式

先检查项目是否使用 Wire。已有手工构造或其他 DI 方式时继续沿用；框架本身不要求 Wire。

使用 Wire 的项目检查：

- provider 返回类型能否满足真实构造参数；接口绑定是否通过返回接口或明确的 `wire.Bind` 完成；不要同时添加重复 provider。
- `wire.Build`、各 `ProviderSet`、injector 的 build tag 与生成入口是否匹配；不要猜测某个目录存在 `go:generate`。
- 资源构造函数的 `error` 与 `func()` cleanup 是否进入生成链；失败时此前创建的资源由谁释放；成功后谁在应用退出时调用 cleanup。
- 生成失败先检查缺失/重复 provider、类型别名与 import、build tag、工具版本。修复源定义后重新生成，不直接修补 `wire_gen.go`。

参考模板的 [injector](https://github.com/go-kratos/kratos-layout/blob/59ad406328acba9a70c9e7f426720a75a89a6b9f/cmd/server/wire.go)、[启动与 cleanup](https://github.com/go-kratos/kratos-layout/blob/59ad406328acba9a70c9e7f426720a75a89a6b9f/cmd/server/main.go)。不要复制固定入口路径到目标项目。

## 数据和资源归属

- 长生命周期 DB、Redis、RPC 客户端按项目装配方式共享；不要在每个请求重新初始化连接池，也不要引入不可替换的包级全局依赖。
- 一次事务内的 Repo 操作必须使用同一事务/连接。检查嵌套调用有没有回落到全局 DB；记录提交失败、结果不明、重试与回滚错误的策略。
- HTTP 超时或客户端取消不证明事务未提交；非幂等写入不能因为 transport 报错就盲目重试。跨服务可靠事件沿用现有 outbox/幂等方案，别用请求后的 goroutine 代替持久化交付。
- 可变字段只按已确认白名单写入；权限/租户约束要进入实际查询或写入条件，不能只相信来自客户端的 ID。
- DB migration、自动建表与测试容器是独立副作用。模板提供 `auto_migrate` 不代表可在目标生产环境开启；未经授权不拉镜像、创建容器或改数据库。

具体 SQL、锁、缓存一致性和消息投递遵循目标项目及可用专项技能；本文件只连接 Kratos 的用例和装配边界。

## 核验范围

获准实现后的针对性核验关注：用例边界、协议转换、Repo 错误、事务绑定、构造失败释放、退出 cleanup 和要求的协议入口。fake Repo 只能证明用例调用与分支，不能证明真实数据库事务、约束、权限或服务发现。

源码依据包括模板的 [biz](https://github.com/go-kratos/kratos-layout/blob/59ad406328acba9a70c9e7f426720a75a89a6b9f/internal/biz/todo.go) 与 [data](https://github.com/go-kratos/kratos-layout/blob/59ad406328acba9a70c9e7f426720a75a89a6b9f/internal/data/data.go)。这些参考已做源码核对，本文没有声称执行过模板。
