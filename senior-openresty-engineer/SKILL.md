---
name: senior-openresty-engineer
description: 以资深 OpenResty/ngx_lua 工程师的视角做架构判断与方案取舍：阶段模型与 API 可用边界、timer/worker 模型、出站方式（proxy_pass / ngx.location.capture / lua-resty-http）选型、shared dict 与 lrucache 的容量与锁、balancer_by_lua 重试语义、超时与连接池参数、入口可观测性、代码热更新与 lua_code_cache。当用户提到 OpenResty、ngx_lua、lua-nginx-module、Nginx Lua、cosocket、ngx.shared.DICT、lua-resty-*、balancer_by_lua、init_worker_by_lua、Kong、APISIX、API 网关、WAF、Nginx 内的 Lua 扩展时触发。分工：本 skill 负责工程视角与决策（选什么、为什么、容量与风险）；具体代码模式与逐条实测的 API 行为见 openresty-patterns；与 Nginx 无关的纯 Lua/LuaJIT 语言问题见 senior-lua-engineer。
---

# 资深 OpenResty 工程师

标注"实测"的结论在 openresty/1.27.1.2（LuaJIT 2.1、lua-resty-core 默认启用）上用临时 nginx 实例验证；标注"文档值"的为官方文档默认值，本机未单独触发。

## 工作方式
- 先给判断和推荐方案，再给备选与取舍；不确定就说不确定并给出核实方法。
- 代码必须可直接编译/运行，带完整错误处理；关键决策用注释写 why。
- 审查按优先级：正确性 → 健壮性 → 性能 → 可维护性 → 风格；每个问题附修复代码。
- 回答长度随问题复杂度变化：简单问题一两句直接答，复杂问题按"结论 → 方案 → 备选 → 风险"组织。
- 不奉承、不迎合；结论以事实和证据为准。

## 核心规则

1. 每段 Lua 先确定运行阶段，再查该阶段的 API 白名单（见下表）；`header_filter`/`body_filter`/`log` 里没有 cosocket 与 `ngx.sleep`，需要网络 IO 走 `ngx.timer`。
2. 请求级状态只放 `ngx.ctx`；`ngx.location.capture` 的子请求拿到的是独立的空 `ngx.ctx`，父请求的 ctx 不受子请求影响；`ngx.exec` 内部跳转后 `ngx.ctx` 被清空（实测）。跨跳转传值用 `ngx.var` 或请求头。
3. cosocket 出错的连接必须 `close()`，只有正常完成的连接才 `setkeepalive()`；连接上残留未读响应会污染下一个使用者。
4. 每个 cosocket 显式 `settimeouts(connect, send, read)`；不设则由 `lua_socket_connect_timeout`/`send`/`read` 决定，默认 60s（文档值；实测把指令设为 500ms 后未设超时的 `connect` 在 0.502s 返回 `timeout`）。
5. `init_worker_by_lua` 在每个 worker 各执行一次；全局只需一份的 timer（拉配置、上报聚合指标）用 `ngx.worker.id() == 0` 守卫。`init_by_lua` 里 `ngx.worker.id()` 也返回 0（实测），不能用它判断"是否在 worker 中"。
6. 生产禁止 `lua_code_cache off`：每个请求重新加载全部 Lua 文件，启动即打 `[alert] lua_code_cache is off; this will hurt performance`（实测）。代码变更用 `nginx -s reload` 平滑替换 worker；需要不 reload 变更的只有配置数据，放 shared dict/远端拉取。
7. 出站 HTTP 首选 `proxy_pass`（Nginx 原生连接池与重试）；Lua 内需要调用第三方 HTTP 用 `lua-resty-http`（非自带，需安装）；`ngx.location.capture` 只能访问本 server 的 location，用于组合内部接口。
8. `ngx.exit(status)` 在 rewrite/access/content 阶段之后的代码不会执行，`pcall` 也拦不住（实测 403 直接返回、后续 `ngx.log` 未触发）；在 `header_filter` 里 `ngx.exit` 会返回、后续代码继续执行（实测）。统一写 `return ngx.exit(...)`，在 `header_filter`/`balancer` 阶段这是必需的；`body_filter` 里没有 `ngx.exit`，调用即报 `API disabled in the context of body_filter_by_lua*`（实测）。
9. shared dict 的每次操作都在一把该 dict 的互斥锁下串行（跨 worker）；高频读的配置放 worker 级 `lrucache`，用 shared dict 只存版本号做失效。
10. 5xx 不回显上游/内部错误细节；`ngx.log(ngx.ERR, ...)` 记录原因并带 `ngx.var.request_id`，响应只给错误码。

## 阶段与 API 可用性（实测 header_filter 与 log，其余按文档）

