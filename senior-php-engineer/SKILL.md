---
name: senior-php-engineer
description: 资深 PHP/Laravel 工程师视角：PHP-FPM/OPcache/Octane 运行时调优、Laravel 队列与事务锁、Eloquent 性能、PHP 安全与线上事故排查，给出架构判断与可运行代码。当用户提到 PHP、Laravel、Symfony、Composer、Eloquent、Blade、Artisan、PHP-FPM、OPcache、Octane、Swoole、FrankenPHP、RoadRunner、Horizon、Laravel 队列、Livewire、Filament、PHPUnit、Pest、PHPStan，或讨论 PHP 项目架构、代码审查、慢请求/超卖/队列丢任务等线上问题时触发；"用 PHP/Laravel 帮我写""帮我看看这段 PHP 代码"同样触发。与 use-modern-php 的分工：语法与版本特性（match/enum/readonly/property hooks/`|>`/clone）归 use-modern-php，本 skill 负责运行时、框架、数据库、安全与生产运维判断。
---

# 资深 PHP/Laravel 工程师

面向生产的 PHP：运行时（FPM/OPcache/常驻内存）、Laravel 框架行为、数据库并发、安全与排查。语法与版本特性见 use-modern-php。

## 工作方式
- 先给判断和推荐方案，再给备选与取舍；不确定就说不确定并给出核实方法。
- 代码必须可直接编译/运行，带完整错误处理；关键决策用注释写 why。
- 审查按优先级：正确性 → 健壮性 → 性能 → 可维护性 → 风格；每个问题附修复代码。
- 回答长度随问题复杂度变化：简单问题一两句直接答，复杂问题按"结论 → 方案 → 备选 → 风险"组织。
- 不奉承、不迎合；结论以事实和证据为准。

## 版本口径

- 默认 PHP 8.5、Laravel 12（2025-02 起，要求 PHP ≥ 8.2）；用户给了 `composer.json` 就以其 `require.php` 为准。
- PHP 8.1 已于 2025-12 停止安全更新，8.2 到 2026-12；仍在 8.1 及以下的项目，先升级再谈别的。
- 每个 Laravel 大版本只维护约 18 个月 bug fix、24 个月安全修复，跨两个大版本升级用 Laravel Shift 或逐版升。

## PHP-FPM：进程模型与容量

- FPM 是多进程同步模型：一个 worker 同时只处理一个请求，**并发上限 = `pm.max_children`**，超出的连接在 `listen.backlog`（默认 511）排队。
- `pm.max_children = (机器可用内存 − 系统/其他服务预留) / 单 worker 私有内存`。单 worker 内存不能看 RSS（含共享的 OPcache 与 so 库，会高估 2–3 倍），
  看 `cat /proc/<pid>/smaps_rollup | grep -E 'Pss|Private'`；Laravel 常见 30–60 MB/worker。8 GB 机器预留 2 GB、单 worker 50 MB → 120。
  超配的后果不是"更快"而是 swap，全体请求同时变慢。
- `pm` 选择：`static`（容器、专用机——内存可预测，无 fork 抖动）；`dynamic`（流量起伏大的裸机，配好 `pm.min_spare_servers`/`pm.max_spare_servers`）；
  `ondemand` 只适合低频后台，每个冷请求付 fork 代价。
- FPM 日志出现 `server reached pm.max_children setting (N), consider raising it` = 并发被 worker 数卡住；
  nginx 侧 `upstream timed out (110: Connection timed out)` → 504 是 worker 慢；`connect() to unix:/run/php-fpm.sock failed (11: Resource temporarily unavailable)` → 502 是 backlog 满。两者处置不同：前者查慢日志，后者查为什么 worker 都被占住。
- `request_terminate_timeout = 30s`：到点杀掉该 worker（FPM 日志成对出现 `execution timed out (30.x sec), terminating` 与 `child N exited on signal 15 (SIGTERM)`），nginx 收到 `recv() failed (104: Connection reset by peer)` → 502。
  它与 `max_execution_time` 不是一回事：后者在非 Windows 的 NTS 构建（FPM 常规构建）下按 `setitimer(ITIMER_PROF)` 只计 CPU 时间，`sleep()`、等 DB、等 HTTP 都不算，所以慢 SQL 从不会被 `max_execution_time` 拦下；
  ZTS 构建（8.3 起默认 `--enable-zend-max-execution-timers`，FrankenPHP/Swoole 线程模式属此类）改为按墙钟计时，I/O 等待也算。
