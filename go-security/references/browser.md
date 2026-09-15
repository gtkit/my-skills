# 应用层：浏览器侧防护

### 安全头

`X-XSS-Protection: 1; mode=block` 是有害配置：Chrome/Edge 已删除 XSS Auditor，Firefox 从未实现，历史上 Auditor 自身被用作 XS-Leak 探测页面内容。防 XSS 的头是 CSP。HSTS 只在 HTTPS 响应上有意义；撤回要下发 `max-age=0` 且客户端得再访问一次 HTTPS 才收得到，进了 preload 列表更要等数月，所以先用短 `max-age` 验证再放大。

```go
func SecurityHeaders(api bool) gin.HandlerFunc {
	csp := "default-src 'self'; object-src 'none'; base-uri 'self'; frame-ancestors 'none'"
	if api { // 纯 JSON API 没有可执行内容
		csp = "default-src 'none'; frame-ancestors 'none'"
	}
	return func(c *gin.Context) {
		h := c.Writer.Header()
		h.Set("X-Content-Type-Options", "nosniff")
		h.Set("Content-Security-Policy", csp)
		h.Set("X-Frame-Options", "DENY") // 旧浏览器兜底，现代浏览器以 frame-ancestors 为准
		h.Set("Referrer-Policy", "strict-origin-when-cross-origin")
		h.Set("Strict-Transport-Security", "max-age=63072000; includeSubDomains") // 只在 HTTPS 响应上有意义；撤回要再发 max-age=0
		c.Next()
	}
}
```

### CSRF

三道防线按顺序：`SameSite=Lax` cookie（阻断跨站 POST）→ `Sec-Fetch-Site` 校验（浏览器自动带，不可伪造）→ 双提交 token 兜底没有该头的老客户端。`OPTIONS` 必须放行，否则 CORS 预检全部 403。`same-site`（其他子域）与 `cross-site` 同样拒绝——子域接管是常见跳板。

```go
func CSRF(cookieName, headerName string) gin.HandlerFunc {
	safe := map[string]bool{http.MethodGet: true, http.MethodHead: true, http.MethodOptions: true} // OPTIONS 是 CORS 预检，拦了整站跨域全挂
	return func(c *gin.Context) {
		if safe[c.Request.Method] {
			c.Next()
			return
		}
		switch c.GetHeader("Sec-Fetch-Site") {
		case "same-origin", "none": // none = 用户从地址栏/书签直接发起
		case "": // 老客户端：退到双提交 token；token cookie 不能 HttpOnly，否则前端读不到
			cookie, err := c.Cookie(cookieName)
			if err != nil || cookie == "" || subtle.ConstantTimeCompare([]byte(cookie), []byte(c.GetHeader(headerName))) != 1 {
				c.AbortWithStatus(http.StatusForbidden)
				return
			}
		default: // cross-site、same-site（其他子域可能被接管）一律拒
			c.AbortWithStatus(http.StatusForbidden)
			return
		}
		c.Next()
	}
}
```
