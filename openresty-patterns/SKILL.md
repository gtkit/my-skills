---
name: openresty-patterns
description: OpenResty/ngx_lua 代码模式与实测 API 行为：执行阶段选择、shared dict、lrucache、resty.lock、cosocket 连接池、ngx.re、cjson、缓存击穿防护、worker 阻塞排查。编写或审查 Nginx 内 Lua 代码时使用。
---

# OpenResty 生产模式库

本文所有行为结论均在 `openresty/1.27.1.2`（LuaJIT 2.1.ROLLING、resty 0.29）上实测得出，
标注「实测」的即为真实运行结果；标注「文档值」的为官方文档默认值，本机未单独触发。

## 执行阶段与 API 可用性

**这是 OpenResty 的第一大坑**：不是所有阶段都能用 cosocket 和 `ngx.sleep`。

实测 `log_by_lua_block` 中调用 `ngx.socket.tcp()` 与 `ngx.sleep(0.001)`，两者都失败：

```
API disabled in the context of log_by_lua* while logging request
```

同一阶段实测可用：`ngx.req.get_headers()`、`get_uri_args()`、`get_method()`、`get_body_data()`、`ngx.timer.at`、shared dict、`ngx.re`、
`ngx.var.upstream_response_time`；不可用的还有 `ngx.req.read_body()`、`ngx.say`、`ngx.exit`。`header_filter_by_lua` 同此集合，只是 `ngx.exit` 可用且会返回。

所以**日志阶段不能上报数据到远端**。要在请求结束后做网络 IO，只有两条路：

```lua
-- ✅ 方案 A：log 阶段只写共享字典/队列，由定时器统一发送
log_by_lua_block {
    local d = ngx.shared.metrics
    d:incr("status_" .. ngx.status, 1, 0)   -- 注意第三个参数 init，见 references/shdict.md
}

-- ✅ 方案 B：init_worker_by_lua 里起定时器，在 timer 上下文做网络 IO
init_worker_by_lua_block {
    if ngx.worker.id() ~= 0 then return end   -- shared dict 全 worker 共享，只需一个 worker 上报
    local function flush(premature)
        if premature then return end          -- worker 退出时必须提前返回
        local sock = ngx.socket.tcp()         -- timer 上下文可以用 cosocket
        -- ... 上报
        local ok, err = ngx.timer.at(5, flush)
        if not ok then ngx.log(ngx.ERR, "timer 重建失败: ", err) end
    end
    ngx.timer.at(5, flush)
}
```

`init_worker_by_lua` 在每个 worker 执行一次（实测 2 个 worker 分别打出 `worker.id=0`/`1`），不加守卫就会起 N 份 timer；`ngx.timer.at` 超过 `lua_max_pending_timers`（默认 1024）返回 `nil, "too many pending timers"`（实测）。

| 阶段 | 用途 | cosocket |
|------|------|----------|
| `init_by_lua` | 加载模块、预编译（master 进程，fork 前） | 不可用 |
| `init_worker_by_lua` | 起 `ngx.timer`、worker 级初始化 | 本体不可用，timer 回调内可用 |
| `set_by_lua` | 计算变量，必须极短 | 不可用 |
| `rewrite_by_lua` | 改写 URI、内部跳转 | 可用 |
| `access_by_lua` | 鉴权、限流、WAF —— 拦截逻辑放这里 | 可用 |
| `content_by_lua` | 生成响应（与 proxy_pass 互斥） | 可用 |
| `header_filter_by_lua` | 改响应头 | 不可用 |
| `body_filter_by_lua` | 改响应体 | 不可用 |
| `log_by_lua` | 只做本地统计 | 不可用 |
| `balancer_by_lua` | 动态选上游、重试 | 不可用 |

`init`、`init_worker`（含 timer 回调）、`access`、`content`、`header_filter`、`log` 六行为本机实测，其余四行依据官方文档。

## 按任务读取

以下内容按任务读取，只读本次需要的文件；核心规则与审查清单已覆盖其结论。

| 任务 | 读 |
|---|---|
| 用 ngx.exit 终止请求 | `references/exit.md` |
| 用 ngx.shared.DICT：incr、get_stale、队列、容量 | `references/shdict.md` |
| 做网关缓存：lrucache + shdict + 回源、击穿防护与 resty.lock | `references/cache.md` |
| 用 cosocket / resty.redis，配连接池与 set_keepalive | `references/cosocket.md` |
| 写 ngx.re 正则或 cjson 序列化 | `references/data.md` |
| 排查 worker 阻塞、ngx.ctx 生命周期与模块级变量污染 | `references/blocking.md` |

## 审查清单

与 senior-openresty-engineer 的分工：那边负责工程视角与决策（出站方式选型、timer/worker 模型、容量与锁、可观测性、热更新），本文提供具体代码模式与逐条实测的 API 行为；与 Nginx 无关的纯 Lua/LuaJIT 问题见 senior-lua-engineer。

- [ ] `log_by_lua` / `header_filter` / `body_filter` 里没有 cosocket、`ngx.sleep`、`ngx.req.read_body`
- [ ] `ngx.exit` 均写成 `return ngx.exit(...)`；filter 阶段没有依赖 exit 终止执行的代码
- [ ] `init_worker` 中全局唯一的 timer 有 `ngx.worker.id() == 0` 守卫；回调首行处理了 `premature`
- [ ] 所有 `ngx.re.*` 带 `jo` 选项；用户输入不进入带 `o` 的正则
- [ ] 所有 cosocket 设了 `set_timeouts`，正常路径 `set_keepalive`、错误路径 `close`；改状态的连接按 `pool` 分池
- [ ] `resty.lock` 的每条返回路径都 `unlock`（含 `pcall(fetch)` 失败分支），且用独立 dict；拿不到锁的降级路径有上界（过期值 / 每秒配额 / 快速失败），不是无限回源
- [ ] `dict:incr` 传了 `init` 参数；没把 `dict:get` 的第二个返回值当 err；`get_stale` 只当尽力而为的兜底（后面仍有配额与快速失败），且没在它之前先用 `get` 碰过该 key
- [ ] 往 shared dict 存的是序列化后的字符串，不是 table / `cjson.null`
- [ ] `dict:set` 的 `forcible` 有观测；队列 `llen` 有上界
- [ ] 外部输入用 `cjson.safe` 解析；空数组用 `empty_array`/`empty_array_mt`；大整数走字符串
- [ ] 无 `os.execute` / `io.popen` / 同步磁盘 IO / LuaSocket
- [ ] 请求级状态在 `ngx.ctx`，模块级变量全部不可变
- [ ] 模块顶层没有依赖被反复执行的副作用代码（`require` 命中缓存后只执行一次，`access_by_lua_file` 才每请求重跑）
- [ ] 缓存空结果（字符串哨兵 + 短 TTL），防止不存在的 key 穿透