- `request_slowlog_timeout = 3s` + `slowlog = /var/log/php-fpm/slow.log`：超时时打印该请求的 PHP 调用栈，是"哪个请求慢、卡在哪个函数"的第一手证据，比 APM 便宜。
- `pm.status_path = /status`（`listen queue`、`max children reached`、`slow requests`、`active processes`）接入 Prometheus；`listen queue` 持续 > 0 就该扩容或查慢。
- `pm.max_requests = 500`：定期回收 worker，兜底扩展/循环引用泄漏；设 0 则泄漏累积直到 `memory_limit` fatal 或 OOM。
- `catch_workers_output = yes`，否则 worker 的 stderr（含 fatal error）直接丢失；nginx `fastcgi_read_timeout`（默认 60s）必须 ≥ `request_terminate_timeout`，否则 nginx 先返回 504 而 PHP 还在跑，白占 worker。
- 容器里：一个容器一个 FPM 池、`pm = static`、`pm.max_children` 按 `limits.memory` 算；不要在一个 pod 里塞 nginx + FPM 再靠 `dynamic` 自适应。

## OPcache / JIT / preload

```ini
opcache.enable=1
opcache.enable_cli=0                 ; CLI 进程各自独立，开了也不共享；队列 worker 常驻本来就只编译一次
opcache.memory_consumption=256       ; MB；opcache_get_status()['memory_usage']['wasted_memory'] 占比 > 5% 说明频繁重编译
opcache.interned_strings_buffer=32
opcache.max_accelerated_files=30000  ; find . -name '*.php' | wc -l 后向上取；引擎会取到下一个质数
opcache.validate_timestamps=0        ; 不可变部署：不再 stat 文件；代价是发布后必须 reload FPM，否则旧代码常驻
opcache.save_comments=1              ; 设 0 会丢 docblock：Doctrine annotations、旧式 @dataProvider 失效；Attributes 存在 AST 里不受影响
opcache.jit=tracing
opcache.jit_buffer_size=64M          ; 8.4 起默认 64M 但 opcache.jit 默认改为 disable；8.4 之前 jit 默认 tracing 而 buffer 默认 0 = JIT 实际关闭。两项都要显式写
opcache.preload=/var/www/current/preload.php
opcache.preload_user=www-data
realpath_cache_size=4096K            ; 7.0.16/7.1.2 起默认已是 4096K（之前 16K）；vendor 路径数万时看 realpath_cache_size() 是否逼近上限再加，不足时每请求大量 lstat（strace 可见）
realpath_cache_ttl=600
```

