---
name: openresty-patterns
description: OpenResty / ngx_lua 生产级模式库。当用户编写或审查 OpenResty、Nginx Lua、ngx_lua 代码，涉及执行阶段选择（access_by_lua / content_by_lua / log_by_lua / init_worker_by_lua）、共享字典 ngx.shared.DICT、lua-resty-lrucache、lua-resty-lock、cosocket（ngx.socket.tcp）、resty.redis、ngx.re 正则、cjson 序列化、API 网关、WAF、限流、缓存击穿防护、worker 阻塞排查时触发。触发关键词包括但不限于：OpenResty、ngx_lua、lua-nginx-module、shared dict、shdict、lrucache、resty.lock、cosocket、set_keepalive、ngx.re、cjson、access_by_lua、content_by_lua、log_by_lua、init_worker_by_lua、balancer_by_lua、Kong、APISIX、网关缓存、缓存击穿、Lua 阻塞。与 senior-openresty-engineer 的分工：那个 skill 提供工程视角与决策框架，本 skill 提供具体代码模式与已验证的行为细节。
---

# OpenResty 生产模式库

本文所有行为结论均在 `openresty/1.27.1.2`（LuaJIT 2.1.ROLLING、resty 0.29）上实测得出，
标注「实测」的即为真实运行结果。

## 执行阶段与 API 可用性

**这是 OpenResty 的第一大坑**：不是所有阶段都能用 cosocket 和 `ngx.sleep`。

实测 `log_by_lua_block` 中调用 `ngx.socket.tcp()` 与 `ngx.sleep(0.001)`，两者都失败：

```
API disabled in the context of log_by_lua* while logging request
```

所以**日志阶段不能上报数据到远端**。要在请求结束后做网络 IO，只有两条路：

```lua
-- ✅ 方案 A：log 阶段只写共享字典/队列，由定时器统一发送
log_by_lua_block {
    local d = ngx.shared.metrics
    d:incr("status_" .. ngx.status, 1, 0)   -- 注意第三个参数 init，见下文
}

-- ✅ 方案 B：init_worker_by_lua 里起定时器，在 timer 上下文做网络 IO
init_worker_by_lua_block {
    local function flush(premature)
        if premature then return end          -- worker 退出时必须提前返回
        -- timer 上下文可以用 cosocket
        local sock = ngx.socket.tcp()
        -- ... 上报
        local ok, err = ngx.timer.at(5, flush)
        if not ok then ngx.log(ngx.ERR, "timer 重建失败: ", err) end
    end
    ngx.timer.at(5, flush)
}
```

阶段选择：

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

本表中 `init`、`init_worker`（含其 timer 回调）、`access`、`content`、`header_filter`、`log`
六个阶段的 cosocket 可用性为本机实测；`set_by_lua`、`rewrite_by_lua`、`body_filter_by_lua`、
`balancer_by_lua` 四行依据官方文档，未在本机验证。

## 共享字典的真实行为

`ngx.shared.DICT` 跨 worker 共享，但有几个签名细节踩了就是 bug，全部实测确认：

```lua
local d = ngx.shared.cache

-- ① 只能存 string / number / boolean，存 table 直接失败
local ok, err = d:set("t", { a = 1 })
-- 实测：ok=nil, err="bad value type"  ← 必须自己序列化
d:set("t", require("cjson.safe").encode({ a = 1 }))

-- ② get 的第二个返回值是 flags，不是 err —— 拿它判断错误必然误判
d:set("k", "v", 0, 7)          -- 第 3 参 exptime(秒, 0=永不过期), 第 4 参 flags
local val, flags = d:get("k")
-- 实测：val="v", flags=7

-- ③ incr 对不存在的 key 返回 nil, "not found"，必须传第三个参数 init
local v, e = d:incr("absent", 1)
-- 实测：v=nil, e="not found"        ← 计数器场景最常见的坑
local v = d:incr("absent", 1, 0)
-- 实测：v=1                          ← 带 init 才会自动初始化

-- ④ set 返回三个值，forcible 表示是否为腾空间而淘汰了别人的 key
local ok, err, forcible = d:set("big", payload)
if forcible then
    ngx.log(ngx.WARN, "shared dict 容量紧张，发生了强制淘汰")
end

-- ⑤ exptime 支持小数秒
d:set("t", "v", 0.5)
```

