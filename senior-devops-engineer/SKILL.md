---
name: senior-devops-engineer
description: 资深运维/SRE 判断与排查步骤：Linux 内核参数、容器与 cgroup、Kubernetes 编排与探针、发布策略、Prometheus 告警、SLO 与事故复盘、云成本。处理服务器、容器、K8s、监控或线上故障问题时使用。
---

# 资深运维 / DevOps / SRE 工程师

面向基础设施、容器编排、发布、监控告警与线上故障的工程判断；脚本写法归 shell-scripting，网关 Lua 归 openresty-patterns。

## 工作方式
- 先给判断与推荐方案，再给备选与取舍；不确定就说不确定并给出核实方法，不奉承不迎合。
- 代码可直接编译运行、带错误处理，关键决策注释写 why；审查按正确性 → 健壮性 → 性能 → 可维护性排序，每个问题附修复代码。

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

## 按任务读取

以下内容按任务读取，只读本次需要的文件；核心规则与审查清单已覆盖其结论。

| 任务 | 读 |
|---|---|
| 写或审查 K8s 清单：安全上下文、资源、探针、PodSecurity | `references/kubernetes.md` |
| 写 Nginx 反向代理配置 | `references/nginx.md` |
| 写 Docker Compose | `references/compose.md` |
| 写运维脚本骨架（规则见 shell-scripting） | `references/ops-script.md` |
| 定 SLO、错误预算与告警分级 | `references/slo.md` |

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

## 发布与变更

- 滚动：`maxSurge: 25%`、`maxUnavailable: 0`，readiness 作为放量闸门，`minReadySeconds: 10` 防止刚起就被算成可用。金丝雀用 Argo Rollouts/Flagger 或 ingress-nginx canary 注解，权重 1 → 5 → 25 → 50 → 100，每步看 5xx 率与 P99，越过阈值自动回滚。
- 优雅关闭时序：Pod 删除 → Endpoint 摘除（异步）与 preStop 同时开始 → SIGTERM → 应用停收新请求、排空 → 超过 grace 被 SIGKILL。preStop sleep 5–10s 就是等第一步。
- 回滚：`kubectl rollout undo` / `helm rollback` 只回代码，不回 ConfigMap 与数据库；配置变更和代码变更分开发布，DB 迁移向后兼容。Docker Hub 匿名拉取有限额，节点与 CI 配镜像加速或私有仓库。

压测与烤机脚本里任何"故意占满 CPU"的命令（`stress-ng`、`yes > /dev/null`、忙循环），必须同时挂看门狗与 `ulimit -t` 两道自毁保险，不能只靠 `trap` 清理——写法见 shell-scripting。

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
