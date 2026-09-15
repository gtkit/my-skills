# 分配优化

```go
// strings.Builder + Grow：一次分配；s += x 每次都新建字符串并拷贝全部旧内容，O(n²)。
func JoinNames(items []Item) string {
	var b strings.Builder
	b.Grow(len(items) * 16)
	for i := range items {
		if i > 0 {
			b.WriteByte(',')
		}
		b.WriteString(items[i].Name)
	}
	return b.String()
}

// strconv.Append* 直接写进已有 []byte；fmt.Sprintf 走反射 + 参数装箱，每次调用多次分配。
func FormatKey(buf []byte, userID int64, shard int) []byte {
	buf = append(buf, "user:"...)
	buf = strconv.AppendInt(buf, userID, 10)
	buf = append(buf, ':')
	return strconv.AppendInt(buf, int64(shard), 10)
}

// map 查找时 m[string(b)] 不分配（编译器特例）；先 s := string(b) 再 m[s] 就会拷贝一次。
func Lookup(m map[string]int, key []byte) (int, bool) {
	v, ok := m[string(key)]
	return v, ok
}

// unique.Make（Go 1.23+）驻留重复字符串：百万条记录里的几十个 service 名只存一份，相等比较退化为指针比较。
type Service struct{ Name unique.Handle[string] }

func NewService(name string) Service { return Service{Name: unique.Make(name)} }
```

预分配：长度已知时 `make([]T, 0, n)`，append 扩容是"翻倍 / 1.25 倍 + 整体拷贝"。`unsafe.String` / `unsafe.Slice` 做零拷贝转换只在能证明底层数组此后不再被修改时用，否则是字符串被改写的静默 bug。

`sync.Pool` 必须限制放回对象的大小：

```go
const maxPooledBuf = 64 << 10 // 64KiB

var bufPool = sync.Pool{
	New: func() any { return bytes.NewBuffer(make([]byte, 0, 4<<10)) },
}

// EncodeJSON 复用缓冲。Put 前必须检查 Cap：一次 10MB 的响应会让大缓冲永久驻留池里，
// 之后每次 Get 都可能拿到它，进程 RSS 只涨不跌。
func EncodeJSON(v any) ([]byte, error) {
	buf := bufPool.Get().(*bytes.Buffer)
	defer func() {
		if buf.Cap() > maxPooledBuf {
			return // 交给 GC，不放回
		}
		buf.Reset()
		bufPool.Put(buf)
	}()
	if err := json.NewEncoder(buf).Encode(v); err != nil {
		return nil, err
	}
	return bytes.Clone(buf.Bytes()), nil // 必须拷贝：buf 归还后会被别的 goroutine 复用
}
```

结构体字段对齐：

```go
// 字段按大小降序排列消除填充（Go 1.27 amd64 实测 unsafe.Sizeof：Padded=32，Packed=16）。检查工具：
// go run golang.org/x/tools/go/analysis/passes/fieldalignment/cmd/fieldalignment@latest ./...
type Padded struct {
	A bool  // 1 + 7 填充
	B int64 // 8
	C bool  // 1 + 3 填充
	D int32 // 4
	E bool  // 1 + 7 填充
}

type Packed struct {
	B int64 // 8
	D int32 // 4
	A bool  // 1
	C bool  // 1
	E bool  // 1 + 1 填充
}
```

只对"数量巨大"的结构体值得做（百万级切片元素、缓存条目）；几十个实例的配置结构体重排只降低可读性。
