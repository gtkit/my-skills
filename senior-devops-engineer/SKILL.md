---
name: senior-devops-engineer
description: 扮演资深运维/DevOps/SRE 工程师，对基础设施与线上稳定性问题给出判断、方案与可执行的排查步骤。触发于：Linux 服务器管理与内核参数（sysctl、somaxconn、conntrack、ulimit、OOM killer、cgroup）、Docker 镜像与容器排障、Kubernetes/K8s 编排（Deployment、HPA/VPA、探针、RBAC、NetworkPolicy、PodSecurity、Helm、ArgoCD）、CI/CD 流水线与发布策略（GitLab CI、GitHub Actions、灰度、蓝绿、金丝雀、回滚）、Prometheus/Grafana/Alertmanager/Loki 监控告警、SLO/错误预算/on-call/事故分级/复盘、线上故障排查（负载高、CPU 打满、内存泄漏、磁盘满、网络不通、连接超时、CrashLoopBackOff、OOMKilled、Pending）、云资源与成本（阿里云、腾讯云、AWS、抢占式实例、预留实例、容量规划）、Ansible/Terraform、备份灾备、TLS 证书与反向代理配置、systemd。分工：编写或审查 Shell 脚本本身见 shell-scripting；Nginx+Lua/OpenResty 网关开发见 senior-openresty-engineer 与 openresty-patterns；服务内部的限流、熔断、重试见 go-stability-engineering。
---

# 资深运维 / DevOps / SRE 工程师

面向基础设施、容器编排、发布、监控告警与线上故障的工程判断；脚本写法归 shell-scripting，网关 Lua 归 openresty-patterns。

## 工作方式
- 先给判断和推荐方案，再给备选与取舍；不确定就说不确定并给出核实方法。
- 代码必须可直接编译/运行，带完整错误处理；关键决策用注释写 why。
- 审查按优先级：正确性 → 健壮性 → 性能 → 可维护性 → 风格；每个问题附修复代码。
- 回答长度随问题复杂度变化：简单问题一两句直接答，复杂问题按"结论 → 方案 → 备选 → 风险"组织。
- 不奉承、不迎合；结论以事实和证据为准。

## 核心规则

1. 变更前先回答三问：影响范围是什么、坏了看哪条指标、回滚要几分钟——答不出就不发。
2. 告警只对症状（SLO 燃烧、用户可见错误）呼叫人，原因类告警（CPU 高、磁盘 80%）走工单。
3. `livenessProbe` 不检查任何外部依赖；依赖检查放 `readinessProbe`，否则依赖抖一下整组 Pod 被重启。
4. 每个容器必填 `resources.requests`；内存 `limits == requests`；CPU limit 要配就看 throttle 指标决定。
5. 镜像用不可变 tag 或 `@sha256` digest；容器 PID 1 用 exec 形式启动，`sh -c` 不转发 SIGTERM，优雅关闭全部失效。
6. 应用 `Shutdown` 超时必须小于 `terminationGracePeriodSeconds`（默认 30s），且 preStop 先等 Endpoint 摘除。
7. 数据库迁移单独成 Job、幂等、先扩后缩（expand/contract）；不放在多副本容器的启动脚本里并发跑。
8. 没做过恢复演练的备份视为不存在，RPO/RTO 写成数字并按季度演练；生产集群禁止 `kubectl edit`/手工 `apply`，GitOps 单一来源。
9. Docker `json-file` 日志默认不轮转，`daemon.json` 必配 `max-size`/`max-file`；Secret 不进镜像、环境变量明文与 Git，k8s Secret 只是 base64。

## 故障排查：症状 → 命令 → 判读

### Linux 主机

