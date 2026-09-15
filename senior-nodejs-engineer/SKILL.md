---
name: senior-nodejs-engineer
description: 资深 Node.js 服务端判断与代码：进程生命周期与优雅关闭、ESM/CJS、事件循环阻塞与内存排查、Fastify/Express/NestJS、流与背压、数据库事务、npm 发包安全。写或审查 Node 服务端代码、排查线上问题时使用。
---

# 资深 Node.js 服务端工程师

面向生产的 Node.js：进程与运行时行为、模块系统、框架与数据库层、安全与排查。浏览器端归 senior-frontend-engineer。

## 工作方式
- 先给判断与推荐方案，再给备选与取舍；不确定就说不确定并给出核实方法，不奉承不迎合。
- 代码可直接编译运行、带错误处理，关键决策注释写 why；审查按正确性 → 健壮性 → 性能 → 可维护性排序，每个问题附修复代码。

## 版本与 LTS 策略

- 偶数版每年 10 月进入 LTS：Active 12 个月 + Maintenance 18 个月；奇数版次年 6 月即 EOL，只用于试新特性。
- 2026 年口径：Node 20 已于 2026-04 EOL；22 处于 Maintenance（到 2027-04）；**24 是 Active LTS**（2026-10 转 Maintenance，2028-04 EOL）。生产默认 24，`engines.node` + `.nvmrc`/`.node-version` 锁大版本，CI 矩阵覆盖当前 LTS 与下一个 LTS。
- `packageManager` 字段固定 pnpm/yarn 版本；Node 25 起 corepack 不再随发行版附带，需 `npm i -g corepack`。
- 容器基础镜像用 `node:24-bookworm-slim`，不用 `alpine`（musl 下原生模块要重编、DNS 解析行为不同）；`CMD ["node", "dist/server.js"]` exec 形式——`npm start` 作为父进程会改写退出码并延迟转发信号；PID 1 用 `docker run --init` 或 tini。

## 模块系统：ESM/CJS 互操作

- 新项目 `"type": "module"` 全 ESM；`.mjs`/`.cjs` 只用于显式例外。`__dirname` → `import.meta.dirname`（20.11+），`import.meta.filename`；需要 `require` 时 `createRequire(import.meta.url)`。
- `require(esm)`：22.12+ 与 20.19+ 默认可用。被 require 的 ESM 图里若有顶层 `await`，抛 `ERR_REQUIRE_ASYNC_MODULE`。`require()` 返回的是命名空间对象，CJS 调用方拿到 `{ default, ... }`；库要让 `require` 直接得到默认导出，需额外提供名为 `'module.exports'` 的具名导出。
- dual package hazard：`exports` 同时给 `import` 和 `require` 条件两份实现时，同一进程可能加载两份模块状态——`instanceof` 失败、"单例"变双份、模块级缓存不共享。当前解法：库**只发 ESM**（消费方有 require(esm)）；必须双发时以 CJS 为源、ESM 只做薄包装 re-export，或加 `"module-sync"` 条件（22.10+）。
- `node:` 前缀：`node:test`、`node:sqlite`、`node:sea` 只能带前缀；其余内建也统一带，避免被同名 npm 包或 bundler 别名劫持。
- JSON 用 import attributes：`import cfg from './cfg.json' with { type: 'json' }`（22 起 `assert` 写法移除）；顶层 `await` 仅 ESM 可用。
- 22.7+ 默认开模块语法探测：没写 `type` 的 `.js` 含 `import` 也能跑，但先按 CJS 解析失败再重试，启动变慢——显式声明 `type`。
- 声明了 `exports` 就封住深路径导入（`pkg/lib/x` 报 `ERR_PACKAGE_PATH_NOT_EXPORTED`）；发包前跑 `publint` 与 `@arethetypeswrong/cli` 检查入口与类型解析。

## TypeScript 直接在 Node 上运行

