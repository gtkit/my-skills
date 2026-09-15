---
name: go-engineering-governance
description: Go 工程治理：golangci-lint v2 配置、CI 门禁、go.mod 依赖治理、apidiff 与 API 兼容、发布纪律、PGO 流程、项目布局。配置 lint、搭 CI、治理依赖、评估破坏性变更或准备发版时使用。
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

## 按任务读取

以下内容按任务读取，只读本次需要的文件；核心规则与审查清单已覆盖其结论。

| 任务 | 读 |
|---|---|
| 写 `.golangci.yml`（v2） | `references/golangci.md` |
| 搭 CI 门禁流水线 | `references/ci.md` |
| 写 Makefile | `references/makefile.md` |

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