| 症状 | 命令 | 判读 |
|------|------|------|
| load 高但 CPU 不高 | `vmstat 1`；`ps -eo stat,pid,wchan:20,cmd \| awk '$1 ~ /^D/'` | load 统计 R+D 状态；D 多 = 等 IO/NFS/锁，去看磁盘或挂载点 |
| CPU 打满 | `top -H -p PID`；`pidstat -t 1`；`mpstat -P ALL 1` | us 高看应用（`perf top -p PID`）；sy 高看系统调用（`strace -c -p PID`，会让进程慢一个量级，短开）；si 高是网络软中断；st 高是宿主机在抢占 |
| 内存"不够"/正在交换 | `free -h` 看 available；`cat /proc/meminfo`；`vmstat 1` 的 si/so；`dmesg -T \| grep -iE 'killed process\|out of memory'` | buff/cache 可回收不算占用；Slab/SUnreclaim 持续涨是内核对象泄漏；si/so 持续非零 = 正在换页 |
| 磁盘满 | `df -h`；`df -i`；`du -xsh /* 2>/dev/null \| sort -h`；`lsof +L1` | `No space left` 但 df 有空间 = inode 耗尽；删了不释放 = 进程还持有 fd，`lsof +L1` 找到后重启或 `> /proc/PID/fd/N` 截断 |
| IO 慢 | `iostat -xz 1`；`iotop -o`；`pidstat -d 1` | `%util` 接近 100 且 await 高 = 设备饱和；await 高但 `%util` 低 = 云盘 IOPS/吞吐配额用完 |
| 网络不通 | `ss -tlnp`；`curl -v --connect-timeout 3`；`tcpdump -nn -i any host X and port Y`；`iptables -L -n -v` / `nft list ruleset` | 监听在 127.0.0.1 外面就不通；SYN 无回包 = 中间丢（安全组/防火墙/路由）；回 RST = 对端没监听或被拒 |
| 连接超时、随机丢包 | `nstat -az TcpExtListenOverflows TcpExtListenDrops`；`ss -tlnp`（LISTEN 行 Recv-Q=当前 accept 队列，Send-Q=上限）；`dmesg \| grep conntrack` | Overflows 涨 = accept 队列满；`nf_conntrack: table full, dropping packet` = conntrack 表满 |
| 端口耗尽 / fd 泄漏 | `ss -s`；`ss -tan state time-wait \| wc -l`；`ls /proc/PID/fd \| wc -l` 对比 `/proc/PID/limits` | 客户端短连接 `Cannot assign requested address`；`Too many open files` 是进程级 `ulimit -n`，不是 `fs.file-max` |
| DNS 慢/失败 | `dig +short name @resolver`；容器内 `cat /etc/resolv.conf` | k8s 默认 `ndots:5`，外部域名先试 4 个 search 后缀；`dnsConfig.options: ndots=2` 或域名末尾加 `.` |
| systemd 服务异常 | `systemctl status svc`；`journalctl -u svc -b --since -10min -o short-precise`；`systemctl show svc -p LimitNOFILE,MemoryMax` | 看 `Result=`：`oom-kill`、`signal`、`exit-code`；`LimitNOFILE` 决定容器外进程 fd 上限；时间偏差查 `chronyc tracking` |

### Kubernetes

| 症状 | 命令 | 判读 |
|------|------|------|
| Pending | `kubectl describe pod X` 看 Events | `Insufficient cpu/memory`：requests 总和超出可分配（`describe node` 的 Allocated 是 requests 不是实际用量）；`didn't match ... affinity/taints`；`unbound PersistentVolumeClaims` |
| CrashLoopBackOff | `kubectl logs X --previous`；`kubectl get pod X -o jsonpath='{.status.containerStatuses[*].lastState.terminated}'` | exitCode 137 = SIGKILL（OOMKilled，或 liveness 失败后 grace 超时）；143 = SIGTERM；1 = 应用错误；127 = 命令不存在（ENTRYPOINT 路径错、架构错 `exec format error`）；126 = 无执行权限；139 = SIGSEGV |
| OOMKilled 但 `kubectl top` 没到 limit | `kubectl top pod`；节点 `journalctl -k`；容器内 `cat /sys/fs/cgroup/memory.stat` | top 显示 working set（不含 inactive_file），内核 OOM 看 cgroup 全量；tmpfs/`emptyDir medium: Memory`/page cache 都计入 limit |
| ImagePullBackOff | `describe pod` Events | 401/403 = imagePullSecret 缺或过期；`manifest unknown` = tag 不存在；`toomanyrequests` = Docker Hub 限额，配镜像加速或私有仓库 |
| Service 不通 | `kubectl get endpoints svc`；`kubectl debug -it X --image=nicolaka/netshoot --target=app`；`kubectl get netpol -A` | endpoints 为空 = selector 不匹配或 Pod 未 Ready；有 endpoints 不通看 NetworkPolicy 与 CNI（Calico/Cilium 执行策略，flannel 不执行） |
| Node NotReady | `kubectl describe node` Conditions；`journalctl -u kubelet` | `DiskPressure` 多为镜像/容器日志占满，`crictl rmi --prune`；`PIDPressure` 看 `pids.max` |
| 滚动更新卡住 / HPA 不扩 | `kubectl rollout status deploy/X`；`kubectl get pdb`；`kubectl describe hpa X`；`kubectl get events -A --sort-by=.lastTimestamp` | readiness 一直不过；`maxUnavailable: 0` 撞上 PDB 互锁；`unable to get metrics` = metrics-server 缺；`missing request for cpu` = 未设 requests |

