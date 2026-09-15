# Kubernetes 基线：安全与资源

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