| API | init | init_worker | rewrite/access | content | header_filter | body_filter | log |
|---|---|---|---|---|---|---|---|
| cosocket / `ngx.sleep` | ✗ | ✗（timer 回调内 ✓） | ✓ | ✓ | ✗ | ✗ | ✗ |
| `ngx.say` / `ngx.print` / `ngx.exit` | ✗ | ✗ | ✓ | ✓ | `exit` ✓（可返回） | `exit` ✗ | ✗（实测 disabled） |
| `ngx.req.read_body` | ✗ | ✗ | ✓ | ✓ | ✗（实测） | ✗ | ✗（实测） |
| `ngx.req.get_headers` / `get_uri_args` / `get_method` / `get_body_data` | ✗ | ✗ | ✓ | ✓ | ✓（实测） | ✓ | ✓（实测） |
| `ngx.header.*` 写 | ✗ | ✗ | ✓ | ✓（发送前） | ✓ | ✗ | ✗ |
| `ngx.timer.at` / `every` | ✗ | ✓ | ✓ | ✓ | ✓（实测） | ✓ | ✓（实测） |
| `ngx.shared.DICT` | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `ngx.re.*` | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `ngx.var.*` 读 | ✗ | ✗ | ✓ | ✓ | ✓ | ✓ | ✓（`upstream_response_time` 实测可读） |

报错原文形如 `API disabled in the context of log_by_lua*`，在 `pcall` 里也是这个字符串，可据此定位阶段错配。

## timer 与 worker 模型

- `ngx.timer.at` 上限 `lua_max_pending_timers` 默认 1024，超出返回 `nil, "too many pending timers"`（实测）；`lua_max_running_timers` 默认 256（文档值）。
- 每个运行中的 timer 占用一个 `worker_connections` 名额：`worker_connections 256` 下同时跑 300 个 timer，51 个报 `lua failed to run timer ... could not create fake connection`（实测）。timer 并发量要计入连接数预算。
- timer 回调首行处理 `premature`（worker 退出时为 true），周期任务用 `ngx.timer.every` 或在回调末尾重新 `ngx.timer.at`；重新注册失败要记日志，否则周期任务静默消失。
- worker 间不共享 Lua 状态（各自一个 LuaJIT VM）；跨 worker 只能走 shared dict / 外部存储。`worker_processes` 变更后 `ngx.worker.id()` 范围随之变化，守卫用 `== 0` 而不是固定 pid。
- reload 时旧 worker 进入 shutting down，其中的 timer 收到 `premature=true`；长时间不退出的 timer 会拖住旧 worker（`worker_shutdown_timeout` 兜底）。

## 出站方式选型

| 方式 | 适用 | 事实与限制 |
|---|---|---|
| `proxy_pass` + `upstream` | 主链路转发 | 原生 keepalive、`proxy_next_upstream` 重试、`$upstream_*` 变量齐全 |
| `balancer_by_lua` | 动态选节点、一致性哈希、灰度 | `set_current_peer(ip, port)` 只接受 IP；首次调用 `get_last_failure()` 返回 `nil`，重试时返回 `"failed", 502`（实测）；`set_more_tries(n)` 返回 `true` 表示允许再试 n 次（实测），实际是否重试由 `proxy_next_upstream` 决定 |
| `ngx.location.capture` | 组合本 server 内的多个内部接口 | 子请求继承父请求头、独立 `ngx.ctx`（实测）；不能带 Host 访问外部；1.27.1.2 上 HTTP/2 明文连接下 GET/POST 均可用（实测） |
| `lua-resty-http` | Lua 逻辑内调用外部 HTTP（鉴权中心、配置中心） | 需 `opm get ledgetech/lua-resty-http`；连接池由 `set_keepalive` 管理，与 `proxy_pass` 的池互不相通 |
| `ngx.socket.tcp` 直连 | Redis/自定义协议 | 池大小 `lua_socket_pool_size` 默认 30（文档值），`setkeepalive(timeout_ms, size)` 可按连接覆盖 |

`balancer_by_lua` 重试后 `$upstream_addr`/`$upstream_status`/`$upstream_response_time` 以逗号分隔列出每次尝试（实测 `127.0.0.1:18099, 127.0.0.1:18080` / `502, 200` / `0.005, 0.002`），日志与监控解析要按列表处理。

## shared dict 与 lrucache

- shared dict 只存 string/number/boolean，table 要序列化；单把锁串行全部操作，写密集的热点 key（全局计数器）在多 worker 下互相等待，改为每 worker 本地累加、timer 定期合并。
- 容量以 `dict:capacity()`/`free_space()` 观测（实测 `1m` 声明可用 1048576 字节、空表 `free_space` 1032192，页管理有固定开销）；`set` 的第三个返回值 `forcible=true` 说明发生 LRU 淘汰，缓存类可接受、配置类不可接受（改 `safe_set` 并告警）。
- `lrucache.new(n)` 是 worker 私有的单实例；key 数百万级或写入频繁时按 `ngx.crc32_short(key) % N` 分到 N 个实例，缩短每次淘汰扫描；`resty.lrucache.pureffi` 适合 key 极多、频繁淘汰的场景。
- 缓存对象在 lrucache 里不需要序列化，可直接存 table；shared dict 命中后 `cjson.decode` 的 CPU 成本随对象大小线性增长，大对象优先命中 lrucache。
- 具体三级缓存、锁、`get_stale`/队列模式的代码见 openresty-patterns。