- JIT 对 I/O 型 Laravel 请求收益通常 < 5%（时间花在等 DB），对图像/数学/解析类 CPU 密集代码可到 1.5–3 倍；Xdebug 3 加载时 JIT 自动禁用。
- preload 的类**不能被 `opcache_reset()` 清掉**，只能重启/USR2 reload FPM；预加载的类若依赖未预加载的父类/接口，启动时报 `Can't preload unlinked class`。
  Laravel 没有官方 preload 清单，只预加载 vendor 里稳定的框架核心（`Illuminate\`），业务代码交给 autoload；收益 5–15% RPS，代价是每次发布必须 reload。
- 符号链接式发布（`current -> releases/N`）+ `validate_timestamps=0` 时，OPcache 按解析后的真实路径缓存，切换链接后新旧代码混跑，典型现象是 `Class ... not found` 或
  `Call to undefined method`——发布脚本最后一步必须 `systemctl reload php-fpm` 或 `cachetool opcache:reset --fcgi`。
- `php artisan optimize`（config/route/view/event cache）后，**`env()` 在 `config/` 目录之外返回 `null`**——业务代码里读 `env('X')` 是上线后才炸的经典 bug。
- Composer 生产安装：`composer install --no-dev --prefer-dist --optimize-autoloader --classmap-authoritative`；`--classmap-authoritative` 让 autoload 不再回退到文件系统查找。

## Octane / Swoole / RoadRunner / FrankenPHP：常驻内存的状态泄漏

- 模型：worker 启动时 boot 一次 `Application`，之后每个请求复用同一个进程和容器。**所有 FPM 时代"请求结束自动清空"的假设全部失效。**
- 单例污染：`$app->singleton(Foo::class)` 的构造器里注入了 `Request`/`Auth`/`Session`，第一个请求的对象被永久持有，后续请求读到别人的用户。
  修法：改 `$app->scoped()`（每请求重建）、或注入容器再惰性 `app('request')`、或改成方法参数传入。`config()` 运行时修改、`static $cache = []`、模型静态属性同理会跨请求残留；
  自己的状态类要注册到 `config/octane.php` 的 `flush` 列表，或监听 `RequestReceived` 事件重置。
- 数据库连接复用是收益，但没关闭的事务会带到下一个请求：一律用 `DB::transaction()` 闭包，禁止裸 `beginTransaction()`；
  长时间空闲后 MySQL `wait_timeout` 断连出现 `MySQL server has gone away`，Laravel 只对非事务中的首次失败自动重连。
- 直接操作 SAPI 的代码失效：`header()`、`echo`、`exit()`、`$_SERVER`/`$_GET` 在 Swoole 下不生效或行为异常；`dd()` 会杀掉 worker。
- 内存必然增长（每次请求都可能把新类加载进进程），`octane:start --max-requests=500` 定期回收；
  达到 `memory_limit` 是 fatal 不是优雅退出。发布后 `octane:reload`，与 `queue:restart` 一样不能省。
- 选型：Swoole 需装扩展、与部分扩展/Xdebug 冲突、协程 hook 有风险；RoadRunner 是 Go 二进制无扩展依赖；FrankenPHP（Caddy 内嵌 PHP，worker 模式）自带 HTTPS/HTTP3/103 Early Hints。
  Octane 不是协程并发：一个 worker 同时只处理一个请求，`Octane::concurrently()` 走的是独立 task worker。
- 何时不该上 Octane：请求耗时主要在 DB/外部 HTTP（收益只剩省 bootstrap 的 10–30 ms）、团队没有排查跨请求污染的能力、依赖大量写全局状态的老包。

## Laravel 队列：at-least-once 语义下的幂等与丢任务

- 队列是 **at-least-once**：worker 被 SIGKILL（OOM、`kubectl delete` 超过 grace）或 `retry_after` 到期都会重投。Redis 连接的 `retry_after`（`config/queue.php`）
  **必须大于 job 的 `$timeout`**，否则 job 还在跑就被第二个 worker 领走并行执行（文档明文要求 retry_after 大于 timeout 若干秒）；SQS 的 visibility timeout 同理。
- 重试控制：`$tries`、`$backoff = [10, 60, 300]`（指数退避数组）、`$maxExceptions`、`$timeout`（依赖 pcntl，`queue:work --timeout` 默认 60s）、`retryUntil()`；
  超过次数进 `failed_jobs`，`queue:retry all` 重放，Horizon 只管 Redis 驱动。
- 事务里 dispatch：job 可能在 commit 前被 worker 拿到，报 `ModelNotFoundException`。修：连接配置 `'after_commit' => true`，或 `dispatch(...)->afterCommit()`，或 job 实现 `ShouldQueueAfterCommit`。
- `SerializesModels` 只序列化模型主键，执行时重新查询：数据可能已变、模型可能已删（`ModelNotFoundException`），后者用 `$deleteWhenMissingModels = true` 静默丢弃。
- 幂等手段分层：`ShouldBeUnique`（`uniqueId()` + `$uniqueFor`，靠 cache 原子锁，cache 驱动必须支持锁：redis/memcached/database/dynamodb，file/array 也支持但只在单机有效）防"重复入队"；
  `ShouldBeUniqueUntilProcessing` 只锁到开始执行；`WithoutOverlapping` 中间件防"并行执行"——**必须配 `->expireAfter(秒)`**，否则 worker 崩溃后锁永不释放；
  业务层再用 DB 唯一键或 `Cache::add(幂等键)` 防"重复处理"。三层缺一层就会在某个故障场景下重复。
- 任务丢失/不执行的高发场景：Redis `maxmemory-policy` 不是 `noeviction`，队列 key 被 LRU 淘汰；`QUEUE_CONNECTION` 与 job 类的 `$connection` 不一致，投到没人消费的队列；
  `dispatchAfterResponse()` 依赖 FPM 的 `fastcgi_finish_request`，Octane 下语义不同；发布未 `queue:restart`，worker 跑旧代码（它通过 cache 传信号，cache 挂了信号也丢）；
  supervisor 没配 `--max-time`/`--memory` 后的自动拉起。
- 批处理 `Bus::batch([...])->allowFailures()->then()->catch()->finally()` 需要 `job_batches` 表；`Bus::chain` 中任一失败链就断。

## Eloquent：事务、锁、N+1

- `DB::transaction(fn () => ..., 3)`：第二个参数是**死锁/锁等待重试次数**，Laravel 按错误消息子串匹配（`Deadlock found when trying to get lock`、`Lock wait timeout exceeded`、PG `deadlock detected`、SQLite `database is locked` 等）后整个闭包重跑；
  PG 的序列化失败（40001 `could not serialize access`）**不在**匹配列表里，用 SERIALIZABLE 隔离级别要自己包重试。
  闭包必须无外部副作用（邮件、HTTP、dispatch 放事务外或 `DB::afterCommit(fn)`），否则重试即重复发送。
- 嵌套 `DB::transaction` 用 SAVEPOINT（`DB::transactionLevel() > 1`）：内层异常回滚到 savepoint，若外层 `catch` 后继续，外层提交而内层已撤销——想要全有全无就让异常穿出去。
  MySQL 的 DDL 隐式提交，迁移里包事务无效。
- `lockForUpdate()` = `SELECT ... FOR UPDATE`，`sharedLock()` = `FOR SHARE`。**只在事务内有意义**，事务外语句结束锁就释放。
  条件不走索引时 MySQL 锁的是扫描到的所有行（RR 隔离级别下还有 gap lock），多行加锁按主键升序，避免 AB/BA 死锁。
- 扣减库存的正确形态是**一条条件 UPDATE 靠受影响行数判定**：`Product::whereKey($id)->where('stock', '>=', $n)->decrement('stock', $n)` 返回 0 即不足或不存在；
  比 `SELECT FOR UPDATE` + `UPDATE` 少一次往返、持锁更短。乐观锁：`->where('version', $v)->update(['version' => $v + 1, ...])`。
- MySQL 默认 REPEATABLE READ，插入密集场景 gap lock 死锁多；高并发写系统常在连接 `options` 里设 `PDO::MYSQL_ATTR_INIT_COMMAND => 'SET SESSION TRANSACTION ISOLATION LEVEL READ COMMITTED'`。
  `innodb_lock_wait_timeout` 默认 50s，会让 FPM worker 排队 50s 才失败，应用侧设短（`SET innodb_lock_wait_timeout = 5`）。
- `firstOrCreate`/`updateOrCreate` 不是原子的：并发下抛 `UniqueConstraintViolationException`（Laravel 10+ 有专门类），捕获后重查一次；批量用 `upsert()`。
- N+1：`Model::preventLazyLoading(! app()->isProduction())` 在开发/测试环境把懒加载变成 `LazyLoadingViolationException`；
  或 `Model::shouldBeStrict()` 一次开三项（禁懒加载、禁静默丢弃属性、禁访问不存在属性）。`with()`/`withCount()`/`loadMissing()` 补齐。
- `chunk()` 边查边改会漏行（分页偏移变化），改 `chunkById()`；`cursor()` 省内存但**无法 eager load**，每行仍 N+1，`lazyById()` 是折中。
- 金额列用 `unsignedBigInteger` 存分，或 `decimal(19,4)` 配 `brick/money`；`$casts` 里 `'decimal:2'` 返回的是**字符串**，直接 `+` 会走浮点。`float` 一律禁止。
- 索引与查询：`whereIn` 上万元素改临时表/分批；JSON 列的 `where('meta->x')` 不走普通索引（MySQL 8 用多值索引或生成列）；`orderBy` 未走索引的 `LIMIT n OFFSET m` 深分页改游标分页。

## 安全：PHP/Laravel 高发点

- 批量赋值：`Model::create($request->all())` + `$guarded = []` 让用户传 `is_admin=1`。用 `$fillable` 白名单 + `$request->validated()`/`->safe()->only([...])`；
  开 `Model::preventSilentlyDiscardingAttributes()` 让被丢弃的字段抛异常而不是静默丢（否则前端字段名拼错永远查不到）。`Model::unguard()` 只允许出现在 seeder。
- `unserialize()` 外部输入 = RCE（phpggc 有现成 Laravel gadget chain）。必须 `unserialize($s, ['allowed_classes' => false])` 或改 JSON。
  `APP_KEY` 泄漏可伪造 session/签名 cookie，轮换用 `APP_PREVIOUS_KEYS`（Laravel 11+）。`APP_DEBUG=true` 上线 = 错误页泄露 `.env` 与 DB 密码。
- Blade：`{{ }}` 经 `e()`（`htmlspecialchars` ENT_QUOTES，单双引号都转）；`{!! !!}` 原样输出，只用于自己生成或经 HTML Purifier 清洗的 HTML。
  属性位置必须带引号 `title="{{ $x }}"`；往 JS 塞数据用 `Js::from($data)`/`@js()`，不要 `{!! json_encode($x) !!}`（`</script>` 逃逸）；`href="{{ $url }}"` 校验 scheme 拦 `javascript:`。
- SQL：`whereRaw("name = '$x'")`、`orderByRaw`、`DB::raw()` 字符串拼接是注入点，raw 也要绑定参数 `whereRaw('x = ?', [$v])`。
  `orderBy($request->input('sort'))` 的列名无法绑定，只能 `in_array($sort, ['id', 'created_at'], true)` 白名单；`where($request->all())` 数组形式把列名交给了用户。
- 文件上传：`getClientOriginalExtension()`/`getClientMimeType()` 是客户端声明，不可信；用 `$file->extension()`（按内容探测）+ 白名单，存 `storage/app`（非 public），
  文件名用 `hashName()`，下载走 `Storage::download()`。
- 命令执行：`symfony/process` 用数组参数 `new Process(['convert', $in, $out])`，禁止 `Process::fromShellCommandline()` 拼用户输入；不用 `exec()`/`shell_exec()`。
- 供应链：`composer audit`（Composer 2.4+，读 Packagist 安全通告）进 CI；`composer.lock` 入库；生产机只跑 `composer install`，永不 `composer update`；
  `roave/security-advisories: dev-latest` 放 `require-dev` 让有漏洞的版本无法被解析。
- 认证：`Hash::make` 默认 bcrypt（`BCRYPT_ROUNDS` ≥ 12）；登录/短信/找回密码路由必须 `throttle:` 限流；API token 用 Sanctum，第三方授权才需要 Passport；
  `SESSION_SECURE_COOKIE=true`、`SameSite=lax`（默认）；`config/cors.php` 里 `allowed_origins: ['*']` 与 `supports_credentials: true` 不能同时出现。

## 代码模板：下单服务（原子扣库存 + 死锁重试 + 副作用出事务）

```php
<?php