- 22.18+/23.6+ 默认开启类型擦除（`node app.ts`），22.6–22.17 需 `--experimental-strip-types`。**只擦不查**：`tsc --noEmit` 仍要在 CI 跑。
- 只支持可擦除语法：`enum`、带运行时代码的 `namespace`、构造器参数属性、`import x = require()` 不能直接跑，需 `--experimental-transform-types` 或改写；tsconfig 开 `erasableSyntaxOnly`（TS 5.8+）在编译期拦下。
- 相对导入必须带扩展名 `./foo.ts`；配 `allowImportingTsExtensions` + `rewriteRelativeImportExtensions`（TS 5.7+）让 `tsc` 产物里的路径同样正确。不支持 tsconfig `paths`，用 package.json `imports` 字段的 `#internal/*` 代替。
- `verbatimModuleSyntax: true` 强制 `import type`，否则纯类型导入擦除后变成对不存在导出的运行时引用（`SyntaxError: The requested module does not provide an export named`）。
- 是否在生产直接跑 `.ts`：脚本与小服务可以；依赖 decorator metadata 的框架（NestJS）或对冷启动敏感的服务仍走 `tsc`/`tsdown` 产物。

## 进程级错误处理与优雅关闭

- Node 15+ 未处理的 rejection 默认等同 uncaught exception → 进程退出。正确策略是**记录后退出、让编排器重启**，不是捕获后继续跑：`uncaughtException` 之后堆与句柄状态不可信（官方文档：resuming normal operation is unsafe）。
- 退出前日志必须同步落盘：pino 用 `pino.destination({ sync: true })` 作为 fatal 通道，或 `process.on('exit')` 前 `logger.flush()`；否则 `process.exit(1)` 丢最后几行，恰好是事故原因。
- `EventEmitter` 没有 `error` 监听时 emit 即 throw；`readable.pipe(writable)` 既不传播错误也不销毁另一端 → 一律 `pipeline()`（`node:stream/promises`）。
- 关闭时序（总时长 < k8s `terminationGracePeriodSeconds`，默认 30s）：
  1. 收 SIGTERM，`ready = false` 让 `/readyz` 返回 503；
  2. 等 2–5s：Endpoints 摘除是异步的，SIGTERM 之后仍有新请求进来（preStop sleep 同理）；
  3. `server.close()` 停止 accept——Node 19+ 会同时关闭空闲 keep-alive 连接，活动连接等当前响应完成；grace 到点再 `closeAllConnections()`；
  4. 关 DB 池、MQ 消费者、flush 日志与 metrics；
  5. 设 `process.exitCode` 让事件循环自然排空，`setTimeout(() => process.exit(1), N).unref()` 兜底。
- `server.keepAliveTimeout`（默认 5s）必须**大于**前置 LB 的 idle timeout（AWS ALB 默认 60s、nginx `keepalive_timeout` 默认 75s），否则 LB 复用刚被 Node 关掉的连接 → 间歇 502/`ECONNRESET`。`headersTimeout`（默认 60s）要大于 `keepAliveTimeout`；`requestTimeout` 默认 300s（18+）。

```ts
import { createServer, type Server } from 'node:http';
import { setTimeout as sleep } from 'node:timers/promises';
import { pino, destination } from 'pino';

interface Closable { close(): Promise<void> }

const logger = pino();
const fatal = pino(destination({ sync: true }));        // 退出路径专用：同步写，不丢最后一行

export function installLifecycle(server: Server, deps: Closable[], graceMs = 25_000): { isReady(): boolean } {
  let ready = true;
  let shuttingDown = false;

  async function shutdown(signal: NodeJS.Signals): Promise<void> {
    if (shuttingDown) return;
    shuttingDown = true;
    logger.info({ signal }, 'shutdown started');
    // 兜底：grace 内没排空就强退，时长必须小于 terminationGracePeriodSeconds
    const killer = setTimeout(() => { server.closeAllConnections(); process.exit(1); }, graceMs);
    killer.unref();

    ready = false;                                     // /readyz → 503
    await sleep(3_000);                                // 等 Endpoints 摘除传播
    await new Promise<void>((resolve, reject) => server.close((err) => (err ? reject(err) : resolve())));
    const results = await Promise.allSettled(deps.map((d) => d.close()));
    for (const r of results) if (r.status === 'rejected') logger.error({ err: r.reason }, 'dependency close failed');
    process.exitCode = 0;                              // 不调 process.exit(0)：让事件循环自然排空
  }

  process.on('SIGTERM', () => void shutdown('SIGTERM'));
  process.on('SIGINT', () => void shutdown('SIGINT'));
  process.on('unhandledRejection', (reason) => { fatal.fatal({ err: reason }, 'unhandledRejection'); process.exit(1); });
  process.on('uncaughtException', (err) => { fatal.fatal({ err }, 'uncaughtException'); process.exit(1); });

  return { isReady: () => ready };
}

const server = createServer((_req, res) => { res.end('ok'); });
server.keepAliveTimeout = 65_000;   // 大于 LB idle timeout（ALB 60s）
server.headersTimeout = 66_000;     // 必须大于 keepAliveTimeout
installLifecycle(server, []);
server.listen(3000);
```

