# 阻塞与请求间状态污染

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
