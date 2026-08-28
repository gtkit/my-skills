---
name: go-engineering-governance
description: Go 工程治理与 CI 门禁：golangci-lint v2 配置、CI 流水线（GitHub Actions / GitLab CI）、govulncheck / gosec、go.mod 依赖治理（tidy / verify / why / graph、GOPRIVATE / GONOSUMDB / GOPROXY、私有模块、replace、go.work、tool 指令）、API 兼容性（apidiff、语义化版本、Deprecated 注释）、发布纪律（tag 与 major 一致、goreleaser、CHANGELOG）、PGO 采集与刷新流程、代码规范落地（gofmt / gofumpt / goimports、pre-commit、go generate 产物检查、//go:build、internal/ 边界）、项目布局与依赖方向（depguard 固化）。当用户配置 lint、搭 CI、治理依赖、评估 API 变更、准备发版、接 PGO、定项目结构时触发。触发关键词包括但不限于：golangci-lint、.golangci.yml、lint、CI 门禁、GitHub Actions、GitLab CI、govulncheck、gosec、go.mod、go.sum、依赖升级、Dependabot、Renovate、apidiff、API 兼容、破坏性变更、语义化版本、SemVer、go.work、GOPRIVATE、GOFLAGS、GOTOOLCHAIN、Makefile、PGO、default.pgo、pre-commit、gofumpt、goimports、go generate、depguard、cmd/、internal/、pkg/。分工：PGO 原理与收益、pprof 分析见 go-performance；测试写法与覆盖率策略见 go-testing；安全编码见 go-security。
---

# Go 工程治理与 CI 门禁

lint、CI 门禁、依赖治理、API 兼容、发布纪律、PGO 流程与项目布局。PGO 原理见 go-performance，测试写法见 go-testing。
标「实测」的结论在 Go 1.27.0、golangci-lint 2.13.1、`golang.org/x/exp/cmd/apidiff` 上验证。

## 核心规则

1. 门禁只放"失败即阻断"的检查；只告警不阻断的检查等于没有。
2. lint 白名单制（`linters.default: none`），每个 linter 说得出抓什么；开 `all` 再逐个关是噪音源。
3. `go mod tidy -diff` 进门禁：有差异时 exit 1（实测），CI 不得自动 tidy 后继续。
4. 工具版本钉死：lint action 的 `version:`、go.mod 的 `tool` 指令、Makefile 变量；裸 `@latest` 只出现在定期升级任务里。
5. 导出 API 变更过 `apidiff -incompatible`；有输出就要么改回，要么走 fail-closed 的 MINOR 发布 + ⚠ CHANGELOG。
6. 永不发 v3 及更高 major，module path 不迁 `/v3`；破坏性变更留在现有 major 线，只允许 fail-closed 形态。
7. 打 tag 前 `git status --porcelain` 必须为空；tag 的 major 必须与 module path 的 `/vN` 后缀一致。
8. 弃用只有一种机制：`Deprecated:` 注释段落 + staticcheck SA1019；删除弃用符号是破坏性变更。
9. `default.pgo` 进仓库放 main 包目录，`go build` 默认 `-pgo=auto` 自动生效，`go version -m` 里有 `build -pgo=<path>` 才算生效（实测）。
10. `internal/` 是编译器强制的边界，`pkg/` 不是；没有外部消费者就不建 `pkg/`。

## golangci-lint v2 配置

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

## CI 门禁流水线（GitHub Actions）

