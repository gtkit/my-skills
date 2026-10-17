# 跨语言后端反例

## Go

- `go test -race` 只能观测到执行过的 Go 内存访问；仍需验证数据库原子性、跨进程部署、消息重投和业务不变量。
- goroutine 必须有取消、退出和错误传播路径；HTTP server、worker、stream 和 shutdown 要一起验证。
- 根据任务路由 `go-review`、`go-enterprise-quality`、`go-testing`、`go-data-consistency`、`go-security`、`go-database-patterns`、`go-stability-engineering`、`go-microservice`。

## Node.js

- 单线程不等于没有竞态：await 之间共享状态会交错；cluster、worker_threads、队列消费者和多实例仍需持久化锁/唯一约束。
- 检查 AbortSignal、Promise rejection、事务 session、流 backpressure、事件监听清理、优雅关闭和重试是否重复副作用。
- 按项目选择 TypeScript strict、ESLint、测试 runner、契约测试、依赖/secret 扫描和真实数据库集成测试；不要以 mock Promise 代替数据库语义。

## PHP

- PHP-FPM 请求隔离不提供跨请求幂等或锁；队列 worker、Octane 常驻进程、缓存和多实例会重新引入共享状态。
- 检查 PDO/Laravel 事务闭包、异常传播、队列重试、`afterCommit`、模型事件、质量/金额精度、授权策略、mass assignment、CSRF 和 N+1。
- 使用 PHPStan/Psalm、框架测试、真实数据库/队列和故障注入；不能因每次请求结束就假设没有资源泄漏或重复任务。

## 通用失败序列

对每个有副作用的接口至少回放：并发首请求、客户端超时后重试、响应丢失后重试、进程重启、外部依赖超时、回调乱序/重复、同幂等键不同 body、跨租户资源 ID、过期状态和非法金额。记录每一步数据库、事件、支付和响应状态，检查最终可对账。