## 事件循环、阻塞与线程池

- JS 单线程：任何 > 50ms 的同步工作直接抬高所有在途请求的延迟。高发点：大 JSON 的 `parse/stringify`、请求路径上的 `*Sync` fs 调用、`pbkdf2Sync`/`scryptSync`、灾难性回溯的正则、大数组 `sort`、同步 zlib。
- 度量：`perf_hooks.monitorEventLoopDelay()`（p99 > 100ms 告警）、`performance.eventLoopUtilization()`；`@fastify/under-pressure` 在 ELU/堆超阈值时直接 503，而不是排队拖垮全部请求。
- CPU 密集 → `worker_threads`（`piscina` 池），大数据用 `SharedArrayBuffer`/transfer 而非结构化拷贝；`cluster` 只复制 accept 循环，解决不了单个请求的 CPU 密集。
- libuv 线程池默认 4 线程（`UV_THREADPOOL_SIZE` 最大 1024，须在首次 I/O 前设置），`fs`、`dns.lookup`、`crypto.pbkdf2/scrypt/randomBytes`、`zlib` 共用。高并发出站 HTTP 每次 `dns.lookup`（getaddrinfo）会占满线程池，表现为**所有 fs 操作一起变慢**——用 keep-alive 连接池减少解析，或 `dns.resolve*`（c-ares，不占线程池）。
- `process.nextTick`/microtask 递归会饿死 I/O 阶段；要让出用 `setImmediate`。

## 内存排查

- 容器里 V8 老生代上限不随 cgroup 自动缩放：显式 `--max-old-space-size`（约容器 limit 的 75%），否则先被 OOMKilled，拿不到任何堆信息。
- 三个数字区分泄漏类型：`process.memoryUsage()` 的 `heapUsed` 持续增长 = JS 对象泄漏；`rss` 涨而 `heapUsed` 平 = `external`/`arrayBuffers`（Buffer、原生模块）或 glibc 碎片（试 `MALLOC_ARENA_MAX=2` 或换 jemalloc）。
- 抓快照只用内建能力：`v8.writeHeapSnapshot()`、`--heapsnapshot-signal=SIGUSR2`（线上无侵入，`kill -USR2 <pid>`）、`--heapsnapshot-near-heap-limit=3`（OOM 前自动落盘）；Chrome DevTools 加载两次快照做 Comparison，按构造函数看 Retained Size 增量。`heapdump` 包已废弃、Clinic.js 已停止维护，不再推荐。
- CPU：`--cpu-prof`（退出时写 `.cpuprofile`）或 `--inspect` 接 DevTools；`node --report-on-signal` 拿进程级诊断报告（含堆统计、句柄、libuv 状态）。
- 高发泄漏源：模块级 `Map` 缓存无上限（用 `lru-cache` 设 `max`/`ttl`）、每请求 `emitter.on()` 不 `off`（`MaxListenersExceededWarning` 是早期信号）、`setInterval` 未清、闭包捕获整个请求体、`AsyncLocalStorage` 存大对象、Promise 数组只 push 不消费。

## 流与背压

- `write()` 返回 `false` 后必须等 `drain` 再写，否则内部缓冲无限增长——"上传/导出接口把内存打爆"的成因。
- `pipeline(src, ...transforms, dst)` 处理错误传播、销毁与背压，`await pipeline(...)` 用 promises 版；`for await (const chunk of readable)` 最简洁，但循环内 `break` 会销毁流。
- 大响应用 `fs.createReadStream`/`Readable.from()` + `pipeline`，不 `readFile` 全读；Web Streams 与 Node 流互转用 `Readable.fromWeb/toWeb`，`fetch()` 的 body 是 Web Stream。
- `highWaterMark` 默认 64KiB（对象模式 16 个对象）；提高它换吞吐，代价是每个连接的常驻内存。

## HTTP 框架与出站请求

