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
    d:incr("status_" .. ngx.status, 1, 0)   -- 注意第三个参数 init，见下文
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

## `ngx.exit` 的真实语义

```lua
-- access / content 阶段（实测）
ngx.exit(403)
ngx.log(ngx.ERR, "never printed")          -- 不会执行：exit 让出协程且不再恢复
local ok = pcall(function() ngx.exit(403) end)
                                           -- pcall 也拦不住：响应仍是 403，后续代码不执行
-- header_filter 阶段（实测）
ngx.exit(500)
ngx.log(ngx.ERR, "printed")                -- 会执行：filter 阶段 exit 只是设置状态后返回
```

统一写 `return ngx.exit(...)`：在 access/content 里是可读性，在 header_filter/balancer 里是正确性。
`body_filter` 里根本没有 `ngx.exit`——调用即报 `API disabled in the context of body_filter_by_lua*`（实测）。
`ngx.exit(ngx.OK)` 只结束当前阶段的 Lua 代码、不结束请求（文档）。

## 共享字典的真实行为

`ngx.shared.DICT` 跨 worker 共享，但有几个签名细节踩了就是 bug，全部实测确认：

```lua
local d = ngx.shared.cache

-- ① 只能存 string / number / boolean，存 table 或 cjson.null 直接失败
local ok, err = d:set("t", { a = 1 })
-- 实测：ok=nil, err="bad value type"  ← 必须自己序列化（cjson.null 是 userdata，同样报错，实测）
d:set("t", require("cjson.safe").encode({ a = 1 }))

-- ② get 的第二个返回值是 flags，不是 err —— 拿它判断错误必然误判
d:set("k", "v", 0, 7)          -- 第 3 参 exptime(秒, 0=永不过期), 第 4 参 flags
local val, flags = d:get("k")
-- 实测：val="v", flags=7

-- ③ incr 对不存在的 key 返回 nil, "not found"，必须传第三个参数 init
print(d:incr("absent", 1))     -- 实测：nil  not found        ← 计数器场景最常见的坑
print(d:incr("absent", 1, 0))  -- 实测：1                     ← 带 init 才会自动初始化
d:set("s", "abc"); print(d:incr("s", 1))   -- 实测：nil  not a number（字符串值不能 incr）

-- ④ set 返回三个值，forcible 表示是否为腾空间而淘汰了别人的 key
local ok, err, forcible = d:set("big", payload)
if forcible then ngx.log(ngx.WARN, "shared dict 容量紧张，发生了强制淘汰") end

-- ⑤ exptime 支持小数秒；ttl/expire 可查改剩余时间
d:set("t", "v", 0.5); print(d:ttl("t"), d:ttl("nope"), d:expire("t", 5))   -- 实测：剩余秒数  nil not found  true

-- ⑥ 列表操作：一个 key 要么是标量要么是列表，混用报错
print(d:lpush("q", "a"), d:lpush("q", "b"))          -- 实测：1  2（返回长度）
print(d:llen("q"), d:rpop("q"), d:lpop("q"), d:rpop("q"))   -- 实测：2  a  b  nil
d:lpush("q", "x"); print(d:get("q"), d:incr("q", 1))   -- 实测：nil value is a list / nil not a number
d:set("q", "s"); print(d:llen("q"))        -- 实测：set 覆盖后 → nil  value not a list
print(d:lpush("q2", {}))                   -- 实测：nil  bad value type

-- ⑦ get_stale 只能拿到"尚未被清理"的过期值，第三个返回值是 stale 标记
print(d:get_stale("expired"))              -- 实测（还没人用 get 碰过该 key）：v  5  true
print(d:get("expired"), d:get_stale("expired"))   -- 实测：get 返回 nil 之后，get_stale 也拿不到了
-- 对其他 key 的 set、内存压力下的写入（实测写满 dict 后即为 nil）、flush_expired(0)/flush_all 都会清掉它
-- 想让过期值能当降级兜底，就必须一开始就用 get_stale 读，别先 get 一次（见下节三级缓存）
print(d:capacity(), d:free_space())        -- 实测：1m 声明 → 1048576  1032192（页管理有固定开销）
```

`set` 与 `safe_set` 的区别：容量不足时 `set` 会淘汰其他 key（返回 `forcible=true`），
`safe_set` 则不淘汰、直接返回 `nil, "no memory"`。**缓存用 `set`，不能丢的数据用 `safe_set` 并处理失败**。
`add` 对已存在 key 返回 `false, "exists"`，`replace` 对不存在 key 返回 `false, "not found"`（实测）。

列表队列模式：请求阶段 `lpush` 序列化后的事件，worker 0 的 timer 循环 `rpop` 批量发送；用 `llen` 做上界，超过阈值丢弃并计数，不要让队列 key 本身被 `forcible` 淘汰。

