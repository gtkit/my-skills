# `ngx.exit` 的真实语义

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