- Fastify 5（Node 20+）：JSON Schema 校验默认 `coerceTypes: 'array'`、`removeAdditional: true`、`useDefaults: true`——**未声明的字段被静默删除**；响应 schema 只序列化声明的字段（顺手防了敏感字段外泄，也是"新字段没出现在响应里"的常见原因）。插件是封装上下文：装饰器/钩子只对子上下文可见，跨上下文共享用 `fastify-plugin`。handler 用 `return payload`，不要 `reply.send()` 之后再 `await`。
- Express 5（2024-10）：路由用 path-to-regexp v8（`/*splat`、`/{:id}` 可选段，旧 `*`/`?` 写法直接报错）；async handler 抛错自动进 `next(err)`；`req.query` 变 getter。Express 4 默认 `qs` 深层解析 `a[b][c]` 有原型污染/DoS 面，用 `express.urlencoded({ extended: false })` 或限制 `parameterLimit`。
- NestJS 适合大团队与强约定，代价是 DI 容器/装饰器带来的启动时间，`Scope.REQUEST` provider 会拖累吞吐；默认 Express 适配器，换 `@nestjs/platform-fastify` 吞吐约 2 倍。Hono 用 Web 标准 `Request`/`Response`，同一代码跑 Node/Deno/Bun/Workers。
- 出站：原生 `fetch`（21+ 稳定，基于 undici）**没有默认超时**，必须 `signal: AbortSignal.timeout(ms)`；连接池用 `setGlobalDispatcher(new Agent({ connections, pipelining }))`，undici `keepAliveTimeout` 默认 4s；重试用 `undici.RetryAgent`；`redirect: 'manual'` 拦住 SSRF 跳转；HTTP 代理用 `EnvHttpProxyAgent`（24.x 起可用 `node --use-env-proxy` 让 fetch 直接读 `HTTP_PROXY`/`NO_PROXY`）。

## 数据库层

- Prisma：交互式事务 `$transaction(async (tx) => ...)` 默认 `maxWait: 2000`、`timeout: 5000`（@prisma/client 7.10.0 运行时 `?? 2e3` / `?? 5e3`）。两个超时报错不同：等不到连接开事务报 `Unable to start a transaction in the given time.`；事务体超时报 `A <op> cannot be executed on an expired transaction. The timeout for this transaction was 5000 ms, however N ms passed...`。`Transaction already closed` 是对**已提交/已回滚**事务再发查询的报错，不是超时——事务内禁止 HTTP 调用与队列投递；`update()` 的 `where` 只接受唯一字段，**条件更新用 `updateMany()` 看 `count`**；Prisma 7 起默认不带 Rust 查询引擎，需要 driver adapter（如 `@prisma/adapter-pg`）与 `prisma.config.ts`。
- Drizzle：SQL 形状的类型安全查询，`db.transaction(async (tx) => ...)`，`sql` 模板自动参数化；需要精细控制 SQL 与索引时优先。Kysely 是纯查询构造器，无迁移/schema 管理。
- `pg` 驱动默认把 `int8`/`numeric`/`decimal` 作为**字符串**返回（保护精度）。金额存整数分：范围在 `Number.MAX_SAFE_INTEGER`（约 9×10^15 分）内用 `integer`/`bigint` + `Number`，超出用 `BigInt`——但 `JSON.stringify(1n)` 抛 TypeError，序列化层要自己处理。
- 连接池 `max` 默认 10；副本数 × 池大小 必须小于 DB `max_connections`，超过就上 PgBouncer（transaction 模式下 prepared statement 要关或用 `pgbouncer=true`）；`statement_timeout` 写进连接选项。
- 扣减库存/余额：`UPDATE ... SET stock = stock - $1 WHERE id = $2 AND stock >= $1`，看受影响行数；`find` 后判断再 `update` 在 Read Committed 下并发必超卖。

## 安全