## 三级缓存 + 击穿防护

worker 级 `lrucache`（无锁、最快）→ 跨 worker `shared dict` → 回源，回源用 `resty.lock` 串行化。
`resty.lock`、`resty.lrucache` 均为 OpenResty 自带，实测可用。`resty.lock` 默认 `timeout=5`、`exptime=30`（源码默认值），锁不可重入：同一请求对同一 key 再次 `lock()` 会等到超时（实测 `nil, "timeout"`）。

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
local lockdict = ngx.shared.locks      -- 锁与降级配额共用这个小 dict
local NEG = "\0nil"                    -- 空结果哨兵：普通字符串，能进 shared dict
local NEG_TTL = 5
local STALE_TTL = 2                    -- 降级取到的过期值只在 L1 停留这么久，后端恢复后立刻回到正常路径
local DEGRADE_QPS = 10                 -- 拿不到锁时，每个 key 每秒最多放这么多请求回源（整机，shdict 跨 worker）

local _M = {}

local function decode(raw, key, ttl)
    if raw == NEG then lru:set(key, NEG, NEG_TTL); return nil end
    local obj = cjson.decode(raw)
    if obj == nil then                  -- 脏值（写坏/半截）不删就会一直命中并静默返回 nil（实测）
        dict:delete(key)
        return nil, "corrupted cache entry"
    end
    lru:set(key, obj, ttl)
    return obj
end

-- 拿不到锁时的降级：过期值 → 每秒配额 → 快速失败。
-- 直接 return fetch() 等于在最需要防护时关掉防护：锁拿不到，通常正是因为后端已经在超时。
local function degrade(key, staleraw, fetch)
    if staleraw then return decode(staleraw, key, STALE_TTL) end   -- 用 L2 阶段就取到的过期值兜底
    local n = lockdict:incr("dg:" .. key, 1, 0, 1)      -- 第 4 参 init_ttl=1，计数器每秒自动归零（实测）
    if n and n > DEGRADE_QPS then
        return nil, "degraded: origin budget exceeded"  -- 快速失败，把 503 交给上游，不排队堆在 worker 上
    end
    local ok, obj, ferr = pcall(fetch)                  -- 与加锁路径同一套错误语义：抛错也变成 nil, err，不让请求 500
    if not ok then return nil, obj end
    return obj, ferr
end

function _M.get(key, ttl, fetch)
    -- L1：worker 内存，命中即返回，无锁；哨兵表示"已知不存在"
    local v = lru:get(key)
    if v == NEG then return nil end
    if v then return v end

    -- L2：跨 worker 共享字典。用 get_stale 读，一次拿到值与 stale 标记：
    -- 先用普通 get 碰过过期项，之后就再也拿不到它做降级兜底了（实测）
    local raw, _, stale = dict:get_stale(key)
    if raw and not stale then return decode(raw, key, ttl) end

    -- L3：回源，用锁串行化，避免同一 key 并发穿透到后端
    local lock, nerr = resty_lock:new("locks", { timeout = 2 })
    if not lock then ngx.log(ngx.ERR, "lock:new 失败: ", nerr); return degrade(key, raw, fetch) end
    -- 不写 lock and lock:lock(key)：and 表达式只保留第一个返回值，错误原因会永远是 nil（实测日志只剩 "lock 失败: nil"）
    local elapsed, lerr = lock:lock(key)
    if not elapsed then
        ngx.log(ngx.ERR, "lock 失败: ", lerr)   -- 实测锁被占满 timeout 后 lerr = "timeout"
        return degrade(key, raw, fetch) -- 降级也要有上界，否则击穿防护在后端故障时正好失效
    end

    -- 双检：等锁期间别人可能已经填好了（这里要的是新鲜值，用普通 get）
    local fresh = dict:get(key)
    if fresh then lock:unlock(); return decode(fresh, key, ttl) end

    -- fetch 抛出 Lua error 时也必须解锁，否则该 key 卡到锁 exptime
    local ok, obj, ferr = pcall(fetch)
    if not ok then lock:unlock(); return nil, obj end      -- obj 此时是错误对象

    if obj then
        local sok, serr, forcible = dict:set(key, cjson.encode(obj), ttl)
        if not sok then ngx.log(ngx.ERR, "写缓存失败: ", serr) end
        if forcible then ngx.log(ngx.WARN, "cache dict 发生强制淘汰") end
        lru:set(key, obj, ttl)
    elseif not ferr then
        dict:set(key, NEG, NEG_TTL)     -- 空结果也缓存（短 TTL），否则不存在的 key 每次都穿透
        lru:set(key, NEG, NEG_TTL)
    end

    lock:unlock()                       -- 每条返回路径都必须 unlock
    return obj, ferr
end

