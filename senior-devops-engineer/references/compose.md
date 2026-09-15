# Docker Compose 模板

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
