# 逃逸分析

```bash
go build -gcflags='-m=2' ./pkg 2>&1 | grep -v inlin
```

`-m=2` 输出（Go 1.27 实测）里三种关键行：

- `moved to heap: u`——变量 u 本身被搬到堆，通常因为地址被返回或存进逃逸的结构。
- `leaking param: name`——参数内容随返回值 / 全局逃逸；`leaking param content` 是只有指向的内容逃逸。
- `300 escapes to heap`——值被装进接口（`any`）或 `...any` 参数，分配一份拷贝。

```go
// NewUser 返回局部变量地址，u 必然逃逸——这是"值得"的逃逸：对象本来就要跨调用存活，不用修。
func NewUser(name string) *User {
	u := User{Name: name}
	return &u
}

// Describe 把值装进 any 要分配一次（Go 1.27 实测：运行期 int 300 / string / 24 字节 struct 各 1 次；
// 0~255 的整数走 runtime 静态表，0 次）。热路径上优先写具体类型的重载，不走 any。
func Describe(v any) string { return fmt.Sprint(v) }
```

不值得修的逃逸：构造函数返回指针；对象生命周期本来就跨请求；每请求只发生一次的分配（一次 32 字节分配在一次 HTTP 请求里可忽略）。值得修的：每次循环迭代都发生的装箱、闭包捕获、`fmt.Sprintf` 拼 key。