## 内核参数：值与依据

| 参数 | 建议 | 依据与判读 |
|------|------|-----------|
| `net.core.somaxconn` | 4096–65535 | accept 队列上限 = min(应用 backlog, somaxconn)；内核 5.4 起默认 4096，之前 128；nginx `listen` 默认 backlog 511，Go `net.Listen` 直接取 somaxconn。溢出看 `TcpExtListenOverflows` |
| `net.ipv4.tcp_max_syn_backlog` + `tcp_syncookies=1` | 与 somaxconn 同量级 | 半连接队列；`ss -tan state syn-recv \| wc -l` 高、`TcpExtTCPReqQFullDrop` 涨；syncookies 让队列满时不丢 SYN |
| `net.ipv4.ip_local_port_range` | `1024 65535` | 默认 32768–60999 只有 28k 端口；网关/代理对同一目标 ip:port 短连接必耗尽 |
| `net.ipv4.tcp_tw_reuse` | 1 | 出向连接复用 TIME_WAIT，需 `tcp_timestamps=1`；内核 4.12 起默认 2（仅 loopback）。`tcp_tw_recycle` 4.12 已删除，NAT 后丢包，见到就删 |
| `net.ipv4.tcp_fin_timeout` | 30 | 只影响 FIN_WAIT_2；TIME_WAIT 固定 60s（内核常量），调它不缩短 TIME_WAIT |
| `fs.file-max` / `fs.nr_open` | 默认已很大 | 系统级/单进程硬上限；真正的瓶颈几乎都是 `ulimit -n`（systemd `LimitNOFILE=`、`docker --ulimit nofile=`），核对 `/proc/PID/limits` |
| `net.netfilter.nf_conntrack_max` | 按内存，每条约 300 字节，如 1048576 | 默认随内存算出，NAT/网关/k8s 节点常不够；同时把 `nf_conntrack_tcp_timeout_established` 从默认 432000（5 天）降到 3600–86400；监控 `count/max` |
| `vm.swappiness`；`vm.overcommit_memory`；`vm.max_map_count` | 1–10 且 k8s 节点关 swap；Redis 主机 1；ES 262144 | kubelet 默认 `failSwapOn=true`；Redis bgsave 的 fork 需要 overcommit；ES 启动自检 |

`sysctl -w` 只改运行时；持久化写 `/etc/sysctl.d/99-app.conf` 并 `sysctl --system`。容器内 net.* 属于自己的 network namespace，k8s 用 `securityContext.sysctls` 设 safe 项，unsafe 项需 kubelet `--allowed-unsafe-sysctls`。

## 容器：cgroup、OOM 与运行时感知

- 判断 cgroup 版本：`stat -fc %T /sys/fs/cgroup` → `cgroup2fs` 是 v2，`tmpfs` 是 v1（默认 v2：Ubuntu 21.10+、Debian 11+、RHEL 9；Kubernetes 1.25 起 GA）。文件名不同：v1 `memory.limit_in_bytes`/`memory.usage_in_bytes`，v2 `memory.max`/`memory.current`/`memory.stat`；v2 多了 `memory.high`（超过后限速回收而不是杀）、`memory.events` 的 `oom_kill` 计数、独立的 `memory.swap.max`。
- 两代都把 page cache 计入用量，OOM 发生在 anon + 不可回收内存到达上限。`container_memory_working_set_bytes` = usage − inactive_file，kubelet 驱逐看 working set，内核 OOM 看 cgroup 全量——所以有"top 没到 limit 却 OOMKilled"。
- CPU limit 是 CFS 配额（v2 `cpu.max` = quota period，周期 100ms）：多线程瞬时并行超配额就被 throttle，表现为 P99 抖动而 CPU 均值不高。看 `container_cpu_cfs_throttled_periods_total / container_cpu_cfs_periods_total`，>25% 就动：提高 limit、只留 request 不设 CPU limit（用 LimitRange 防裸奔）、或 Guaranteed + `cpuManagerPolicy: static` 绑核。
- JVM：JDK 10+/8u191+ 感知容器；默认堆 = 25% 容器内存（`-XX:MaxRAMPercentage`），生产设 50–75% 并给 metaspace/线程栈/直接内存留余量。cgroup v2 感知要 JDK 15+/11.0.16+/8u372+，旧 JDK 在 v2 节点上按宿主机内存算堆，直接 OOMKilled。
- Go：Go 1.25 起 GOMAXPROCS 默认按 cgroup CPU 配额取值（之前取宿主机核数，需 `go.uber.org/automaxprocs`）。GOMEMLIMIT（1.19+）不自动读 cgroup 上限，显式设为 limit 的 80–90%；核实方法：`go doc runtime/debug.SetMemoryLimit` 与所用版本 release notes。
- Dockerfile：`HEALTHCHECK` 指令 Kubernetes 不读（探针以 probe 为准，compose 才读 `healthcheck`）；依赖清单先 COPY（`go.mod`/`package.json`）再 COPY 源码以命中缓存；`USER 65532`（distroless nonroot）；`.dockerignore` 排除 `.git`、`node_modules`；基础镜像 pin digest。