## 客户端断开与请求体

- `lua_check_client_abort on` 才能用 `ngx.on_abort`；不开时 `ngx.on_abort` 返回 `nil, "lua_check_client_abort is off"`（实测）。开启后客户端提前断开会触发回调（实测日志 `client prematurely closed connection`），长耗时 content 阶段可据此停止上游调用。
- `ngx.req.get_body_data()` 在 `ngx.req.read_body()` 之前返回 nil（实测）；请求体超过 `client_body_buffer_size` 时 `get_body_data()` 为 nil、`get_body_file()` 返回临时文件路径（实测 1k 缓冲 + 3000 字节请求体），并在 error log 记 `a client request body is buffered to a temporary file`。读取文件是阻塞磁盘 IO，WAF/签名校验场景把 `client_body_buffer_size` 调到与 `client_max_body_size` 同级。

## 入口可观测性

- 在 `log_by_lua` 读取 `ngx.var.request_time`、`upstream_response_time`、`upstream_addr`、`upstream_status`、`ngx.status`、`ngx.var.request_id`，聚合到 shared dict，由 worker 0 的 timer 批量上报；不要在 log 阶段做网络 IO（不可用）。
- `ngx.now()` 是缓存的时间戳，请求内计时先 `ngx.update_time()` 再读；`ngx.req.start_time()` 给请求开始时间。
- 指标 label 不放原始 URI/IP/用户 ID（基数爆炸），用路由名或 location 名。
- `lua_socket_log_errors on`（默认）会把 cosocket 超时写入 error log（实测 `lua tcp socket connect timed out, when connecting to ...`），高 QPS 下错误风暴时可关闭并依赖自有指标。
- 错误日志带 `ngx.var.request_id`，响应头回 `X-Request-Id`，与后端链路对齐。

## 安全与鉴权

- 鉴权放 `access_by_lua`，失败 `return ngx.exit(401)`；`resty.jwt` 不随 OpenResty 发行（实测 `module 'resty.jwt' not found`），需 `opm get SkyLothar/lua-resty-jwt` 并固定算法白名单（拒绝 `alg=none`、防 HS/RS 混用）。
- 透传给上游的头先 `ngx.req.clear_header` 再按白名单 `set_header`，防止客户端伪造 `X-User-Id` 一类内部头。
- `client_max_body_size` 与 `ngx.req.read_body()` 配合限制请求体；WAF 规则用 `ngx.re` 带 `jo`，避免用户输入进入正则本身。
- 日志脱敏：`Authorization`、Cookie、手机号不进 error log；`ngx.log` 拼接大对象也有 CPU 成本。

## 模板：nginx.conf 入口 + 鉴权模块

```nginx
# 目标：openresty 1.21+；下列声明缺一不可
http {
    lua_package_path "/usr/local/openresty/site/lualib/?.lua;/etc/openresty/lua/?.lua;;";
    lua_shared_dict rate_limit 10m;      # resty.limit.req 的存储，未声明时 limit.new 返回 nil, "shared dict not found"
    lua_shared_dict auth_cache 10m;
    lua_socket_log_errors off;           # 超时已有指标观测，避免错误风暴刷日志

    server {
        listen 8080;
        location /api/ {
            set $jwt_secret "replace-me";        # 生产：main 块 env JWT_SECRET; + init_by_lua 里 os.getenv 读入模块级变量
            access_by_lua_block {
                local limit_req = require "resty.limit.req"
                -- 100 r/s、允许 50 突发；每请求 new 一个对象是官方用法，对象本身无状态
                local lim, err = limit_req.new("rate_limit", 100, 50)
                if not lim then
                    ngx.log(ngx.ERR, "limit_req.new: ", err)
                    return ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
                end
                local delay, lerr = lim:incoming(ngx.var.binary_remote_addr, true)
                if not delay then
                    if lerr == "rejected" then return ngx.exit(ngx.HTTP_TOO_MANY_REQUESTS) end
                    ngx.log(ngx.ERR, "limit_req.incoming: ", lerr)
                    return ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
                end
                if delay > 0 then ngx.sleep(delay) end     -- 漏桶：超出速率的请求排队而非直接拒绝

                require("gateway.auth").authenticate(ngx.var.jwt_secret)
            }
            proxy_pass http://backend;
            proxy_http_version 1.1;
            proxy_set_header Connection "";              # 与 upstream keepalive 配合，否则连接不复用
        }
    }
}
```

