# 响应结构与 DTO 校验

## 统一成功响应

以下仅为响应结构示例。已有项目必须复用真实存在、符合 Gin 语义的响应工具、字段名和空值约定，不因本示例另建公共包或替换接口协议；JSON 响应由 Gin 的渲染 API 完成。

```go
// Paged 是公共包，不能假设调用方已做默认值处理：perPage <= 0 直接整除零 panic，
// total 为负（COUNT 减去软删数量写错符号）会算出负页数，前端翻页控件按负数循环请求。
// items 为 nil 时输出 [] 而非 null，客户端不必区分两种"空"。
func Paged[T any](c *gin.Context, items []T, page, perPage int, total int64) {
	perPage = max(perPage, 1)
	total = max(total, 0)
	if items == nil {
		items = []T{}
	}
	// 先除后补，不用 (total+perPage-1)/perPage：total 接近 MaxInt64 时那个写法会溢出成负数。
	totalPage := int(total / int64(perPage))
	if total%int64(perPage) != 0 {
		totalPage++
	}
	c.JSON(http.StatusOK, Response{
		Message: "success",
		Data:    items,
		Meta:    PageMeta{Page: max(page, 1), PerPage: perPage, Total: total, TotalPage: totalPage},
	})
}
```

``Response{Code int; Message string; Data any `json:"data,omitzero"`; Meta PageMeta `json:"meta,omitzero"`}``：`omitempty` 对 struct 值不生效（encoding/json 只认 false/0/nil/空集合），`PageMeta` 零值照样输出——Go 1.24 起用 `omitzero`（Go 1.27 实测）。本 skill 的错误响应示例采用 go-error-handling 的 `ginmw.ErrorBody`，已有项目沿用其已确认契约。

## 先核对框架和项目依据

动手前读取锁定的 Gin 版本、模块替换、有关构建标签、同模块 handler、请求 DTO、统一错误响应和中间件。以下原生方法及调用语义已对照 Gin v1.12.0 的 `context.go`、`binding/binding.go`、`binding/json.go`、`binding/query.go` 和 `binding/form.go`；其他版本及 JSON 实现仍按目标项目核实。此说明维护只做了源码核对，没有运行示例或业务测试。

框架 API、输入来源和项目调用链有依据后再编写代码。禁止因为示例出现某个 helper 就假设目标项目也存在；禁止把 Gin 支持的能力误判为必须手写实现。

## 按输入来源使用原生绑定

| 已确认的输入来源 | Gin 入口 | DTO 字段标签与边界 |
|---|---|---|
| JSON 请求体 | `c.ShouldBindJSON(&req)` | `json` + `binding`；该方法指定 JSON 解码器，不自动验证 Content-Type 是否符合接口契约 |
| 仅 URL query | `c.ShouldBindQuery(&req)` | `form` + `binding`；不从请求体取字段 |
| 路径参数 | `c.ShouldBindUri(&req)` | `uri` + `binding`；不要手取字符串再逐字段转换和校验 |
| 请求 header | `c.ShouldBindHeader(&req)` | `header` + `binding`；按契约定义需要的字段 |
| 表单或按方法、Content-Type 自动选择格式 | `c.ShouldBind(&req)` | 通常为 `form` + `binding`；自动选择不等于只接受一种格式 |
| 明确只取 URL 编码表单的请求体字段 | `c.ShouldBindWith(&req, binding.FormPost)` | `form` + `binding`；与自动 Form 绑定可能合并 query 的行为区分 |
| multipart 表单 | `c.ShouldBind(&req)`，由实际 Content-Type 选择 | `form` + `binding`；文件操作按 Gin 原生文件 API 和已确认大小限制处理 |

- JSON-only 接口不要为省事改成可接收多种格式的自动绑定；Content-Type 的接受范围单独按契约及已有中间件处理。反过来，表单接口也不能照搬 `ShouldBindJSON`。
- 一个请求同时有 path、query、body 等来源时，分别绑定对应 DTO，每次检查错误，任一失败立即结束当前分支。不要反复覆盖同一 DTO，造成字段来源或优先级不明。
- 普通结构化请求直接调用上述方法。禁止把 `io.ReadAll`、手工 Content-Type 分支、`json.Unmarshal` 和逐字段判断拼成另一套默认解析链，也禁止再包装一个仅供单接口使用的 `Bind`/`ParseRequest`。

## DTO 标签与校验职责

下例只展示原生字段标签；字段及限制以实际接口契约为准，不把示例限制加到其他接口：

```go
type CreateRequest struct {
	Email string `json:"email" binding:"required,email"`
}
```

