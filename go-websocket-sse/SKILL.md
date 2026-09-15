---
name: go-websocket-sse
description: Go 长连接推送：WebSocket 与 SSE 选型、升级前鉴权、单读单写、actor Hub、背压、心跳与中间层超时、优雅关闭、Redis 水平扩展、Last-Event-ID 补发。实现或审查实时推送时使用。
allowed-tools: "Read, Write, Edit, Bash, Glob, Grep"
---

# Go WebSocket 与 SSE

长连接服务的选型、连接生命周期、Hub、背压、关闭时序与水平扩展。HTTP 服务器与关闭顺序的主线在 go-microservice，跨实例广播的 Redis 客户端在 go-redis-patterns，限流器实现在 go-stability-engineering。

## 核心规则

1. 单向推送选 SSE，双向选 WebSocket；SSE 上生产必须走 HTTP/2——HTTP/1.1 浏览器同域只有 6 条连接，多 tab 会互相饿死。
2. 鉴权、Origin 校验、连接上限判断全部在 `Upgrade` 之前；升级后只能发 Close 帧，返回不了 401/503。
3. 一条 gorilla 连接只允许一个 goroutine 写、一个 goroutine 读，违反直接 `panic("concurrent write to websocket connection")`。所有写走 writePump，Hub 不碰 `conn`。
4. Hub 状态（clients、users 索引）只在 `Run` goroutine 内读写，不加锁；对外只暴露 channel 与 atomic 计数。混用"部分加锁"就是读锁下写 map 的来源。`close(c.send)` 同样只发生在 `Run` goroutine（`remove` / `shutdown` / 注册拒绝）；readPump 只把关闭码交给 `Unregister`——在 readPump 里 `close(send)` 与 Hub 的 `deliver` 交错，就是 `panic: send on closed channel`（build 里有反证测试）。
5. 进入 Hub 的每个 channel 发送都 `select` 上 hub 的 `done`：Hub 退出后 readPump 的 defer `unregister` 不能永久阻塞。
6. ping 周期必须小于链路上所有中间层的空闲超时（Nginx `proxy_read_timeout` 默认 60s、AWS ALB idle 60s）；`SetReadLimit`、读写 deadline 缺一不可。
7. `http.Server.Shutdown` 不关闭、不等待被 hijack 的连接；Hub 关闭必须自己发 `1001 Going Away` 并等 Close 帧写出。
8. 入站消息统一封包 `{type, payload}`，按 type 白名单分发，每连接限速；不做"收到什么就广播什么"。
9. 升级后不要把 `c.Request.Context()` 直接传给 pump：ServeHTTP 返回即取消它，用 `context.WithoutCancel` 保留 trace 值。
10. SSE 端点所在 server 的 `WriteTimeout` 为 0，或每次写前 `ResponseController.SetWriteDeadline` 续期；`id:` 必须配 `Last-Event-ID` 读取与补发，否则字段无意义。
11. 每条 `Fprintf`/`Write` 的错误立即 `return`；客户端断开的第一信号是写失败，不是 ctx 取消。

## 按任务读取

以下内容按任务读取，只读本次需要的文件；核心规则与审查清单已覆盖其结论。

| 任务 | 读 |
|---|---|
| 写升级前鉴权、Origin 校验、连接上限 | `references/upgrade.md` |
| 实现 Hub：注册、广播、SendToUser、关闭 | `references/hub.md` |
| 写 readPump / writePump、心跳与 deadline | `references/pumps.md` |
| 实现 SSE：flush、Last-Event-ID 补发、WriteTimeout | `references/sse.md` |
| 估算连接数、fd 上限与内存 | `references/capacity.md` |

## 选型先行

| 需求 | 选择 | 理由 |
|---|---|---|
| 服务端单向推送（通知、进度、行情） | SSE | 纯 HTTP，过代理/网关/CDN 无需特殊配置，浏览器 `EventSource` 自带重连与 `Last-Event-ID` |
| 双向低延迟（聊天、协作、游戏） | WebSocket | 全双工，帧开销小 |
| 穿透企业代理 / 老旧中间层 | SSE 或长轮询 | 部分代理不转发 `Upgrade` |
| 二进制流 | WebSocket | SSE 只有 UTF-8 文本 |
| 每分钟一两次的低频更新 | 长轮询或普通轮询 | 长连接的 fd、心跳、粘性都白付 |

库：`gorilla/websocket`（2022-12 归档、2024 恢复维护，API 稳定、生态最广，本文示例基于它）；`github.com/coder/websocket`（原 nhooyr，所有操作接受 `ctx`，`wsjson` 直接读写 JSON，无 goroutine 泄漏面）；`gobwas/ws`（零拷贝、不绑定 goroutine-per-conn，配 epoll 做百万连接网关时才值得引入其复杂度）。