return _M
```

要点：

- **`lock:unlock()` 必须覆盖所有分支**：双检命中、回源抛错、回源失败。漏一条路径就会把该 key 卡到锁 `exptime`。
- `resty_lock:new` 的 dict **不要和缓存共用**（缓存淘汰会把锁一起淘汰掉）；回源出错（`ferr` 非空）不缓存，只有"确定不存在"才写哨兵。
- **降级路径必须有上界**。三种做法的取舍：返回过期值（对用户最友好，但要求 L2 一开始就用 `get_stale` 读，且过期值可能已被回收）→ 限额回源（最差情况该 key 每秒 `DEGRADE_QPS` 次打到后端，shdict 跨 worker 所以是整机口径）→ 快速失败（保后端，牺牲这部分请求）。默认按这个顺序退；退成"无限回源"时，锁拿不到的原因（后端正在超时）会让降级变成放大器。

## 正则必须带 `jo` 选项

`ngx.re.*` 默认每次调用都重新编译正则。`j` = 启用 PCRE JIT，`o` = 缓存编译结果。
**漏了 `o`，高 QPS 下正则编译会成为热点**。

```lua
-- ✅ 实测：ngx.re.match("/api/v1/users/42", [[^/api/v(\d+)/users/(\d+)$]], "jo")
--         → m[1]="1", m[2]="42"
local m = ngx.re.match(uri, [[^/api/v(\d+)/users/(\d+)$]], "jo")
if m then local ver, id = m[1], m[2] end

-- ❌ 缺 o：每请求重新编译
local m = ngx.re.match(uri, [[^/api/v(\d+)/users/(\d+)$]])
```

用 `[[ ]]` 长字符串写正则，避免 `\\d` 这类双重转义。

`o` 缓存容量是 `lua_regex_cache_max_entries`（默认 1024，文档值），以正则字符串为键；用户输入拼进正则再加 `o` 会打满缓存，超限后新正则不再缓存（超限告警未在本机触发到）。动态正则不加 `o`，或先归一化再匹配。

## cosocket 必须复用连接

用完 `close()` 等于每请求三次握手。要用 `set_keepalive` 放回连接池。

```lua
local redis = require "resty.redis"       -- OpenResty 自带，实测可用

local function with_redis(db, fn)
    local red = redis:new()
    -- connect/send/read 超时。不设则由 lua_socket_connect_timeout 等指令决定，默认 60s（文档值；实测把指令设为 500ms 后未设超时的 connect 在 0.502s 返回 "timeout"）
    red:set_timeouts(1000, 1000, 1000)
    -- 按 db 分池：pool 名不同，不同 db 的连接不会混用；pool_size 为该池上限，backlog 为等空闲连接的排队数
    local ok, err = red:connect("127.0.0.1", 6379, { pool = "redis_db" .. db, pool_size = 100, backlog = 50 })
    if not ok then return nil, "connect: " .. err end

    -- 只有新建连接需要 select；复用连接 get_reused_times() > 0，已在正确的 db 上
    if red:get_reused_times() == 0 then
        local sok, serr = red:select(db)
        if not sok then red:close(); return nil, "select: " .. serr end
    end

    local res, ferr = fn(red)
    if res ~= nil then
        local kok, kerr = red:set_keepalive(10000, 100)   -- 空闲 10s、池大小 100；之后不可再用 red
        if not kok then ngx.log(ngx.ERR, "set_keepalive: ", kerr) end
    else
        red:close()                        -- 出错的连接不要放回池
    end
    return res, ferr
end
```

要点：

- **出错的连接不能 `set_keepalive`**：状态可能残留（比如 pipeline 没读完的响应），会污染下一个使用者。
- 认证/`select db` 改变连接状态：用 `connect` 的 `pool` 选项按 db（或按账号）分池，配合 `get_reused_times()` 只在新连接上初始化；不分池就只能固定 db 或 `close()`。
- 对连接失败的对象调用 `set_keepalive` 返回 `nil, "closed"`（实测），不抛异常；`set_keepalive` 之后该对象不可再用。连接池是 worker 私有的：`pool_size=100` × worker 数才是对 Redis 的真实连接上限。
- HTTP 出站用 `lua-resty-http`，**它不是 OpenResty 自带的**（实测 `require "resty.http"` 失败），需单独安装；只做内部子请求可以用 `ngx.location.capture`。

## JSON 一律用 cjson.safe

```lua
local cjson = require "cjson.safe"

