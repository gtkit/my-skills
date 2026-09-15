# cosocket 必须复用连接

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