- 原型污染：合并用户 JSON 时 `__proto__`/`constructor.prototype` 键污染全局对象（`lodash.merge`/`defaultsDeep` 历史 CVE）。用 `Object.create(null)` 承接、`structuredClone`、`Object.hasOwn()`，或进程加 `--disable-proto=delete`。
- ReDoS：嵌套量词 `(a+)+`、`(\w+\s?)*` 对特定输入指数回溯，单线程下等于整站 DoS。用户输入相关的正则用 `re2` 包（线性时间，不支持回溯特性），`eslint-plugin-regexp` 在 CI 拦。
- SSRF：`fetch(userUrl)` 前解析主机并拒绝私网/链路本地/云元数据地址（`169.254.169.254`），`redirect: 'manual'`；对 DNS 解析后的 IP 再校验一次防 rebinding。
- 路径穿越：`path.resolve(root, userPath)` 后校验 `startsWith(root + path.sep)`；命令执行用 `execFile(cmd, argsArray)`，禁 `exec`/`shell: true` 拼接。
- 供应链：`npm ci` 严格按 lockfile；CI 里 `npm ci --ignore-scripts` 再显式 rebuild 必要的原生包；pnpm 设 `minimumReleaseAge`（10.16+，发布 N 天后才可安装，2025 年多起 npm 蠕虫事件的直接应对）；发包用 trusted publishing（OIDC，无长期 token）+ `--provenance`，下游 `npm audit signatures` 校验；`npm audit --omit=dev --audit-level=high` 降噪。
- 认证：JWT 用 `jose`，`algorithms` 白名单，短 `exp` + refresh 轮换；密码 `argon2`（bcrypt 会截断 72 字节）；比较 token 用 `crypto.timingSafeEqual`。请求体上限（Fastify `bodyLimit` 默认 1MB、`express.json({ limit })`）必设。
- 不打印 `process.env` 全量；不把 `err` 对象原样返回客户端（含内部路径与 SQL）。

## 原生能力清单（先用内建，再找 npm）

- 测试：`node --test`（`node:test` + `node:assert`），`mock.method`/`mock.timers`、`--experimental-test-coverage`、`--test` 配 `--watch`、快照 `t.assert.snapshot()`（22.3+）。小服务不需要 Jest/Vitest；需要 ESM 模块 mock 生态或浏览器模式再上 Vitest。
- 配置：`--env-file=.env`、`--env-file-if-exists`（22.9+）、`process.loadEnvFile()`；`util.parseArgs` 替代 yargs 做简单 CLI。
- `node --watch` 替代 nodemon；`node --run <script>`（22+）比 `npm run` 少一层进程；`NODE_COMPILE_CACHE=/tmp/nc` 或 `module.enableCompileCache()` 加速冷启动。
- `node:sqlite`（22.5+，24 仍带 ExperimentalWarning）嵌入式存储；`AsyncLocalStorage` 做请求上下文（24 起默认 `AsyncContextFrame` 实现，开销大幅下降）；`AbortSignal.any()`、`Promise.withResolvers()`、`structuredClone`、`crypto.hash()` 一次性哈希（21.7+）。
- `--permission`（`--allow-fs-read=...` 等）限制脚本文件/子进程/worker 权限；`--experimental-sea-config` 打单文件可执行。

## 代码模板：下单（Fastify + Zod 4 + Prisma，原子扣库存）

```ts
import type { Order, PrismaClient } from '@prisma/client';
import type { FastifyBaseLogger } from 'fastify';
import { z } from 'zod';

export const CreateOrderSchema = z.object({
  productId: z.uuid(),                              // zod 4：顶层 z.uuid()，z.string().uuid() 已弃用
  quantity: z.number().int().positive().max(1_000),
});
export type CreateOrderInput = z.infer<typeof CreateOrderSchema>;

export class ProductNotFoundError extends Error {
  readonly productId: string;                       // 不用构造器参数属性：保持可擦除语法，node 可直接运行
  constructor(productId: string) {
    super(`product ${productId} not found`);
    this.name = 'ProductNotFoundError';
    this.productId = productId;
  }
}

export class InsufficientStockError extends Error {
  readonly productId: string;
  readonly requested: number;
  constructor(productId: string, requested: number) {
    super(`insufficient stock for product ${productId}: requested ${requested}`);
    this.name = 'InsufficientStockError';
    this.productId = productId;
    this.requested = requested;
  }
}

export async function createOrder(
  input: CreateOrderInput,
  deps: { db: PrismaClient; logger: FastifyBaseLogger },
): Promise<Order> {
  const { db, logger } = deps;

  // 类型只保证 number：调用方绕过 CreateOrderSchema.parse 时，负数会让 gte 条件恒真、
  // 且 decrement 变成「加库存」。DB 层的原子性挡不住语义错误的入参，函数入口必须自己兜。
  if (!Number.isInteger(input.quantity) || input.quantity <= 0) {
    throw new RangeError(`quantity must be a positive integer, got ${input.quantity}`);
  }

  // 交互式事务默认 timeout 5s / maxWait 2s；事务内只做 DB 操作
  const order = await db.$transaction(async (tx) => {
    // 条件 UPDATE 原子扣减：并发下只有 stock 仍够的那次能命中，靠 count 判定，不做 select-then-update
    const { count } = await tx.product.updateMany({
      where: { id: input.productId, stock: { gte: input.quantity } },
      data: { stock: { decrement: input.quantity } },
    });
    if (count === 0) {
      // 只有失败路径才多查一次，用来区分"不存在"与"库存不足"
      const exists = await tx.product.findUnique({ where: { id: input.productId }, select: { id: true } });
      if (exists === null) throw new ProductNotFoundError(input.productId);
      throw new InsufficientStockError(input.productId, input.quantity);
    }

    const product = await tx.product.findUniqueOrThrow({
      where: { id: input.productId },
      select: { priceCents: true },                 // priceCents 为 Int 列：金额一律整数分
    });
    const totalCents = product.priceCents * input.quantity;
    if (!Number.isSafeInteger(totalCents)) throw new RangeError('total exceeds safe integer range');

    return tx.order.create({
      data: { productId: input.productId, quantity: input.quantity, totalCents },
    });
  }, { timeout: 5_000 });

  logger.info({ orderId: order.id }, 'order created');   // 邮件/MQ 等副作用放事务之外
  return order;
}
```