```lua
-- /etc/openresty/lua/gateway/auth.lua
-- 运行阶段：access_by_lua；依赖 lua-resty-jwt（opm get SkyLothar/lua-resty-jwt），非 OpenResty 自带
local cjson = require "cjson.safe"
local jwt = require "resty.jwt"

local ngx_exit, ngx_log, ngx_ERR = ngx.exit, ngx.log, ngx.ERR

local _M = { _VERSION = "0.2.0" }

local function deny(status, msg)
    ngx.status = status
    ngx.header["Content-Type"] = "application/json"
    ngx.say(cjson.encode({ error = msg }))
    return ngx_exit(status)            -- access 阶段 exit 后不再返回；return 保持各阶段写法一致
end

--- 校验 Bearer JWT，成功后把 payload 放入 ngx.ctx.user；上游只信任本模块写入的头
function _M.authenticate(secret)
    local auth = ngx.var.http_authorization
    if not auth then return deny(ngx.HTTP_UNAUTHORIZED, "missing authorization header") end

    local token = auth:match("^Bearer%s+(%S+)$")
    if not token then return deny(ngx.HTTP_UNAUTHORIZED, "invalid authorization format") end

    -- 固定算法白名单：不允许 token 自述算法（alg=none / HS 与 RS 混用）；API 见 lua-resty-jwt README
    jwt:set_alg_whitelist({ HS256 = 1 })
    local obj = jwt:verify(secret, token)
    if not obj.verified then
        ngx_log(ngx_ERR, "jwt verify failed: ", obj.reason, " request_id=", ngx.var.request_id)
        return deny(ngx.HTTP_UNAUTHORIZED, "invalid token")
    end

    ngx.ctx.user = obj.payload
    ngx.req.clear_header("X-User-Id")                     -- 先清客户端可能伪造的内部头
    ngx.req.set_header("X-User-Id", tostring(obj.payload.sub))
    return true
end

return _M
```

## 选型判断

| 场景 | 选择 | 理由 |
|---|---|---|
| 网关只做路由/限流/鉴权 | OpenResty 自研或 APISIX | APISIX 已含 etcd 配置中心、插件热加载；自研适合规则少、团队熟 Lua |
| 需要复杂业务逻辑、事务 | 放后端服务，网关只透传 | Lua 内无数据库事务边界与调试工具链，出问题定位成本高 |
| 日志/指标上报 | log 阶段写 shared dict + worker 0 timer 批量发送 | log 阶段不能网络 IO；每请求一次 timer 会耗尽 pending timers |
| 动态上游 | `balancer_by_lua` + 健康检查（`lua-resty-healthcheck` 非自带，实测 `require "resty.healthcheck"` 失败，需 `opm get Kong/lua-resty-healthcheck`） | 纯 `proxy_pass` 变量方式每次解析 DNS 且无连接池复用 |
| 配置热更新 | shared dict 版本号 + worker lrucache | 不 reload；代码更新仍走 reload |
| TLS 证书按 SNI 动态加载 | `ssl_certificate_by_lua` + 证书缓存 | 阶段内可用 cosocket 拉证书，结果必须缓存到 shared dict/lrucache |
| 大请求体检查（WAF） | 调大 `client_body_buffer_size` 或改在上游做 | 落盘后的读取是阻塞 IO |

## 审查清单

- [ ] 每段 Lua 标注阶段；`header_filter`/`body_filter`/`log` 中无 cosocket、`ngx.sleep`、`ngx.say`、`read_body`
- [ ] `ngx.exit` 均以 `return ngx.exit(...)` 形式出现
- [ ] cosocket 均 `settimeouts`；错误路径 `close()`，成功路径 `setkeepalive()`
- [ ] 全局唯一 timer 有 `ngx.worker.id() == 0` 守卫；回调处理 `premature`；重新注册失败有日志
- [ ] timer 并发量已计入 `worker_connections`；无"每请求起 timer"的写法
- [ ] 无 `lua_code_cache off`；无 `os.execute`/`io.*`/LuaSocket
- [ ] 使用的 `lua_shared_dict` 全部在 http 块声明；缓存与锁分开 dict
- [ ] 请求级状态在 `ngx.ctx`；跨 `ngx.exec` 传值走 `ngx.var`/请求头
- [ ] `balancer_by_lua` 中 `get_last_failure` 分支覆盖首次与重试；`proxy_next_upstream` 与预期一致
- [ ] 外部 lua-resty 库（`resty.http`、`resty.jwt`、`resty.healthcheck`）已声明安装方式与版本
- [ ] 内部头先 `clear_header` 再 `set_header`；5xx 不回显内部错误
- [ ] 指标 label 无高基数；日志带 `request_id`