`set` 与 `safe_set` 的区别：容量不足时 `set` 会淘汰其他 key（返回 `forcible=true`），
`safe_set` 则不淘汰、直接返回 `nil, "no memory"`。**缓存用 `set`，不能丢的数据用 `safe_set` 并处理失败**。

## 三级缓存 + 击穿防护

worker 级 `lrucache`（无锁、最快）→ 跨 worker `shared dict` → 回源，回源用 `resty.lock` 串行化。
`resty.lock`、`resty.lrucache` 均为 OpenResty 自带，实测可用。

```nginx
lua_shared_dict cache 100m;
lua_shared_dict locks  1m;      # lock 必须用独立的 dict
```

```lua
-- 模块级：lrucache 实例按 worker 复用，不要每请求 new
local lrucache = require "resty.lrucache"
local resty_lock = require "resty.lock"
local cjson = require "cjson.safe"

local lru = lrucache.new(200)          -- 200 个槽位，worker 私有
local dict = ngx.shared.cache

local _M = {}

function _M.get(key, ttl, fetch)
    -- L1：worker 内存，命中即返回，无锁
    local v = lru:get(key)
    if v then return v end

    -- L2：跨 worker 共享字典
    local raw = dict:get(key)
    if raw then
        local obj = cjson.decode(raw)
        lru:set(key, obj, ttl)
        return obj
    end

    -- L3：回源，用锁串行化，避免同一 key 并发穿透到后端
    local lock, err = resty_lock:new("locks")
    if not lock then
        ngx.log(ngx.ERR, "lock:new 失败: ", err)
        return fetch()                  -- 降级：拿不到锁机制就直接回源
    end

    local elapsed, err = lock:lock(key)
    if not elapsed then
        ngx.log(ngx.ERR, "lock:lock 失败: ", err)
        return fetch()
    end

    -- 双检：等锁期间别人可能已经填好了
    raw = dict:get(key)
    if raw then
        lock:unlock()
        local obj = cjson.decode(raw)
        lru:set(key, obj, ttl)
        return obj
    end

    local obj, ferr = fetch()
    if obj then
        local ok, serr, forcible = dict:set(key, cjson.encode(obj), ttl)
        if not ok then ngx.log(ngx.ERR, "写缓存失败: ", serr) end
        if forcible then ngx.log(ngx.WARN, "cache dict 发生强制淘汰") end
        lru:set(key, obj, ttl)
    end

    lock:unlock()                       -- 每条返回路径都必须 unlock
    return obj, ferr
end

return _M
```

要点：

- **`lock:unlock()` 必须覆盖所有分支**，包括双检命中和回源失败。漏一条路径就会把该 key 卡到锁超时。
- `resty_lock:new` 的 dict **不要和缓存共用**：缓存淘汰会把锁一起淘汰掉。
- 空结果也要缓存（缓存空值 + 短 TTL），否则不存在的 key 每次都穿透。

## 正则必须带 `jo` 选项

`ngx.re.*` 默认每次调用都重新编译正则。`j` = 启用 PCRE JIT，`o` = 缓存编译结果。
**漏了 `o`，高 QPS 下正则编译会成为热点**。

```lua
-- ✅ 实测：ngx.re.match("/api/v1/users/42", [[^/api/v(\d+)/users/(\d+)$]], "jo")
--         → m[1]="1", m[2]="42"
local m = ngx.re.match(uri, [[^/api/v(\d+)/users/(\d+)$]], "jo")
if m then
    local ver, id = m[1], m[2]
end

-- ❌ 缺 o：每请求重新编译
local m = ngx.re.match(uri, [[^/api/v(\d+)/users/(\d+)$]])
```

用 `[[ ]]` 长字符串写正则，避免 `\\d` 这类双重转义。

## cosocket 必须复用连接

用完 `close()` 等于每请求三次握手。要用 `set_keepalive` 放回连接池。

```lua
local redis = require "resty.redis"       -- OpenResty 自带，实测可用

local function with_redis(fn)
    local red = redis:new()
    red:set_timeouts(1000, 1000, 1000)    -- connect / send / read，必须设，默认无超时上限
    local ok, err = red:connect("127.0.0.1", 6379)
    if not ok then return nil, "connect: " .. err end

    local res, ferr = fn(red)

    if res then
        -- 归还连接：池大小 100，空闲 10s。注意 set_keepalive 之后不可再用 red
        local ok, kerr = red:set_keepalive(10000, 100)
        if not ok then ngx.log(ngx.ERR, "set_keepalive: ", kerr) end
    else
        red:close()                        -- 出错的连接不要放回池
    end
    return res, ferr
end
```