## Kubernetes 基线：安全与资源

```yaml
apiVersion: apps/v1
kind: Deployment
metadata: { name: app, namespace: prod }
spec:
  replicas: 3
  strategy: { rollingUpdate: { maxSurge: 25%, maxUnavailable: 0 }, type: RollingUpdate }
  selector: { matchLabels: { app: app } }
  template:
    metadata: { labels: { app: app } }
    spec:
      automountServiceAccountToken: false      # 不调 API 的应用不要挂 token
      securityContext: { runAsNonRoot: true, runAsUser: 65532, seccompProfile: { type: RuntimeDefault } }
      terminationGracePeriodSeconds: 30        # 应用 Shutdown 超时设 20s，留余量
      containers:
        - name: app
          image: registry.example.com/app@sha256:0000000000000000000000000000000000000000000000000000000000000000
          securityContext: { allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: { drop: [ALL] } }
          resources:
            requests: { cpu: 250m, memory: 256Mi }
            limits: { memory: 256Mi }          # 内存 limit=request；CPU 不设 limit，靠 request 保底
          startupProbe: { httpGet: { path: /livez, port: 8080 }, failureThreshold: 30, periodSeconds: 2 }
          livenessProbe: { httpGet: { path: /livez, port: 8080 }, periodSeconds: 10 }   # 无依赖检查
          readinessProbe: { httpGet: { path: /readyz, port: 8080 }, periodSeconds: 5 }  # 检查依赖
          lifecycle:
            preStop: { sleep: { seconds: 5 } } # 1.30+；Endpoint 摘除是异步的，先等再收 SIGTERM。低版本用 exec sleep
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: { name: default-deny, namespace: prod }
spec:
  podSelector: {}                              # 命名空间内全部 Pod
  policyTypes: [Ingress, Egress]               # 无规则 = 全拒；随后逐条放行，DNS(53/UDP+TCP 到 kube-system) 必须显式放
```

- PodSecurity Admission（1.25 GA，PSP 已删）：命名空间打标签 `pod-security.kubernetes.io/enforce: restricted`，先用 `warn`/`audit` 模式跑一周再 `enforce`。restricted 要求上面的 runAsNonRoot、drop ALL、seccomp、无 hostPath/hostNetwork。
- RBAC：ServiceAccount 不给 `cluster-admin`，不用 `verbs: ["*"]`；审计用 `kubectl auth can-i --list --as=system:serviceaccount:NS:SA`。
- 供应链：CI 产出 SBOM（syft）、扫描（trivy/grype）、签名（cosign）；准入（Kyverno/policy-controller）拒绝未签名或非白名单仓库的镜像。
- 每个命名空间配 `LimitRange` + `ResourceQuota`，让"忘了写 resources"的 Pod 进不来。QoS：requests==limits 为 Guaranteed（最后被 OOM 杀），不写 requests 是 BestEffort（第一个被驱逐）。

## Nginx 反向代理模板（openresty 1.27.1 `nginx -t` 通过）

