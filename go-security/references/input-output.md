# 应用层：输入与输出

- 注入：参数化查询与列名白名单见 go-database-patterns；`fmt.Sprintf` 拼任何 SQL 片段都是缺陷。
- 输出编码：`html/template` 按位置选转义器（文本节点 HTML 转义，`href` 查询串 URL 转义，`<script>` 内 JS 转义），`text/template` 一个都没有；`encoding/json` 默认把 `<`、`>`、`&` 转成 `\u003c` 等，`SetEscapeHTML(false)` 只用于非浏览器消费方。
- 邮箱用 `net/mail.ParseAddress`，正则校验邮箱是经典反模式；路径用 `filepath.IsLocal`（Go 1.20，词法）+ `os.Root`（Go 1.24，运行时含符号链接）双重拦截。

```go
var page = template.Must(template.New("p").Parse(`<p>{{.Comment}}</p><a href="/search?q={{.Query}}">再搜</a>`))

func ValidEmail(s string) (string, error) {
	addr, err := mail.ParseAddress(s)
	if err != nil || addr.Name != "" {
		return "", ErrBadEmail
	}
	return addr.Address, nil
}

func OpenUpload(baseDir, name string) (*os.File, error) {
	if !filepath.IsLocal(name) { // 拒绝 ""、绝对路径、"../x"、Windows 保留名
		return nil, ErrBadPath
	}
	root, err := os.OpenRoot(baseDir)
	if err != nil {
		return nil, err
	}
	defer root.Close()
	return root.Open(name) // 链接指向 root 之外时返回错误
}
```

### SSRF

流程：入口只接受 `http/https` 且有 Host → 解析出全部 IP → 任一命中 loopback / 私网 / 100.64.0.0/10（`IsPrivate` 不含，阿里云元数据在此段）/ 链路本地（169.254.169.254）/ 多播 / 未指定即拒绝 → 连接刚校验过的那个 IP → 重定向次数上限且目标同样走校验。IP 校验必须在 `DialContext` 里做：先解析再交给默认拨号会二次解析，攻击者的 DNS 第一次返回公网、第二次返回 10.0.0.1（DNS rebinding）。

```go
var cgnat = netip.MustParsePrefix("100.64.0.0/10") // RFC 6598；IsPrivate 不含它，阿里云元数据 100.100.100.200 就在这段

func blocked(ip netip.Addr) bool {
	ip = ip.Unmap() // ::ffff:10.0.0.1 这类 4in6 绕过
	return !ip.IsValid() || ip.IsLoopback() || ip.IsPrivate() || cgnat.Contains(ip) || ip.IsUnspecified() ||
		ip.IsLinkLocalUnicast() || // 169.254.169.254 云元数据
		ip.IsLinkLocalMulticast() || ip.IsInterfaceLocalMulticast() || ip.IsMulticast()
}

	tr.DialContext = func(ctx context.Context, network, addr string) (net.Conn, error) {
		host, port, err := net.SplitHostPort(addr)
		if err != nil {
			return nil, err
		}
		ips, err := net.DefaultResolver.LookupNetIP(ctx, "ip", host)
		if err != nil {
			return nil, err
		}
		for _, ip := range ips {
			if blocked(ip) { // 任一解析结果命中即拒绝，防混合 A 记录
				return nil, ErrForbiddenAddr
			}
		}
		return dialer.DialContext(ctx, network, net.JoinHostPort(ips[0].Unmap().String(), port))
	}
```

### 反序列化与解析炸弹

- JSON：`encoding/json` 嵌套深度硬上限 10000，超出报 `exceeded max depth`（Go 1.27 实测），深度不用自己防；体积靠 `MaxBytesReader`/`LimitReader`；`DisallowUnknownFields` 是 mass assignment 的第二道闸。
- XML：`encoding/xml` 不解析 DTD 实体声明，自定义实体在 Strict 模式报 `invalid character entity`（实测），billion laughs 天然免疫；基于 libxml2 的 cgo 库不在此列。
- YAML：`gopkg.in/yaml.v3` 对别名展开有上限，炸弹文档报 `yaml: document contains excessive aliasing`（实测）。
- zip：条目名过 `IsLocal` 防 zip slip；解压总字节按实际读出计数，头部 `UncompressedSize64` 可伪造。

```go
func DecodeJSON[T any](r io.Reader, limit int64) (T, error) {
	var v T
	dec := json.NewDecoder(io.LimitReader(r, limit))
	dec.DisallowUnknownFields()
	err := dec.Decode(&v)
	return v, err
}

		if !filepath.IsLocal(f.Name) {
			return fmt.Errorf("zip: illegal entry %q", f.Name)
		}

	n, err := io.Copy(dst, io.LimitReader(rc, limit))
```
