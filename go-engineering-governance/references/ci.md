# CI 门禁流水线（GitHub Actions）

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
