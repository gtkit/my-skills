# 正则与 JSON

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