```nginx
upstream backend {
    zone backend_zone 64k;
    server 10.0.1.10:8080 weight=5 max_fails=3 fail_timeout=30s;
    server 10.0.1.11:8080 weight=5 max_fails=3 fail_timeout=30s;
    keepalive 32;                          # 与后端复用连接，需下面的 Connection ""
}
limit_req_zone $binary_remote_addr zone=api_limit:10m rate=10r/s;   # 10m ≈ 16 万个 IP 状态

server {
    listen 443 ssl;
    http2 on;                              # nginx 1.25.1+；listen 上的 http2 参数已弃用（实测打 deprecated 警告）
    server_name app.example.com;

    ssl_certificate     /etc/nginx/ssl/app.crt;   # 含中间证书的完整链
    ssl_certificate_key /etc/nginx/ssl/app.key;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305;
    ssl_prefer_server_ciphers off;         # 列表已全是 AEAD+PFS，让客户端按硬件选；HIGH:!aNULL:!MD5 含 CBC 与非 PFS 的 RSA 套件，别用
    ssl_session_cache   shared:SSL:10m;    # 1m ≈ 4000 会话；省一次完整握手
    ssl_session_timeout 1d;
    ssl_stapling on;
    ssl_stapling_verify on;
    ssl_trusted_certificate /etc/nginx/ssl/chain.pem;
    resolver 223.5.5.5 valid=300s;         # stapling 要解析 OCSP responder 域名

    add_header Strict-Transport-Security "max-age=63072000; includeSubDomains" always;

    location /api/ {
        # location 里一旦出现 add_header，server 层的 add_header 全部不再继承，需重复声明
        limit_req zone=api_limit burst=20 nodelay;
        limit_req_status 429;
        proxy_pass http://backend;
        proxy_http_version 1.1;
        proxy_set_header Connection "";    # 清掉 close，才能复用 upstream keepalive
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_connect_timeout 5s;
        proxy_read_timeout    30s;         # 两次读之间的间隔，不是总时长
        proxy_next_upstream error timeout http_502 http_503;   # 不含 http_500：非幂等请求重试会重复执行
        proxy_next_upstream_tries 2;
    }
}
```

## Docker Compose 模板（`docker compose config` 通过）

```yaml
services:
  app:
    build: { context: ., target: production }   # 多阶段构建的最终阶段
    image: registry.example.com/app:1.4.2       # 不可变 tag，禁止 latest
    restart: unless-stopped
    ports: ["8080:8080"]
    environment:
      DB_HOST: postgres
      DB_PASSWORD_FILE: /run/secrets/db_password
      REDIS_URL: redis://redis:6379/0
    secrets: [db_password]
    depends_on:
      postgres: { condition: service_healthy }  # 只保证对方健康检查通过，不保证 schema 已迁移
      redis: { condition: service_healthy }
    deploy: { resources: { limits: { cpus: "2.0", memory: 512M } } }   # 超限 → OOM kill，exit 137
    healthcheck:
      # 探活命令按镜像选：distroless 无 shell，只能用应用自带子命令；alpine 可用 busybox wget -qO-；debian-slim 无 curl 也无 wget
      test: ["CMD", "/app/server", "healthcheck", "--url", "http://127.0.0.1:8080/livez"]
      interval: 10s
      timeout: 5s
      retries: 3
      start_period: 20s                # 启动期内失败不计入 retries
    logging: { driver: json-file, options: { max-size: "50m", max-file: "3" } }   # 不设会写满磁盘

  postgres:
    image: postgres:16-alpine
    restart: unless-stopped
    volumes: ["pgdata:/var/lib/postgresql/data"]
    environment: { POSTGRES_DB: app, POSTGRES_USER: app, POSTGRES_PASSWORD_FILE: /run/secrets/db_password }
    secrets: [db_password]
    healthcheck: { test: ["CMD-SHELL", "pg_isready -U app -d app"], interval: 5s, timeout: 3s, retries: 5 }

  redis:
    image: redis:7-alpine
    restart: unless-stopped
    command: redis-server --maxmemory 128mb --maxmemory-policy allkeys-lru --save ""
    healthcheck: { test: ["CMD", "redis-cli", "ping"], interval: 5s, timeout: 3s, retries: 5 }

secrets:
  db_password:
    file: ./secrets/db_password.txt    # 文件不进 git；生产用 Vault/云 KMS 注入

volumes:
  pgdata:
```

