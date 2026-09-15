# 幂等写接口（Idempotency-Key）

状态机：无记录 → `processing` → `done(status, body)`。首选实现是 DB 业务表上的幂等键 UNIQUE 约束（取舍见 go-data-consistency），中间件方案是其上的应用层补充。`IdemStore` 接口：`Begin(ctx, key, ttl) (rec *IdemRecord, acquired bool, err error)` 必须是原子占位（Redis `SET NX` / DB 唯一键 INSERT），两个并发请求只能有一个 `acquired`；`Finish(ctx, key, rec, ttl)`；`Abort(ctx, key)`。反例：先 `GET` 再 `SET`——并发请求都查到空、都执行业务。`captureWriter` 嵌入 `gin.ResponseWriter`，重写 `Write`/`WriteString` 同时写入 `bytes.Buffer`。

```go
// Idempotency 状态机：无记录 → processing → done(result)。
// 命中 processing 返回 409（客户端稍后重试），命中 done 原样回放首次响应；handler 报错（c.Errors 非空）、5xx 或 panic 则释放占位允许重试。
func Idempotency(store IdemStore, ttl time.Duration) gin.HandlerFunc {
	return func(c *gin.Context) {
		key := c.GetHeader("Idempotency-Key")
		if key == "" || len(key) > 128 {
			ginmw.Fail(c, apperror.WithMessage(apperror.ErrInvalidParam, "Idempotency-Key header required (1-128 chars)"))
			return
		}
		ctx := c.Request.Context()
		key = c.GetString(KeyUserID) + ":" + c.FullPath() + ":" + key // 绑定用户与路由，防止跨用户串号
		rec, acquired, err := store.Begin(ctx, key, ttl)
		if err != nil {
			ginmw.Fail(c, apperror.Wrap(apperror.ErrUnavailable, err))
			return
		}
		if !acquired {
			if rec != nil && rec.State == IdemDone { // 实现返回 acquired=false 却给 nil 记录时按 processing 处理，不能 panic
				c.Data(rec.Status, "application/json", rec.Body)
			} else {
				c.JSON(http.StatusConflict, ginmw.ErrorBody{Code: apperror.CodeConflict, Message: "request with same Idempotency-Key is in progress"})
			}
			c.Abort()
			return
		}
		bg := context.WithoutCancel(ctx) // 客户端此时断开也要把状态写完，否则占位卡在 processing 直到 TTL
		defer func() {
			if r := recover(); r != nil {
				_ = store.Abort(bg, key)
				panic(r) // 交给外层 Recovery 记录栈
			}
		}()
		w := &captureWriter{ResponseWriter: c.Writer}
		c.Writer = w
		c.Next()
		// 经 ginmw.Fail 报告的错误此时尚未被外层 Errors 中间件写出，Status() 仍是默认 200（Go 1.27 + gin 1.12 实测）：
		// 必须同时看 c.Errors，否则失败请求被记成 done/200，之后同 key 的重试全部回放这个空 200。
		if len(c.Errors) > 0 || c.Writer.Status() >= http.StatusInternalServerError {
			_ = store.Abort(bg, key)
			return
		}
		_ = store.Finish(bg, key, IdemRecord{State: IdemDone, Status: c.Writer.Status(), Body: w.buf.Bytes()}, ttl)
	}
}
```
