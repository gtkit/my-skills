# golangci-lint v2 配置

实测 `golangci-lint config verify` 通过；对 `import "log"`、`import "log/slog"`、repository 层 `import gin` 分别报 depguard，对 `f, _ := os.Open()` 报 errcheck。

```yaml
version: "2"

run:
  timeout: 5m
  modules-download-mode: readonly   # go.mod/go.sum 不干净直接失败，不在 lint 时静默修改

linters:
  default: none                     # 白名单制：每个 linter 都说得出为什么开
  enable:
    - errcheck        # 未处理的 error 返回值（含 defer f.Close()）
    - govet           # 官方 vet 全量：printf 参数、copylocks、lostcancel、loopclosure、waitgroup
    - staticcheck     # 死代码、弃用 API（SA1019）、错误的标准库用法；v2 已并入 gosimple/stylecheck
    - unused          # 未使用的常量/变量/函数/类型
    - ineffassign     # 赋值后从未读取
    - errorlint       # err == ErrX 比较、%v 包装 error、type switch 断言 error（应 errors.Is/As/%w）
    - gosec           # 硬编码凭据、弱随机、不安全 TLS、G204 命令注入、文件权限
    - bodyclose       # http.Response.Body 未 Close → 连接泄漏
    - noctx           # 发 HTTP/SQL 不带 context → 无法超时与取消
    - contextcheck    # 函数内新建 context.Background() 切断了调用链的取消传播
    - sqlclosecheck   # sql.Rows/Stmt 未 Close → 连接池耗尽
    - rowserrcheck    # rows.Next() 循环后未查 rows.Err() → 静默截断结果集
    - exhaustive      # enum switch 漏分支（新增枚举值时编译不报错，lint 报）
    - gocritic        # diagnostic + performance 标签：badCond、dupBranchBody、rangeValCopy、hugeParam
    - revive          # 可配置的风格与 API 规则（导出符号注释、上下文参数位置、裸返回）
    - nilerr          # if err != nil { return nil } —— 吞错
    - copyloopvar     # Go 1.22 起多余的 v := v
    - intrange        # for i := 0; i < n; i++ 可写 for i := range n
    - usetesting      # 测试里应用 t.Context()/t.TempDir()/t.Setenv 而非手写等价物
    - depguard        # 固化依赖方向与禁用包（见 settings）
    # - wrapcheck     # 要求包装外部包错误；库项目开，业务项目噪音大，按需
  settings:
    govet:
      enable-all: true
      disable:
        - fieldalignment   # 结构体重排属性能专项，单独跑 `fieldalignment -fix ./...`，不进日常门禁
    errcheck:
      check-type-assertions: true   # x.(T) 无 ok 形式 → 运行时 panic
      check-blank: true             # _ = f() 也要显式说明
    exhaustive:
      default-signifies-exhaustive: true
    gocritic:
      enabled-tags: [diagnostic, performance]
    revive:
      rules:
        - name: context-as-argument
        - name: error-return
        - name: error-strings
        - name: unhandled-error
          arguments: [fmt.Print, fmt.Printf, fmt.Println]
    depguard:
      rules:
        logging:
          deny:
            - pkg: log/slog
              desc: 日志一律使用 github.com/gtkit/logger/v2
            - pkg: "log$"
              desc: 日志一律使用 github.com/gtkit/logger/v2
            - pkg: github.com/pkg/errors
              desc: 用标准库 errors + fmt.Errorf("%w")
            - pkg: io/ioutil
              desc: Go 1.16 起弃用，改用 io / os
        layering:
          files: ["**/internal/repository/**"]
          deny:
            - pkg: github.com/gin-gonic/gin
              desc: repository 层不得依赖 HTTP 框架（依赖方向 handler → service → repository）
  exclusions:
    generated: lax
    presets: [std-error-handling, common-false-positives]
    rules:
      - path: _test\.go
        linters: [gosec, noctx]

formatters:
  enable: [gofumpt, goimports]
  settings:
    goimports:
      local-prefixes: [example.com/app]

issues:
  max-issues-per-linter: 0
  max-same-issues: 0
```

- v2 变化：`version: "2"` 必填；`gosimple`、`stylecheck` 并入 `staticcheck`；格式化器移到 `formatters`（gofmt / gofumpt / goimports / gci / golines），`golangci-lint fmt` 一条命令；`run.timeout` 默认不限时（实测 `--help`）；`linters.exclusions.presets` 取代旧 `issues.exclude-use-default`。
- depguard 的 `pkg: "log$"` 精确匹配标准库 `log`，不会误伤 `github.com/gtkit/logger/v2`（实测）。
- `fieldalignment` 单独跑 `go run golang.org/x/tools/go/analysis/passes/fieldalignment/cmd/fieldalignment@latest -fix ./...`：它会重排字段影响可读性，只对内存热点结构体做。
- `wrapcheck`：库项目开（调用方要 `errors.Is` 穿透，包装点要可控），业务项目关（每个 return 都要 `fmt.Errorf` 是噪音）。
- `//nolint:gosec // G204: 参数来自白名单` 必须带 linter 名与理由，`nolintlint` 抓裸 `//nolint`。