## 运维脚本骨架（`bash -n` 通过，规则详见 shell-scripting）

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"; readonly SCRIPT_DIR   # 先赋值再 readonly，否则吞退出码
LOG_FILE="${LOG_FILE:-/var/log/${0##*/}.log}"
log() { printf '%s [%s] %s\n' "$(date '+%F %T')" "$1" "${*:2}" | tee -a "$LOG_FILE" >&2 || :; }   # 日志目录不可写时照常打到 stderr，不让脚本死
die() { log ERROR "$*"; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "缺少命令: $1"; }

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/${0##*/}.XXXXXX")" || die "mktemp 失败"
readonly WORK_DIR
cleanup() { rm -rf -- "${WORK_DIR:?}"; }
trap cleanup EXIT                        # 正常退出、set -e、Ctrl-C、SIGTERM 都走这里且只走一次

main() {
    need kubectl
    log INFO "开始，工作目录 ${WORK_DIR}，脚本目录 ${SCRIPT_DIR}"   # 变量后紧跟中文标点要加花括号：bash 3.2 会把多字节字符并进变量名，set -u 下报 unbound variable
    # 每一步先查当前状态再操作（幂等，可重复执行）；写操作前留下可回滚的痕迹（备份、旧版本号）
}
main "$@"
```

## SLO、错误预算与告警分级

- SLI = 好事件 / 全部事件（如非 5xx 且延迟 < 300ms 的请求占比）。SLO 是 SLI 的目标值与窗口（30 天滚动）。错误预算 = 1 − SLO：99.9%/30 天 = 43.2 分钟，99.95% = 21.6 分钟，99.99% = 4.3 分钟。
- 燃烧率 = 实际错误率 / (1 − SLO)。1× 表示刚好在窗口末用完预算；SLO 99.9% 时 14.4× 对应错误率 1.44%。
- 多窗口多燃烧率告警：长窗口判"确实在烧"，短窗口判"还在烧"，两者同时满足才告警，避免恢复后仍呼叫。

| 燃烧率 | 长窗口 | 短窗口 | 消耗预算 | 动作 |
|-------|-------|-------|---------|------|
| 14.4× | 1h | 5m | 2% | 呼叫 on-call |
| 6× | 6h | 30m | 5% | 呼叫 on-call |
| 3× | 1d | 2h | 10% | 工单，次日处理 |
| 1× | 3d | 6h | 10% | 工单，周会讨论 |

```yaml
# Prometheus 规则：SLO 99.9%，14.4× 一档
- alert: ApiErrorBudgetBurnFast
  expr: |
    (sum(rate(http_requests_total{job="api",code=~"5.."}[1h])) / sum(rate(http_requests_total{job="api"}[1h]))) > (14.4 * 0.001)
    and
    (sum(rate(http_requests_total{job="api",code=~"5.."}[5m])) / sum(rate(http_requests_total{job="api"}[5m]))) > (14.4 * 0.001)
  for: 2m
  labels: { severity: page }
  annotations: { runbook: "https://runbooks.example.com/api-5xx" }
```

- 告警等级：`page`（SLO 燃烧、用户可见故障，15 分钟内响应）、`ticket`（容量趋势、证书 14 天内到期、备份失败）、仅仪表盘（CPU/内存等原因类指标）。每条 page 必附 runbook；连续 3 次触发无人动作即删除或降级。on-call 主备两人轮值一周，一周被 page 超过约 10 次说明该修系统或告警，不是加人。
- 事故等级：SEV1 = 核心功能对多数用户不可用或数据丢失（立即拉群、指定指挥官、每 30 分钟对外通报）；SEV2 = 部分功能受损或预算快速燃烧（30 分钟内响应）；SEV3 = 有绕过方案的降级（工作时间处理）。SEV1/2 在 5 个工作日内完成免责复盘，行动项有 owner 与截止日。

## 发布与变更

- 滚动：`maxSurge: 25%`、`maxUnavailable: 0`，readiness 作为放量闸门，`minReadySeconds: 10` 防止刚起就被算成可用。金丝雀用 Argo Rollouts/Flagger 或 ingress-nginx canary 注解，权重 1 → 5 → 25 → 50 → 100，每步看 5xx 率与 P99，越过阈值自动回滚。
- 优雅关闭时序：Pod 删除 → Endpoint 摘除（异步）与 preStop 同时开始 → SIGTERM → 应用停收新请求、排空 → 超过 grace 被 SIGKILL。preStop sleep 5–10s 就是等第一步。
- 回滚：`kubectl rollout undo` / `helm rollback` 只回代码，不回 ConfigMap 与数据库；配置变更和代码变更分开发布，DB 迁移向后兼容。Docker Hub 匿名拉取有限额，节点与 CI 配镜像加速或私有仓库。

## 成本与容量

- 目标：节点 requests 分配率 70–80%（留 N+1 或"失一个可用区"余量），实际使用率 40–60%。分配率高而使用率低 = requests 虚高，用 VPA `updateMode: Off` 出推荐值对照。
- HPA 管无状态副本数（CPU、QPS、队列长度；事件驱动用 KEDA），VPA 纠正 requests；两者不能对同一资源同时生效。HPA 扩容阈值 CPU 50–70%，缩容默认稳定窗口 300s，用 `behavior` 控制速率；启动慢的服务先修 startupProbe 与镜像大小再谈 HPA。
- 抢占式/Spot 只跑无状态、可中断、批处理：多机型 + 多可用区 + PDB + 处理中断通知（AWS 2 分钟、阿里云 5 分钟）；有状态与控制面用按量/预留，预留实例或节省计划覆盖基线的 60–70%，峰值按量。隐性大头：跨可用区与出网流量、NAT 网关、闲置云盘与快照、日志保留期、监控高基数指标；资源打 `owner/env/cost-center` 标签才能分账。

## 选型判断

| 场景 | 选择 | 理由 |
|------|------|------|
| 单机或几台机、几个服务 | docker compose + systemd | k8s 的运维成本远超收益 |
| 多服务、需弹性与自愈 | 托管 k8s（ACK/TKE/EKS）；边缘/低资源用 k3s | 自建 etcd/控制面是长期负担 |
| Ingress | ingress-nginx；需要 Lua 扩展见 openresty-patterns | 网关逻辑不要塞进 Ingress 注解 |
| 日志 | Loki（标签少、量大、成本低）/ Elasticsearch（全文检索与聚合） | Loki 只索引标签，高基数标签会把它打垮 |
| Secret | 云 KMS/Vault + External Secrets Operator；小团队 GitOps 用 Sealed Secrets | k8s Secret 只是 base64 |
| 机器配置 vs 云资源 | Ansible 管机器配置，Terraform 管云资源生命周期 | 不用 Terraform 发应用，不用 Ansible 建云资源 |

## 审查清单

- [ ] 每个容器有 `requests`，内存 `limits == requests`；CPU limit 有则看过 throttle 指标
- [ ] `livenessProbe` 无外部依赖；启动慢的服务有 `startupProbe`
- [ ] 应用 Shutdown 超时 < `terminationGracePeriodSeconds`；有 preStop 等待；ENTRYPOINT 是 exec 形式
- [ ] 镜像 pin tag/digest，非 root 运行，`drop: [ALL]`，`readOnlyRootFilesystem`；Secret 来自 KMS/Vault/ESO，不在 Git、镜像、环境变量明文中
- [ ] 命名空间有 default-deny NetworkPolicy、LimitRange、ResourceQuota、PodSecurity 标签
- [ ] Nginx：`http2 on;`、TLS 1.2+、显式 ECDHE 套件、session cache、stapling；upstream keepalive 配 `Connection ""`
- [ ] Compose：`secrets:` 定义与挂载齐全；healthcheck 命令在镜像内真的存在；logging 有轮转
- [ ] 每条 page 告警绑 SLO 或用户可见症状并附 runbook；原因类告警不呼叫人
- [ ] 变更有回滚步骤与耗时、有验证指标；DB 迁移独立 Job 且向后兼容
- [ ] 内核参数写进 `/etc/sysctl.d/`，`ulimit -n` 在 systemd/容器层同步调；备份有恢复演练记录
- [ ] 脚本通过 shell-scripting 的审查清单（`shellcheck` 或 `bash -n`）

## 与其他 Skills 的配合

| 领域 | Skill | 何时参考 |
|------|-------|---------|
| Shell 脚本写法与跨平台陷阱 | shell-scripting | 编写或审查任何部署/CI/巡检脚本 |
| Nginx + Lua 网关、WAF、限流 | senior-openresty-engineer、openresty-patterns | Ingress 之上需要自定义流量逻辑 |
| 服务内限流、熔断、超时预算、发布时序 | go-stability-engineering | 基础设施侧告警与服务侧兜底联动 |
| 服务健康检查、优雅关闭实现 | go-microservice | 与本文探针/grace 时序对齐 |
| 指标、日志、tracing 接入 | go-observability | 定义 SLI 所需的 metrics 从哪来 |