## 背压策略

`deliver` 里 `select default` 命中即缓冲满。四种处置，按业务选一种写死，不要运行时可配：

| 策略 | 做法 | 适用 |
|---|---|---|
| 断开（示例默认） | `h.remove(c)`，客户端重连后全量同步 | 聊天、协作等不能丢消息的场景，把"补数据"责任交给重连 |
| 丢最旧 | `<-c.send` 弹出一条再 `send <- msg` | 行情、位置等只关心最新值 |
| 合并 | 同 key 新值覆盖旧值（`map` + 定时 flush） | 仪表盘、计数器 |
| 降级拉取 | 发一条 `{"type":"resync"}` 让客户端走 REST | 消息体大、积压意味着客户端已落后太多 |

## 优雅关闭时序

与 go-microservice 的顺序衔接：`/readyz` 先翻红让 LB 摘流 → `srv.Shutdown(ctx)` 拒绝新升级并等普通请求 → 取消 Hub ctx，`shutdown` 给每个客户端 1001 并最多等 5s 让 Close 帧写出 → 等 `Run` 返回 → 关依赖。整段时长必须小于 k8s `terminationGracePeriodSeconds`。客户端拿到 1001 才会按退避重连，拿到 RST 会立即重连形成惊群。

## 水平扩展

- 多实例时 Hub 是单机内存，跨实例广播走 Redis Pub/Sub（客户端用法见 go-redis-patterns；它是 at-most-once，订阅者断线期间的消息丢失，不能丢就用 Redis Streams / Kafka / NATS JetStream）。每个实例订阅同一 channel，收到后本地 `Broadcast`。
- 在线状态集中存 Redis（`user_id → 实例 ID` 带 TTL，由心跳续期），`SendToUser` 先查所在实例再定向发布，避免全量广播。
- LB 不需要会话粘性：连接建立后就固定在一台机器；需要的是 LB idle timeout > ping 周期。

## 何时不该用长连接

| 场景 | 选择 | 理由 |
|---|---|---|
| 更新频率低于每分钟一次 | 轮询 | 心跳流量比业务流量还大 |
| 客户端是无浏览器的批处理 / 脚本 | Webhook 或队列 | 长连接的重连、心跳、粘性全是负担 |
| 移动端弱网 | SSE + 短 `retry` 或 MQTT | WebSocket 在网络切换时的半开连接靠 ping 才能发现，延迟 = pongWait |
| 需要严格 at-least-once 送达 | MQ + 拉取确认 | Hub 内存队列在进程重启时全丢，补发只能覆盖环形缓冲窗口 |
| 网关不支持 HTTP/2 | WebSocket 而非 SSE | 见核心规则 1 |

## 审查清单

- [ ] 鉴权、Origin、全局上限在 `Upgrade` 之前；`CheckOrigin` 不是 `return true`
- [ ] 每条连接只有 writePump 调用写方法；Hub 与业务代码 grep 不到 `conn.Write`
- [ ] Hub 的 map 只在 `Run` 内访问；对外计数用 atomic；无 `RWMutex`；`close(c.send)` 只在 Hub goroutine（`kick` 的调用方只有 `remove` / `shutdown` / 注册拒绝）
- [ ] `Register/Unregister/Broadcast/SendToUser` 全部 `select` 上 `done`
- [ ] `SetReadLimit`、`SetReadDeadline` + pong 续期、每次写前 `SetWriteDeadline`；pingPeriod < 所有中间层 idle timeout
- [ ] pump 拿到的是 `context.WithoutCancel(c.Request.Context())`
- [ ] Hub 关闭发 1001 并等待 Close 帧写出；主流程等 `Run` 返回后才关依赖
- [ ] 入站有封包、type 白名单、每连接限速；缓冲满的策略明确且写在 `deliver`
- [ ] 每用户上限、全局上限、建连速率三层都有；`ulimit -n` / `LimitNOFILE` 已调
- [ ] 指标：连接数、消息计数、握手失败、队列深度；label 无 user_id
- [ ] 多实例：跨实例广播走 Pub/Sub 或 Streams；在线状态在 Redis 且带 TTL
- [ ] SSE：Flush 不支持时直接 return；`WriteTimeout` 为 0 或每次续期；读 `Last-Event-ID` 并补发，非法/超前 ID 发 `reset`；`retry:` 带抖动；心跳注释行；写错误即 return；无 `Connection` 头
- [ ] `-race` 下有并发进出 + 广播 + 关闭的测试