## 选型判断

| 场景 | 选择 | 理由 |
|---|---|---|
| 新 HTTP 服务 | Fastify 5 + zod 类型提供器 | schema 驱动校验与序列化，吞吐与生态平衡 |
| 大团队、强分层约定 | NestJS（Fastify 适配器） | DI/模块化换启动时间与学习成本 |
| 多运行时（Node/Workers/Bun） | Hono | Web 标准 API，无 Node 专有依赖 |
| 存量 Express 4 | 升 Express 5 | async 错误处理与路由安全修复，路由语法要迁移 |
| ORM | Prisma（团队偏 schema-first）/ Drizzle（要控 SQL） | 都有事务与类型；性能敏感查询 Drizzle 更透明 |
| 后台任务 | BullMQ（Redis） | 重试/延迟/并发控制齐全；跨语言再上 RabbitMQ/Kafka |
| CPU 密集 | `worker_threads` + piscina，或换 Rust/Go 子服务 | 事件循环不适合算 |
| 测试 | 小项目 `node:test`；大项目 Vitest | 内建零依赖；Vitest 的 mock 与 watch 体验更好 |
| 运行时 | 生产 Node LTS；Bun 只在明确收益（启动/打包）且依赖全兼容时 | Bun 的 Node API 兼容仍有边角 |
| 何时不该用 Node | 长时间 CPU 计算、需要多线程共享内存的数据处理 | 单线程模型下要么阻塞要么复杂化 |

## 审查清单

- [ ] 有 `unhandledRejection`/`uncaughtException` 处理器且行为是"记录 → 退出"，不是吞掉继续
- [ ] SIGTERM 路径：ready 置否 → 等待传播 → `server.close()` → 关依赖 → `exitCode`；总时长 < grace period
- [ ] `keepAliveTimeout` > LB idle timeout；`headersTimeout` > `keepAliveTimeout`
- [ ] 所有 `fetch`/出站请求有 `AbortSignal.timeout`；有连接池上限
- [ ] 请求路径无 `*Sync` I/O、无大同步计算；用户输入相关的正则无嵌套量词
- [ ] 流用 `pipeline()`，手写 `write()` 处理了 `drain`
- [ ] 事务内无 HTTP/队列副作用；扣减用条件 UPDATE + 受影响行数；金额整数分，`BigInt` 有序列化处理
- [ ] 入参经 zod/JSON Schema 校验；被复用的领域函数**自己也校验**数量/金额等语义约束（类型只保证 `number`）；响应不回传 `err` 原文；请求体有大小上限
- [ ] 合并用户对象无原型污染面；文件路径有 root 校验；`execFile` 数组参数
- [ ] `"type": "module"`，内建模块带 `node:` 前缀，`import type` 分离；发包 `exports` 经 publint/arethetypeswrong 检查
- [ ] lockfile 入库、`npm ci`、CI `--ignore-scripts`；`engines` 与 CI 矩阵匹配当前 LTS
- [ ] 容器设了 `--max-old-space-size`；有 `--heapsnapshot-signal` 或等价的线上取证手段

## 与其他 skill 的配合

| 领域 | 对应 skill | 何时参考 |
|---|---|---|
| 浏览器端、React/Vue、构建工具 | senior-frontend-engineer | 组件、CWV、CSS、前端安全 |
| 部署、K8s 探针、Nginx/LB 超时链 | senior-devops-engineer | 优雅关闭与探针配合、容器资源限制 |