要点：

- **出错的连接不能 `set_keepalive`**：状态可能残留（比如 pipeline 没读完的响应），会污染下一个使用者。
- 用了认证或 `select db` 的连接，归还前状态就是脏的——要么固定用同一 db，要么 `close()`。
- `set_keepalive` 之后该对象不可再用。
- HTTP 出站用 `lua-resty-http`，**它不是 OpenResty 自带的**（实测 `require "resty.http"` 失败），需单独安装；只做内部子请求可以用 `ngx.location.capture`。

## JSON 一律用 cjson.safe

```lua
local cjson = require "cjson.safe"

-- 实测：非法输入返回 nil + 错误串，而不是抛异常
local obj, err = cjson.decode("{bad json")
-- obj=nil, err="Expected object key string but found invalid token at character 2"
if not obj then
    return ngx.exit(ngx.HTTP_BAD_REQUEST)
end
```

`require "cjson"` 的 `decode` 失败会抛异常，得包 `pcall`；`cjson.safe` 直接返回 `nil, err`。
**入口解析外部输入一律用 safe 版**。

Lua 的 table 无法区分空数组和空对象，编码时用 `cjson.empty_array` / `cjson.empty_object` 明确表达。

## 绝不阻塞 worker

一个 worker 用单线程事件循环跑成千上万个请求。**任何阻塞调用会冻结该 worker 上的全部请求**。

```lua
-- ❌ 这些都会阻塞整个 worker
os.execute("curl ...")
io.popen("...")
local f = io.open("/path"):read("*a")     -- 磁盘 IO 阻塞
require "socket"                           -- LuaSocket 是阻塞的
os.time() 之外的 os.date 频繁调用          -- 有系统调用开销

-- ✅ 对应的非阻塞替代
ngx.socket.tcp()                           -- 网络
ngx.timer.at(0, function() ... end)        -- 后台任务
ngx.sleep(0.01)                            -- 让出控制权（log 阶段不可用，见上文）
ngx.now()                                  -- 缓存的时间，不走系统调用
ngx.update_time()                          -- 需要精确时间时先刷新
```

外部命令一律移出请求路径：让 timer 去做，或者交给后端服务。

## 请求间的状态污染

Lua 模块只在 worker 内加载一次，**模块级变量被该 worker 的所有请求共享**。

```lua
-- ❌ 模块级可变状态：请求 A 写的值会被请求 B 读到
local _M = {}
local current_user          -- 灾难
function _M.set_user(u) current_user = u end

-- ✅ 请求级状态放 ngx.ctx（每请求独立，请求结束即回收）
function _M.set_user(u) ngx.ctx.user = u end
function _M.get_user()  return ngx.ctx.user end
```

模块级只放**不可变**的东西：配置常量、预编译正则、`lrucache` 实例、共享字典引用。

`ngx.ctx` 的开销不为零（每次访问走一次 metatable），热路径里反复读同一个值先取到局部变量。
内部跳转（`ngx.exec`、`ngx.location.capture`）会重建 `ngx.ctx`，跨跳转传值要用 `ngx.var` 或请求头。

## 审查清单

- [ ] `log_by_lua` / `header_filter` / `body_filter` 里没有 cosocket、`ngx.sleep`
- [ ] `ngx.timer` 回调首行处理了 `premature`
- [ ] 所有 `ngx.re.*` 带 `jo` 选项
- [ ] 所有 cosocket 设了 `set_timeouts`，正常路径 `set_keepalive`、错误路径 `close`
- [ ] `resty.lock` 的每条返回路径都 `unlock`，且用独立 dict
- [ ] `dict:incr` 传了 `init` 参数
- [ ] 没把 `dict:get` 的第二个返回值当 err
- [ ] 往 shared dict 存的是序列化后的字符串，不是 table
- [ ] `dict:set` 的 `forcible` 有观测
- [ ] 外部输入用 `cjson.safe` 解析
- [ ] 无 `os.execute` / `io.popen` / 同步磁盘 IO / LuaSocket
- [ ] 请求级状态在 `ngx.ctx`，模块级变量全部不可变
- [ ] 缓存空结果，防止不存在的 key 穿透