```yaml
name: ci
on:
  push:
    branches: [main]
  pull_request:
permissions:
  contents: read
concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: true
env:
  GOTOOLCHAIN: local        # 禁止 go 命令自动下载别的工具链：版本以 setup-go 装的为准，对不上就失败
  GOFLAGS: -trimpath        # 所有 go build/test 去掉本机路径，产物可复现

jobs:
  verify:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7
      - uses: actions/setup-go@v7
        with:
          go-version-file: go.mod   # 单一事实来源，不在 CI 里再写一遍版本号
          cache: true               # 缓存 GOMODCACHE + GOCACHE，key 由 go.sum 派生
      - name: go.mod / go.sum 必须 tidy
        run: go mod tidy -diff      # 有差异时打印 diff 并以非 0 退出
      - name: 依赖内容与 go.sum 一致
        run: go mod verify
      - run: go vet ./...
      - uses: golangci/golangci-lint-action@v9
        with:
          version: v2.13.1          # 与本地版本钉死，避免"本地过、CI 不过"
      - name: 测试（竞态 + 乱序 + 原子覆盖率）
        run: go test -race -shuffle=on -covermode=atomic -coverprofile=cover.out ./...
      - name: 覆盖率阈值
        run: |
          total=$(go tool cover -func=cover.out | awk '/^total:/ {sub("%","",$3); print $3}')
          awk -v t="$total" 'BEGIN { if (t+0 < 70) { print "覆盖率 " t "% 低于 70%"; exit 1 } }'
      - name: 漏洞扫描（只报可达调用链上的漏洞）
        run: go run golang.org/x/vuln/cmd/govulncheck@v1.7.0 ./...   # 钉版本：@latest 违反"工具版本钉死"

  build:
    needs: verify
    runs-on: ubuntu-latest
    strategy:
      matrix:
        include:
          - { goos: linux, goarch: amd64 }
          - { goos: linux, goarch: arm64 }
          - { goos: darwin, goarch: arm64 }
    steps:
      - uses: actions/checkout@v7
      - uses: actions/setup-go@v7
        with:
          go-version-file: go.mod
          cache: true
      - run: CGO_ENABLED=0 GOOS=${{ matrix.goos }} GOARCH=${{ matrix.goarch }} go build -ldflags='-s -w' -o dist/ ./cmd/...

  image:
    needs: build
    if: github.ref == 'refs/heads/main'
    runs-on: ubuntu-latest
    permissions:
      contents: read
      packages: write
    steps:
      - uses: actions/checkout@v7
      - uses: docker/setup-buildx-action@v4
      - uses: docker/login-action@v4
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}
      - uses: docker/build-push-action@v7
        with:
          push: true
          tags: ghcr.io/${{ github.repository }}:${{ github.sha }}
          cache-from: type=gha
          cache-to: type=gha,mode=max
```

- 顺序即成本：tidy / verify / vet 秒级 → lint 分钟级 → 测试 → 漏洞扫描 → 构建。便宜的先跑，先失败少花钱。
- 缓存：`setup-go` 的 `cache: true` 按 `go.sum` 哈希缓存 GOMODCACHE 与 GOCACHE，lint action 自带 golangci 缓存；不要再用 `actions/cache` 缓存一遍 `~/go`，两份缓存互相覆盖。
- `GOTOOLCHAIN=local`：go.mod 的 `go` 指令高于已安装版本时直接失败，而不是静默下载另一个工具链；保证 CI 与本地是同一版本。
- `-race` 会让 `-covermode` 默认变 `atomic`（`go help testflag`），显式写出，避免有人删掉 `-race` 后覆盖率统计悄悄变 `set`。
- `-shuffle=on` 抓测试间顺序依赖，失败输出里带 `-test.shuffle <seed>` 可复现。
- Dependabot（`.github/dependabot.yml`，实测 yq 可解析）：

```yaml
version: 2
updates:
  - package-ecosystem: gomod
    directory: /
    schedule:
      interval: weekly
    groups:
      minor-and-patch:              # 非 major 升级合成一个 PR，减少噪音
        update-types: [minor, patch]
    open-pull-requests-limit: 5
  - package-ecosystem: github-actions
    directory: /
    schedule:
      interval: monthly
```

- GitLab CI 差异点：`image: golang:1.27`；`variables: { GOMODCACHE: $CI_PROJECT_DIR/.go/pkg/mod }` + `cache: { key: $CI_COMMIT_REF_SLUG, paths: [.go/pkg/mod] }`；lint 用 `image: golangci/golangci-lint:v2.13.1`；`coverage: '/^total:\s+\(statements\)\s+(\d+\.\d+)%/'` 让 MR 显示覆盖率；`rules: - if: $CI_PIPELINE_SOURCE == "merge_request_event"`。

## Makefile