-- 实测：非法输入返回 nil + 错误串，而不是抛异常
local obj, err = cjson.decode("{bad json")
-- obj=nil, err="Expected object key string but found invalid token at character 2"
if not obj then return ngx.exit(ngx.HTTP_BAD_REQUEST) end
```

`require "cjson"` 的 `decode` 失败会抛异常，得包 `pcall`；`cjson.safe` 直接返回 `nil, err`。
**入口解析外部输入一律用 safe 版**。

空表与数字精度（实测）：

```lua
print(cjson.encode({}))                                        --> {}（空表默认当对象）
print(cjson.encode(cjson.empty_array))                         --> []
print(cjson.encode(setmetatable({}, cjson.empty_array_mt)))    --> []（空时数组，非空时按内容）
print(cjson.encode(setmetatable({1, 2}, cjson.array_mt)))      --> [1,2]（强制数组）
cjson.encode_empty_table_as_object(false)                      -- 全局切换：之后 encode({}) → []
print(cjson.encode({3, 3.0, 3.5, 2^53}))                       --> [3,3,3.5,9.007199254741e+15]
print(cjson.encode({12345678901234567}))                       --> [1.2345678901235e+16]（默认 14 位精度）
print(pcall(cjson.encode, {[1] = 1, [1000] = 1}))              --> false  excessively sparse array
print(pcall(cjson.encode, {0/0}))                              --> false  must not be NaN or Infinity
print(cjson.decode("[null]")[1] == cjson.null)                 --> true（不是 nil）
```

`cjson.empty_object` 不存在（实测为 nil）。超过 14 位有效数字的整数（雪花 ID、金额分）只能按字符串传递，`encode_number_precision(16)` 上限 16 位仍装不下 int64。

## 绝不阻塞 worker

一个 worker 用单线程事件循环跑成千上万个请求。**任何阻塞调用会冻结该 worker 上的全部请求**。

```lua
-- ❌ 这些都会阻塞整个 worker
os.execute("curl ...")                     -- io.popen 同理
local f = io.open("/path"):read("*a")     -- 磁盘 IO 阻塞；require "socket"（LuaSocket）同样阻塞

-- ✅ 对应的非阻塞替代
ngx.socket.tcp()                           -- 网络
ngx.timer.at(0, function() end)            -- 后台任务
ngx.sleep(0.01)                            -- 让出控制权（log 阶段不可用，见上文）
ngx.now()                                  -- 缓存的时间，不走系统调用；需要精确时间先 ngx.update_time()
```

外部命令一律移出请求路径：让 timer 去做，或者交给后端服务。请求体落盘后 `ngx.req.get_body_file()` 的读取也是阻塞磁盘 IO（实测 `client_body_buffer_size 1k` + 3000 字节请求体即落盘）。

## 请求间的状态污染

Lua 模块只在 worker 内加载一次，**模块级变量被该 worker 的所有请求共享**。

```lua
-- ❌ 模块级可变状态：请求 A 写的值会被请求 B 读到
local _M = {}
local current_user          -- 灾难
function _M.set_user(u) current_user = u end

-- ✅ 请求级状态放 ngx.ctx（每请求独立，请求结束即回收）
function _M.set_user(u) ngx.ctx.user = u end
```

模块级只放**不可变**的东西：配置常量、预编译正则、`lrucache` 实例、共享字典引用。

`ngx.ctx` 每次访问走一次 metatable，热路径里先取到局部变量（同一请求内读到的是同一个 table，实测）。`ngx.location.capture`
的子请求拿到**独立的空** `ngx.ctx`，子请求内写入不影响父请求（实测父值原样保留）；`ngx.exec` 跳转后 `ngx.ctx` 为空（实测）。跨跳转传值用 `ngx.var` 或请求头。

### `require` 命中模块缓存：模块顶层的自动执行代码只跑一次

`require` 在同一 worker 内对同一模块只加载一次，之后直接返回 `package.loaded` 里缓存的值，**不会重新执行 chunk**。常见于从独立脚本改造成模块的 WAF/限流代码——文件末尾习惯性留了一行顶层自动调用：

```lua
-- ❌ 模块尾部自动执行
local _M = {}
function _M.run() ... end
_M.run()          -- 顶层调用；只在 chunk 第一次被加载时跑一次
return _M
```

同一份代码，接入方式不同，效果完全不同（实测，OpenResty 1.27.1.2，连续 5 次请求）：

| 接入方式 | `run()` 实际执行次数 |
|---|---|
| `access_by_lua_file waf.lua` | 5（每请求重新执行整个文件） |
| `access_by_lua_block { require "waf" }` | **1**（`require` 命中缓存，chunk 只跑一次） |

用 `require` 接入时，这段防护逻辑只在该 worker 生命周期里生效一次，此后所有请求全部放行，**且没有任何报错或日志**——看起来"装上了"，实际是摆设。

```lua
-- ✅ 模块只导出函数，不在顶层调用副作用代码
local _M = {}
function _M.run() ... end
return _M
```

```nginx
access_by_lua_block { require("waf").run() }
```

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