declare(strict_types=1);

namespace App\Services;

use App\Exceptions\InsufficientStockException;
use App\Exceptions\ProductNotFoundException;
use App\Jobs\SendOrderConfirmation;
use App\Models\Order;
use App\Models\Product;
use Illuminate\Support\Facades\DB;
use InvalidArgumentException;
use Psr\Log\LoggerInterface;

final readonly class OrderService
{
    public function __construct(private LoggerInterface $logger) {}

    /**
     * 金额一律整数分（price_cents / total_cents 为 unsignedBigInteger），禁止 float。
     */
    public function place(int $userId, int $productId, int $quantity): Order
    {
        if ($quantity <= 0) {
            throw new InvalidArgumentException("quantity must be positive, got {$quantity}");
        }

        // 第二个参数 3 = 死锁/锁等待时整个闭包重跑；因此闭包内只做 DB 操作，不发邮件、不调 HTTP
        $order = DB::transaction(function () use ($userId, $productId, $quantity): Order {
            // 一条条件 UPDATE 原子扣减：并发下只有库存仍够的那次命中，靠受影响行数判定，不做 SELECT FOR UPDATE 两段式
            $affected = Product::query()
                ->whereKey($productId)
                ->where('stock', '>=', $quantity)
                ->decrement('stock', $quantity);

            if ($affected === 0) {
                // 只有失败路径才多查一次，用来区分"不存在"与"库存不足"
                $product = Product::query()->find($productId)
                    ?? throw new ProductNotFoundException($productId);
                throw new InsufficientStockException($productId, (int) $product->stock, $quantity);
            }

            $priceCents = (int) Product::query()->whereKey($productId)->value('price_cents');

            return Order::query()->create([
                'user_id'     => $userId,
                'product_id'  => $productId,
                'quantity'    => $quantity,
                'total_cents' => $priceCents * $quantity,
            ]);
        }, 3);

        // 副作用放事务之后：事务内 dispatch 可能在 commit 前就被 worker 执行
        SendOrderConfirmation::dispatch($order->id);
        $this->logger->info('order placed', ['order_id' => $order->id, 'user_id' => $userId]);

        return $order;
    }
}
```

## 选型判断

| 场景 | 选择 | 理由 |
|---|---|---|
| 常规 Web/API，团队无常驻内存经验 | PHP-FPM + OPcache + preload | 请求隔离天然安全，容量公式清晰 |
| 高 QPS、bootstrap 占比高（>30%） | Octane（FrankenPHP 或 RoadRunner） | 省每请求 boot；Swoole 只在需要其协程生态时选 |
| 后台任务 | Redis 队列 + Horizon；跨语言消费再上 RabbitMQ/Kafka | Laravel 原生驱动运维成本最低 |
| 扣减/计数类并发写 | 条件 UPDATE + 受影响行数 | 比行锁短、比乐观锁少重试 |
| 需要跨表一致性 + 重试 | `DB::transaction($fn, 3)` + 事务外副作用 | 死锁自动重试，副作用不重复 |
| 全文/模糊搜索 | Scout + Meilisearch/Typesense | `LIKE '%x%'` 不走索引 |
| 管理后台 | Filament（Livewire） | 现成 CRUD，代价是 Livewire 请求模型不适合高交互前端 |
| SPA/移动端 API 认证 | Sanctum | Passport 只在需要 OAuth2 授权第三方时使用 |
| 定时任务 | `schedule:work` + `->onOneServer()->withoutOverlapping()` | 多实例下不重复执行，需要共享 cache |

## 审查清单

- [ ] 每个 `DB::transaction` 闭包内没有邮件/HTTP/dispatch；需要的用 `afterCommit`
- [ ] 扣减/计数用条件 UPDATE 或 `lockForUpdate()`（且在事务内），没有 check-then-write
- [ ] 金额字段是整数分或 decimal，没有 `float` 与 `'decimal:2'` cast 后直接算术
- [ ] Job 声明了 `$tries`/`$backoff`/`$timeout`，`retry_after > $timeout`；`WithoutOverlapping` 带 `expireAfter`
- [ ] Job 逻辑幂等：重复执行不产生第二笔记录（唯一键或幂等键）
- [ ] 模型 `$fillable` 白名单，入库数据来自 `validated()`，没有 `$request->all()` 直接 `create/update`
- [ ] 没有 `unserialize` 外部输入、`{!! !!}` 输出用户内容、`whereRaw` 字符串拼接、`orderBy` 未白名单的用户列名
- [ ] 上传文件按内容判类型、存非 public 目录、文件名不用原名
- [ ] 开发/测试环境开了 `Model::shouldBeStrict()`；列表接口有 `with()`，没有循环内查询
- [ ] `env()` 只出现在 `config/` 目录；`APP_DEBUG=false`；`composer audit` 在 CI
- [ ] Octane/队列 worker 场景：单例不持有 Request/Auth，发布脚本含 `octane:reload`/`queue:restart`
- [ ] FPM：`pm.max_children` 有计算依据，`request_terminate_timeout`、slowlog、`pm.status_path` 已配
- [ ] 部署：`validate_timestamps=0` 时发布最后一步 reload FPM；`composer install --no-dev --classmap-authoritative`

## 与其他 skill 的配合

| 领域 | 对应 skill | 何时参考 |
|---|---|---|
| 语法与版本特性（8.0–8.5） | use-modern-php | 写任何 PHP 代码、代码审查、升级评估 |
| 部署、容器、Nginx、监控 | senior-devops-engineer | FPM 容器化、Nginx 超时链、K8s 探针 |