- 基础必填、长度、格式、范围等采用 Gin 集成的 validator 标签；标签是否适用按项目实际 validator 版本及字段类型核实。解码到独立请求 DTO，不绑到数据库 model。
- `json`、`form`、`uri`、`header` 标签描述字段来源，`binding` 标签描述校验，不能用其中一种代替其他职责。
- `required` 会拒绝相应类型的零值。业务允许 `0` 或 `false`、但需要区分字段缺失时，应按契约选择可表达存在性的类型及标签；不能机械给所有字段加 `required`，也不能随意把缺失与空值当成同一种输入。
- 业务状态、权限、数据库查询等判断留在 application/service。确实超出内建标签的纯格式校验，才复用或注册 validator 扩展；不为单次字段检查另建校验框架。
- 字段错误名按实际输入来源映射。项目需要 `RegisterTagNameFunc` 或自定义校验注册时，在启动阶段按现有机制完成并处理错误，不在每个请求中反复注册或修改全局配置。

Gin 原生绑定会调用其校验器。项目确需将校验错误字段映射为 JSON 字段名时，可沿用下面的启动期扩展示例；服务骨架中的 `dto.SetupValidator` 对应此例。多来源请求仍需按实际标签映射，已有项目优先复用自己的实现；使用内建标签本身无须新增这个函数。

```go
func SetupValidator() error {
	v, ok := binding.Validator.Engine().(*validator.Validate)
	if !ok {
		return errors.New("binding.Validator.Engine() is not *validator.Validate")
	}
	v.RegisterTagNameFunc(func(fld reflect.StructField) string {
		name, _, _ := strings.Cut(fld.Tag.Get("json"), ",")
		if name == "-" {
			return ""
		}
		return name
	})
	return nil
}
```

## handler 与错误响应

固定顺序为：原生绑定并处理错误 → 读取已校验的身份/上下文 → DTO 映射应用参数 → 调 application/service → 使用已有响应工具。handler 只承担 HTTP 适配，不混入数据库操作和复杂业务规则。

下面仅表示 handler 内的绑定位置；错误分支须接入目标项目真实存在的响应工具后使用，不是可以原样运行的完整 handler：

```go
var req CreateRequest
if err := c.ShouldBindJSON(&req); err != nil {
	// 此处调用项目已有的参数错误响应工具，完成错误分类与脱敏。
	return
}
// 使用 req 调用 application/service；向下游传 c.Request.Context()。
```

- `ShouldBind*` 返回错误，由调用方决定响应；不要误以为它已经向客户端写出了错误。
- `Bind*`/`MustBind*` 走自动中断及错误状态写出路径。已有统一错误信封的 handler 应使用 `ShouldBind*`，避免自动响应与业务响应相互覆盖；具体错误状态以锁定版本为准。
- 解码失败、类型不匹配、校验失败交给已有错误映射；请求体超限保留对应分类和状态。`http.MaxBytesReader` 的限长及 `*http.MaxBytesError` 的实际传播须与 JSON 实现一起核对，不因换回原生绑定而删掉限长或把所有错误压成同一种。
- 不把原始 `err.Error()`、内部结构名、敏感请求内容或底层错误回传客户端。字段错误只返回项目允许暴露的字段名与稳定文案；服务端诊断遵守现有脱敏规则。
- 拒绝分支在响应后 `return`。中间件拒绝请求时同时停止后续链；`c.Abort()` 本身不退出当前函数，`c.JSON()` 本身不代表链已中止，`c.Next()` 只用于需要执行下游链的位置，不能机械添加。

## 原始请求体和特殊协议的适配边界

- 原始字节验签、流式输入、文件、特殊媒体类型必须先有真实接口需求，再核对 Gin 原生方法与现有中间件。禁止以假设需求为普通 JSON 接口增加手工读取、重复解码或请求体缓存。
- 确有重复读取请求体的需求时，先评估当前版本的 `ShouldBindBodyWith` 等原生能力及缓存成本；不能默认所有请求都缓存，也不能忘记先设置大小限制。
- 未知字段、重复键、尾随 JSON、空请求体或 `null` 的接受规则，逐项来自已确认契约。不得自行增加限制来证明自定义 binder 必要；也不得为删代码而放弃已经确认的安全要求。
- 原生能力确实不足时，先记录具体缺口、版本/源码依据、影响范围和最小适配方案，取得用户对自定义解析或绑定的明确认可；优先沿用 Gin 扩展点，不另造通用请求框架。全局解码开关会影响其他路由，不能为单接口擅自修改。
- 用户纠正写法后，重新核对需求和原生能力，去掉不必要的解析链；把相同逻辑搬进 helper、新文件或 `binding.Binding` 并不构成简化。已有安全、兼容和错误响应契约必须保留。
