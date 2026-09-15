---
name: go-microservice
description: Go 微服务进程边界：优雅关闭与 k8s 发布时序、/livez /readyz、幂等键、http.Client 连接池、gRPC 拦截器/keepalive/status 映射、超时预算逐跳传播、服务发现。处理服务启停、探针、服务间调用时使用。
allowed-tools: "Read, Write, Edit, Bash, Glob, Grep"
---

# Go 微服务：生命周期与服务间通信

一个请求从入口到下游的"进程边界"问题：怎么停、怎么被探活、怎么防重放、怎么调别人。限流、熔断、重试、超时值怎么定归 go-stability-engineering；本文只放传播代码。

## 核心规则

1. `ListenAndServe` 与 `Shutdown` 的错误经 `errgroup` 收敛到 main 统一处理；goroutine 里 `Fatal` 会 `os.Exit` 跳过全部 defer，日志不刷、连接不关。
2. `http.Server` 必设 `ReadHeaderTimeout`（gosec G112）；`Shutdown` 超时 + `preStop` 时长 < `terminationGracePeriodSeconds`，否则被 SIGKILL 时仍有在途请求。
3. `/livez` 只回 200，不查任何依赖；`/readyz` 查依赖，每个依赖独立 2s 超时，响应只有 up/down。
4. 幂等记录是状态机 `none → processing → done(result)`：processing 返回 409，done 返回缓存结果；`SetNX` 失败就 `return nil` 是把"别人正在做"报告成"已成功"。
5. 出站 HTTP 复用一个 `http.Client`；`MaxIdleConnsPerHost` 默认只有 2；`resp.Body` 必须读尽再 Close，否则连接不能归还池。
6. gRPC 服务端 handler 返回的错误必须是 `status` 错误，`context` 错误映射到 `Canceled`/`DeadlineExceeded`，否则客户端只看到 `Unknown`。
7. 超时预算传绝对截止时刻（`ctx.Deadline()`），逐跳只减不增；剩余不足以覆盖本跳就直接失败，不发起注定超时的调用。
8. 网格（Istio）已接管重试/熔断/超时时，SDK 侧同类能力必须关掉，否则重试次数相乘、超时互相覆盖。

## 按任务读取

以下内容按任务读取，只读本次需要的文件；核心规则与审查清单已覆盖其结论。

| 任务 | 读 |
|---|---|
| 实现优雅关闭并与 k8s 发布时序对齐 | `references/shutdown.md` |
| 写 /livez 与 /readyz 探针 | `references/health.md` |
| 实现幂等键状态机 | `references/idempotency.md` |
| 配 http.Client 连接池与 otelhttp 传播 | `references/http-client.md` |
| 写 gRPC 拦截器、keepalive、status 映射、健康检查协议 | `references/grpc.md` |
| 实现超时预算逐跳传播 | `references/deadline.md` |

## 服务发现与网格选型

| 方案 | 适用 | 代价 | 注意 |
|---|---|---|---|
| k8s Service DNS | 全部在 k8s 内，HTTP 或 gRPC | 零 SDK | gRPC 长连接只解析一次，扩容后不均衡：用 headless Service + `dns:///` 客户端 LB，或服务端 `MaxConnectionAge` |
| Nacos | 混合部署（VM + k8s）、需配置中心 | SDK 心跳、注册中心高可用运维 | 与 k8s DNS 二选一，双注册会有两套健康视图 |
| etcd（自建注册） | 已有 etcd、需要 lease/watch 语义 | 自己写注册与摘除 | lease TTL 过短 → 网络抖动即大面积摘除 |
| Consul | 多数据中心、需要 KV 与健康检查一体 | Agent 部署 | gRPC 健康检查用 `grpc.health.v1` 对接 |
| Istio sidecar | 多语言、需要 mTLS/流量镜像/金丝雀 | 每跳 +1~3ms、Envoy 内存 | **关闭 SDK 侧重试/熔断/超时**（重试相乘 3×3=9 倍）；`preStop` 时序要考虑 sidecar 先退出导致出站失败 |

## 服务通信审查清单

- [ ] `http.Server` 四个超时字段都设了；`Shutdown` 超时 + preStop < `terminationGracePeriodSeconds`
- [ ] 没有任何 goroutine 里的 `logger.Fatal` / `os.Exit`；`errors.Is(err, http.ErrServerClosed)` 而非 `==`
- [ ] SIGTERM 后第一步是 readiness 翻红；有 `preStop sleep`
- [ ] WebSocket/SSE 连接有独立关闭路径（`RegisterOnShutdown` + hub）
- [ ] `/livez` 无依赖检查；`/readyz` 每依赖独立超时，响应不含 `err.Error()`
- [ ] 幂等：processing 返回 409，done 返回缓存结果；存储用 DB 唯一键
- [ ] 每个下游一个复用的 `http.Client`；`MaxIdleConnsPerHost` 按并发设；Body 读尽再 Close
- [ ] `http.NewRequestWithContext` 的 err 被检查；方法与状态码用常量
- [ ] gRPC handler 出口统一 `ToStatus`；两端 keepalive 一起配；健康检查协议已注册
- [ ] 下游调用用 `ForHop` 派生 ctx；HTTP 出站 `Inject`、入站 `Extract`
- [ ] 有 mesh 时 SDK 侧重试/熔断/超时已关闭
