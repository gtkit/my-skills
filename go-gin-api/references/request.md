# 响应结构与 DTO 校验

## 统一成功响应

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

``Response{Code int; Message string; Data any `json:"data,omitzero"`; Meta PageMeta `json:"meta,omitzero"`}``：`omitempty` 对 struct 值不生效（encoding/json 只认 false/0/nil/空集合），`PageMeta` 零值照样输出——Go 1.24 起用 `omitzero`（Go 1.27 实测）。错误响应形状是 go-error-handling 的 `ginmw.ErrorBody`。

## DTO 绑定与校验

```go
// SetupValidator 在启动时调用一次。binding.Validator.Engine() 返回 any，需断言为 *validator.Validate。
// 不注册 TagNameFunc 时 FieldError.Field() 返回 Go 字段名 "Email"，客户端拿到的字段名与请求体对不上。
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
	return v.RegisterValidation("phone", func(fl validator.FieldLevel) bool {
		return phoneRE.MatchString(fl.Field().String())
	})
}

// Bind 是 handler 里唯一的绑定入口：校验错误按字段返回，其余解码错误一律 400 且不回显原文——
// err.Error() 会泄漏 "Key: 'CreateUserReq.Email' Error:..." 之类内部结构名，以及 json.SyntaxError 的偏移量细节。
func Bind(c *gin.Context, dst any) bool {
	err := c.ShouldBindJSON(dst)
	if err == nil {
		return true
	}
	if mbe, ok := errors.AsType[*http.MaxBytesError](err); ok {
		ginmw.Fail(c, apperror.WithMessage(&apperror.AppError{Code: apperror.CodeInvalidParam, HTTP: http.StatusRequestEntityTooLarge},
			fmt.Sprintf("request body exceeds %d bytes", mbe.Limit)))
		return false
	}
	if ves, ok := errors.AsType[validator.ValidationErrors](err); ok {
		msgs := make([]string, 0, len(ves))
		for _, fe := range ves {
			msgs = append(msgs, fe.Field()+": failed on "+fe.Tag()) // fe.Field() 已是 json 名
		}
		ginmw.Fail(c, apperror.WithMessage(apperror.ErrInvalidParam, strings.Join(msgs, "; ")))
		return false
	}
	ginmw.Fail(c, apperror.Wrap(apperror.WithMessage(apperror.ErrInvalidParam, "malformed request body"), err))
	return false
}
```