```make
GO        ?= go
COVER_MIN ?= 70
VERSION   := $(shell git describe --tags --always --dirty 2>/dev/null || echo dev)
LDFLAGS   := -s -w -X main.version=$(VERSION)

.PHONY: all tidy lint test cover vuln build release-check pgo-refresh

all: tidy lint test build

tidy:                       ## go.mod 不干净即失败（不自动改）
	$(GO) mod tidy -diff

lint:
	$(GO) vet ./...
	golangci-lint run ./...

test:
	$(GO) test -race -shuffle=on -covermode=atomic -coverprofile=cover.out ./...

cover: test                 ## 覆盖率低于 COVER_MIN 即失败
	@total=$$($(GO) tool cover -func=cover.out | awk '/^total:/ {sub("%","",$$3); print $$3}'); \
	awk -v t="$$total" -v m="$(COVER_MIN)" 'BEGIN { if (t+0 < m+0) { printf "覆盖率 %s%% 低于 %s%%\n", t, m; exit 1 } }'

vuln:
	govulncheck ./...

build:
	CGO_ENABLED=0 $(GO) build -trimpath -ldflags '$(LDFLAGS)' -o bin/ ./cmd/...

release-check:              ## 打 tag 前必须过：工作区干净 + tag 与 go.mod major 一致
	@test -z "$$(git status --porcelain)" || { echo "工作区不干净，禁止发版"; git status --short; exit 1; }
	@echo "$(TAG)" | grep -qE '^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$$' || { echo "用法: make release-check TAG=v1.4.0（TAG 必须是 vMAJOR.MINOR.PATCH）"; exit 1; }
	@major=$$(echo "$(TAG)" | sed -E 's/^v([0-9]+)\..*/\1/'); mod=$$($(GO) list -m); \
	case "$$major" in \
	0|1) if echo "$$mod" | grep -qE '/v[0-9]+$$'; then echo "go.mod 带 /vN 后缀却打 v0/v1 tag"; exit 1; fi ;; \
	*)   if ! echo "$$mod" | grep -qE "/v$$major$$"; then echo "tag $(TAG) 要求 module path 以 /v$$major 结尾，当前 $$mod"; exit 1; fi ;; \
	esac

pgo-refresh:                ## 合并线上采集的 CPU profile，刷新 default.pgo
	$(GO) tool pprof -proto profiles/*.pprof > cmd/app/default.pgo
```

- `release-check` 实测：工作区不干净 → 列出文件退出 1；`TAG` 为空或不是 `vX.Y.Z` 形式（如 `TAG=foo`）→ 报用法退出 1；`TAG=v2.0.0` 而 path 无 `/v2` → 报错；`TAG=v1.4.0` 而 path 带 `/v2` → 报错；`TAG=v3.0.0` 在 `/v2` 上同样报错（本仓库也不发 v3）；匹配时退出 0。
- `$$` 是 make 转义，awk 里的 `$$3` 到 shell 才是 `$3`；`case` 分支里用 `if`，`cmd && { ...; exit 1; }` 形式在 cmd 失败时会让分支以非 0 结束（这是上一版的 bug）。

## 依赖治理

- `go mod tidy -diff`（门禁）、`go mod verify`（本地缓存与 go.sum 一致，输出 `all modules verified.`）、`go mod why -m <mod>`（谁引入的）、`go mod graph | grep <mod>`（多版本来源）、`go list -m -u -json all`（`Update` 有新版、`Deprecated` 非空是模块作者已弃用、`Retracted` 撤回版本，`go help list`）。
- 私有模块：`GOPRIVATE=*.corp.example.com,github.com/yourorg/*` 同时作用于 `GONOPROXY` 与 `GONOSUMDB`，glob 用 `path.Match` 语法（`go help private`）；`GOPROXY=https://goproxy.cn,direct`，`direct` 回落走 VCS，需要 `git config url."ssh://git@github.com/".insteadOf "https://github.com/"` 或 `GOAUTH`（`go help goauth`）。
- `GOFLAGS` 是空格分隔的默认 flag，只对认识该 flag 的子命令生效（`go help environment`）；`-mod=vendor` 放进 GOFLAGS 会让没有 vendor 目录的仓库全部命令报错，写在 Makefile 里更可控。
- `replace` 边界：只用于本地调试与临时 fork 修 bug；进 main 的 replace 必须指向已发布的 fork tag 并注明移除条件。库里的 replace 对下游无效（只有主模块的 replace 生效）——这是它最大的陷阱。
- `go.work`：`go work init ./api ./lib` 多模块联调，api 直接用 lib 的工作区版本；go.work 不进仓库，CI 用 `GOWORK=off` 验证 go.mod 声明的版本真的能编过（`go help environment`）。
- `tool` 指令（`go help tool`）：`go get -tool golang.org/x/vuln/cmd/govulncheck@v1.1.4` 把工具版本钉进 go.mod，`go tool govulncheck ./...` 全员同版本；代价是工具的依赖进 go.sum。
- govulncheck 实测输出把"你的代码调用到的漏洞"与"import 的包里有但没调用"分开报，后者只提示不算失败；比按包名匹配的扫描器误报少一个量级。`-mode=binary` 可扫已发布的二进制。

