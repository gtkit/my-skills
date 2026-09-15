# 三级缓存 + 击穿防护

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
