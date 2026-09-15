# 共享字典的真实行为

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