## API 兼容性与版本

`apidiff` 实测（旧、新版本各在自己目录里导出）：

```
$ apidiff -w old.export example.com/lib      # 在旧版本目录
$ apidiff -w new.export example.com/lib      # 在新版本目录
$ apidiff -incompatible old.export new.export
- (*Client).Get: changed from func(string) string to func(context.Context, string) string
- Legacy: removed
```

- 不加 `-incompatible` 还会列 `Compatible changes:`（新增字段、新增函数）。退出码始终 0，门禁要判断输出为空：`test -z "$(apidiff -incompatible old.export new.export)"`。`-m` 直接比两个模块路径。
- 语义化版本：MAJOR 破坏、MINOR 新增、PATCH 修复；v0.x 允许破坏但同样写 CHANGELOG；`+incompatible` 后缀是没有 go.mod 的 v2+ 模块，尽快让上游补 go.mod 或 fork。
- 破坏性变更的唯一允许形态（不升 major）：旧的危险行为改成显式报错，错误信息里写出路。例：`Timeout=0` 原表示不超时，改为 `return nil, errors.New("Timeout 必须 > 0；原来的 0 表示不超时，请显式传 time.Hour 或用 WithNoTimeout()")`。把 0 静默变成 30s 是禁止的静默改语义。CHANGELOG 条目以 ⚠ 开头并附迁移步骤。
- `Deprecated:` 独立段落、以 `Deprecated:` 开头、写替代品与保留承诺。`go doc` 照常列出弃用符号（实测，只有 `-all` 才显示 Deprecated 段），所以弃用的执行力只来自 staticcheck SA1019 在调用处报（`staticcheck -explain SA1019`）与 gopls 的删除线：

```go
// Fetch 拉取一条记录。
//
// Deprecated: 不带 ctx 无法取消与超时，改用 FetchContext。本函数保留为转发调用，
// 不会在当前 major 线上删除（本仓库不发新 major）。
func Fetch(id string) ([]byte, error) { return FetchContext(context.Background(), id) }

// FetchContext 拉取一条记录，ctx 控制超时与取消。
func FetchContext(ctx context.Context, id string) ([]byte, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	return []byte(id), nil
}
```

## 发布纪律

- 顺序：`git status --porcelain` 为空 → CHANGELOG 已写本版 → `apidiff` 无 incompatible 或已 ⚠ 标注 → `make release-check TAG=vX.Y.Z` → `git tag -a vX.Y.Z -m "..."` → push tag。任何一步失败停下，不跳。
- `/v2` 模块只能打 `v2.x.y`；打了 `v2.0.0` 而 path 无 `/v2`，`go get` 会当作 `+incompatible` 或拒绝。
- goreleaser 要点：`builds.env: [CGO_ENABLED=0]`、`flags: [-trimpath]`、`ldflags: -s -w -X main.version={{.Version}}`、`mod_timestamp: "{{ .CommitTimestamp }}"` 让构建可复现；`goreleaser release --snapshot --clean` 在非 tag 提交上验证配置；`changelog.filters.exclude: ['^docs:', '^test:']`。
- CHANGELOG 只写已实现的能力与迁移说明；`Unreleased` 段随每个 PR 更新，发版时改成版本号与日期。

## PGO 流程

1. 线上采集：高峰期对 2~3 个实例各拉一次 `/debug/pprof/profile?seconds=30`（pprof 端点挂内部端口，见 go-observability）。
2. 合并：`go tool pprof -proto a.pprof b.pprof > cmd/app/default.pgo`——pprof 接受多个 source 并合并（实测两份 3~4 KB 的 profile 合成 4.7 KB）。
3. 放 main 包目录，`go build` 默认 `-pgo=auto` 自动拾取（`go help build`）；实测 `go version -m app` 输出 `build -pgo=/abs/path/cmd/app/default.pgo`，没有文件或 `-pgo=off` 时没有这一行。
4. 只对 main 包目录的 `default.pgo` 生效，作用于该 main 的全部依赖（`go help build`）；库项目不放 pgo 文件。
5. 每个大版本或每季度刷新；CI 加 `test -f cmd/app/default.pgo` 防误删。收益量化与原理见 go-performance。

