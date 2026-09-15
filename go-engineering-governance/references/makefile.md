# Makefile

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