## 代码规范落地

- 格式只认工具：`gofumpt`（gofmt 超集：去多余空行、`0o` 八进制、合并 var 声明）+ `goimports -local example.com/app` 分组，都在 golangci `formatters` 里。
- pre-commit 钩子只跑秒级检查：`gofumpt -l`、`goimports -l`、`go vet ./...`、`go mod tidy -diff`；全量 lint 与测试放 CI，钩子超过 10s 就会被 `--no-verify` 绕过。
- `go generate` 产物进仓库，CI 里 `go generate ./... && git diff --exit-code` 抓"改了 proto / sqlc 没重新生成"。
- `//go:build integration` + `go test -tags integration` 隔离集成测试；平台文件用 `_linux.go` 后缀而不是手写约束；`go vet` 的 `buildtag` 分析器抓位置写错的约束。
- `internal/`：`example.com/app/internal/...` 只能被 `example.com/app/...` 导入，编译器强制；库要暴露半公开 API 时用 `internal/` + 顶层薄包装，不靠"请勿使用"注释。

## 项目布局与依赖方向

```
cmd/<app>/main.go       只做装配：读配置、建依赖、启动
internal/handler        HTTP/gRPC 入参出参、DTO；只依赖 service
internal/service        业务规则；依赖 repository 接口与领域类型
internal/repository     DB/Redis/MQ 访问；不依赖 handler/service，不 import gin
internal/platform       日志、配置、可观测性初始化
```

- 依赖方向用 depguard 固化（上面配置的 `layering` 规则）：违反即 lint 失败，比口头约定可靠。`go-arch-lint` 能检查更复杂的分层并画依赖图，但多一个工具；只有三层时 depguard 足够。
- 接口定义在使用方：service 定义 `OrderRepo` 接口，repository 实现，service 测试不需要 DB。
- `pkg/` 只在有外部模块消费时存在；单体服务全放 `internal/`。

## 何时不该加门禁

| 场景 | 选择 | 理由 |
|---|---|---|
| ≤ 3 人、每周发布数次的内部工具 | tidy-diff + vet + `test -race`，不上 golangci 全量 | 每个红叉都要人修，修 lint 的时间超过它抓住的 bug 成本 |
| 覆盖率阈值 | 设"不低于上一版"而不是绝对值 | 绝对阈值逼人写无断言测试凑数 |
| 多平台构建矩阵 | 只构建真实部署的平台 | 每个平台一次全量编译，没人部署的平台是白烧 |
| apidiff | 只对有外部消费者的库开 | 单体服务的导出 API 没有兼容承诺 |

## 治理审查清单

- [ ] `.golangci.yml` 是 `version: "2"`、`default: none` 白名单，每个 linter 有一句"抓什么"
- [ ] CI 含 `go mod tidy -diff`、`go mod verify`、`go vet`、golangci-lint、`go test -race -shuffle=on -covermode=atomic`、govulncheck
- [ ] 工具版本钉死（lint action `version:`、`tool` 指令或 Makefile 变量），无裸 `@latest`
- [ ] `GOTOOLCHAIN=local`，Go 版本只在 go.mod 一处
- [ ] `GOPRIVATE` 覆盖全部私有模块前缀
- [ ] `replace` 只指向已发布 tag 且写了移除条件；go.work 不进仓库
- [ ] 导出 API 变更跑过 `apidiff -incompatible`；破坏性变更是 fail-closed 形态且 CHANGELOG 有 ⚠
- [ ] 弃用符号有 `Deprecated:` 段落与替代品，没有直接删除
- [ ] 发版前工作区干净、tag major 与 module path 一致、不发 v3+
- [ ] `default.pgo` 在 main 包目录且 `go version -m` 能看到 `-pgo=`
- [ ] `go generate` 产物与源一致（CI diff 检查）
- [ ] repository 层不 import HTTP 框架（depguard 规则在跑）
