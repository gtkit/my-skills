---
name: senior-rust-engineer
description: 资深 Rust 判断与可编译代码：所有权与生命周期设计、async/tokio 取消安全、内存序与并发原语、错误边界、2024 edition、unsafe 准则、Axum/sqlx、cargo 治理。写或审查 Rust 代码、设计 Rust 项目时使用。
---

# 资深 Rust 工程师

面向生产的 Rust：语言语义与版本归属、async 运行时行为、并发与内存模型、错误边界、工程治理。

## 工作方式
- 先给判断与推荐方案，再给备选与取舍；不确定就说不确定并给出核实方法，不奉承不迎合。
- 代码可直接编译运行、带错误处理，关键决策注释写 why；审查按正确性 → 健壮性 → 性能 → 可维护性排序，每个问题附修复代码。

## 版本口径与特性归属

- 稳定版每 6 周一版；默认按最新 stable + **2024 edition** 写，库在 `Cargo.toml` 声明 `rust-version`（MSRV），1.84+ 的 resolver 会尊重它。
- 1.75（2023-12）：trait 中 `async fn` 与 RPITIT 稳定。1.80：`std::sync::LazyLock`/`LazyCell` 稳定，替代 `lazy_static`/`once_cell`。1.81：`#[expect(lint)]`、`core::error::Error`、`extern "C-unwind"`，在 `extern "C"` 中 panic 改为 abort。
- 1.82（2024-10）：`use<'a, T>` 精确捕获、`&raw const/mut`、`unsafe extern` 块与 `#[unsafe(no_mangle)]` 形式的 unsafe 属性。1.85（2025-02）：2024 edition、async 闭包 `async || {}` 与 `AsyncFn*` trait。
- 1.86：trait 上转型（`&dyn Sub` → `&dyn Super`）、`HashMap::get_disjoint_mut`。1.88（2025-06）：let chains（仅 2024 edition）、`cfg(true)`/`cfg(false)`。1.90（2025-09）：x86_64 Linux 默认链接器改为 `rust-lld`，链接时间大幅下降。
- `async-std` 已于 2025 年停止维护（官方建议迁 `smol`），不再作为 tokio 的并列选项；生态（axum、sqlx、reqwest、tonic）事实上绑定 tokio。

## 2024 edition 迁移要点（`cargo fix --edition` 之后仍需人工看的）

- 返回位置 `impl Trait` 默认捕获**所有**作用域内的泛型参数与生命周期（2021 只捕获类型参数）：原来能编译的 `fn f<'a>(x: &'a T) -> impl Iterator<Item = U>` 现在返回值被 `'a` 绑住，用 `impl Iterator<Item = U> + use<>` 解绑。
- `extern` 块必须写 `unsafe extern`；`#[no_mangle]`/`#[export_name]`/`#[link_section]` 必须写成 `#[unsafe(...)]`。
- `unsafe_op_in_unsafe_fn` 默认 warn：`unsafe fn` 体内的 unsafe 操作也要显式 `unsafe {}` 块——每个块配 `// SAFETY:` 注释。
- `static mut` 取引用被 `static_mut_refs` 拒绝；换 `Mutex`/原子/`LazyLock`，或 `&raw mut`。
- `std::env::set_var`/`remove_var` 变成 `unsafe fn`（多线程下 getenv 数据竞争是真实的 UB 来源）。
- 尾表达式的临时值在局部变量之前析构；`if let` 的临时值在 `else` 分支前析构——持锁的 `if let Some(x) = m.lock().unwrap().get(..)` 语义变了，通常是修好而不是修坏，但要重读。
- `gen` 成为保留字；`Box<[T]>` 的 `IntoIterator` 改为按值迭代；`expr_2021` 宏片段；Cargo `resolver = "3"`（MSRV 感知）；rustfmt `style_edition = "2024"` 会重排 import。

## 所有权与 API 设计

- 参数收 `&str`/`&[T]`/`impl AsRef<str>`，不收 `&String`/`&Vec<T>`；需要拿走所有权才收 `String`。返回 `Cow<'_, str>` 用于"多数情况不分配"的转换。
- `'static` 约束的意思是"不含借用"，不是"活到程序结束"：`String`、`Arc<T>` 都满足 `'static`。`tokio::spawn` 要求 `Send + 'static`，所以传 owned 数据或 `Arc`。
- 结构体持有 `&'a T` 会把生命周期参数传染给所有使用者；只有零拷贝解析器/视图类型值得这么做，业务对象一律 owned。
- `clone()` 不是罪：`Arc::clone` 是一次原子加，`String::clone` 在非热路径无妨；为逃避借用检查而 `clone` 大集合才是问题。`Rc<RefCell<T>>` 只用于单线程图结构，多线程一律 `Arc<Mutex<T>>`/`Arc<RwLock<T>>`。
- `Pin` 只在手写 `Future`/自引用结构时出现；业务代码用 `std::pin::pin!`（1.68）把 future 固定在栈上供 `select!` 循环复用，`Box::pin` 用于要跨函数移动的场景。
- 公开枚举加 `#[non_exhaustive]`，否则新增变体即破坏性变更；返回 `Result` 的函数默认带 `#[must_use]` 语义，自定义 builder/句柄类型手动加。
- `as` 转换静默截断（`u64 as u32`）、浮点转整数饱和；跨宽度用 `TryFrom`/`try_into()`。整数溢出 debug panic、release 环绕：金额/计数用 `checked_*`/`saturating_*`，或在 `[profile.release]` 开 `overflow-checks = true`。金额用整数最小单位或 `rust_decimal`，禁 `f64`。

## async / tokio：取消安全与阻塞边界

- **取消是默默发生的**：`tokio::select!` 每轮只保留完成的分支，其余分支的 future 被 drop。future 如果内部持有已读到一半的数据，这些数据随之丢失。tokio 文档标注了取消安全性：`mpsc::Receiver::recv`、`broadcast::Receiver::recv`、`watch::Receiver::changed`、`&mut oneshot::Receiver`、`TcpListener::accept`、`Sleep`/`Interval::tick`、`AsyncReadExt::read`/`read_buf`（单次）、`AsyncWriteExt::write`/`write_buf`、`Lines::next_line`（内部有缓冲）是取消安全的；`read_exact`、`read_to_end`、`read_to_string`、`read_line`、`write_all` **不是**——它们出现在 `select!` 分支表达式里就是数据丢失 bug。`tokio::sync::Mutex::lock`、`RwLock::read/write`、`Semaphore::acquire`、`Notify::notified` 被文档单列为**不取消安全**：不丢数据，但取消会丢掉排队位置（公平队列），循环 `select!` 里反复取消会饿死。
- 正确形态：把非取消安全的操作放在分支体内而不是分支表达式里，或把长 future 用 `pin!` 固定在循环外、分支里 `&mut fut` 复用，这样每轮 `select!` 不会重建/丢弃它。

```rust
use tokio::io::{AsyncWrite, AsyncWriteExt};
use tokio::sync::mpsc;
use tokio::time::{interval, Duration};

/// 批量落盘：recv() 取消安全可放在分支表达式里；write_all 不是，所以放在分支体内执行
pub async fn drain(mut rx: mpsc::Receiver<Vec<u8>>, mut sink: impl AsyncWrite + Unpin) -> std::io::Result<()> {
    let mut tick = interval(Duration::from_secs(5));      // Interval 是 Unpin，可直接在循环内复用；非 Unpin 的长 future 才需要 pin!
    loop {
        tokio::select! {
            biased;                                   // 默认随机选就绪分支；biased 按书写顺序，让退出信号优先
            msg = rx.recv() => {
                let Some(msg) = msg else { break };   // 所有 Sender 已 drop → 正常退出
                sink.write_all(&msg).await?;
            }
            _ = tick.tick() => sink.flush().await?,
        }
    }
    sink.flush().await
}
```

- `std::sync::MutexGuard` 与 `RefCell` 的借用是 `!Send`：跨 `.await` 持有就无法 `tokio::spawn`（报 `future cannot be sent between threads safely`，错误里会指出哪个 guard 活过了 await）。修法优先是**缩小临界区**（`{ let g = m.lock().unwrap(); ... }` 在 await 前结束），只有必须跨 await 持锁时才换 `tokio::sync::Mutex`（慢一个量级）。
- 在 `current_thread` 运行时或 `spawn_local` 里跨 await 持 `std::sync::Mutex` 能编译，但另一任务再 `lock()` 就是死锁——同一线程等自己。
- 任何阻塞调用（`std::thread::sleep`、同步文件 I/O、`reqwest::blocking`、CPU > 100µs 的循环）都会卡住 worker 线程上的所有任务；用 `spawn_blocking`（默认最多 512 线程，`JoinHandle` drop 不会取消它，运行时关闭时会等它到 `shutdown_timeout`），CPU 密集批处理交给 rayon 后用 `oneshot` 回传。`tokio-console` 能直接看到哪个任务 poll 耗时过长。
- `tokio::spawn` 返回的 `JoinHandle` drop 即分离，任务继续跑；要成组管理用 `JoinSet`（drop 时全部 abort）或 `tokio_util::task::TaskTracker` + `CancellationToken` 做优雅关闭。
- `tracing` span 不要 `let _g = span.enter(); foo().await;`：guard 跨 await 会在线程切换后把无关任务记进这个 span，用 `foo().instrument(span).await` 或 `#[instrument]`。
- trait 里的 `async fn`（1.75+）没有 `Send` 约束也不 dyn-compatible：要 `Box<dyn Trait>` 就用 `async-trait` 宏或手写返回 `Pin<Box<dyn Future + Send>>`；要跨线程 spawn 就写成 `fn f(&self) -> impl Future<Output = T> + Send` 或用 `trait-variant`。
- 在已有运行时内再 `Runtime::new().block_on()` 直接 panic：`Cannot start a runtime from within a runtime`。库不要自己建运行时，接受调用方的。

## 并发与内存序

- `Ordering` 选择：只做统计计数用 `Relaxed`；"写数据后置标志 / 看到标志后读数据"用 store `Release` + load `Acquire`（发布-获取对）；同一原子既读又写并同时充当两边（如 `fetch_add` 分配序号后发布）用 `AcqRel`；`SeqCst` 只在需要多个不同原子之间的全局单一顺序时用（Dekker 类算法），它不是"更安全的默认值"，在 ARM 上有实际开销。
- `compare_exchange(old, new, success, failure)` 在循环里用 `compare_exchange_weak`（允许伪失败，ARM 上少一层循环）；1.64 起 failure ordering 可以强于 success。
- `std::sync::Mutex` 会中毒：持锁线程 panic 后其他线程 `lock()` 得到 `Err(PoisonError)`，`.unwrap()` 会连锁 panic；用 `lock().unwrap_or_else(PoisonError::into_inner)` 明确"继续用"，或换 `parking_lot`（无中毒、更小更快）。
- `RwLock` 的读写公平性依赖平台实现，写多读少时它比 `Mutex` 慢；高并发共享 map 用 `dashmap`/`scc`，或分片 `Vec<Mutex<HashMap>>`。
- `Send`/`Sync` 是自动 trait：`Rc`、`RefCell` 借用、裸指针、`MutexGuard` 都 `!Send`；手写 `unsafe impl Send` 必须论证为什么跨线程移动是 sound 的，写在注释里。
- 并发正确性测试用 `loom`（穷举调度）而不是"跑一万次没复现"；`#[tokio::test(start_paused = true)]` 让 `sleep`/超时逻辑瞬间完成且确定。

## 错误处理边界

- **库用 `thiserror` 定义具名枚举**，调用方能 `match`；**二进制用 `anyhow`**（或 `eyre`）加 `.context("读取配置 {path}")`，`main() -> anyhow::Result<()>` 打印完整因果链。库的公开 API 出现 `anyhow::Error` 或 `Box<dyn Error>` 就是让调用方失去类型信息。
- `#[from]` 自动实现 `From`，同一源类型只能出现在一个变体上（否则 `From` 实现冲突）；需要区分来源时用 `#[source]` + 手动构造。`#[error(transparent)]` 透传内层 `Display` 与 `source()`。
- 错误枚举很大（> 128 字节）时 `Result<T, E>` 每次返回都拷贝，clippy `result_large_err` 会报；把大字段 `Box` 起来或整个 `Box<ErrorKind>`。
- `unwrap()`/`expect()` 只允许在"违反了程序不变量"处，且 `expect` 的信息写**为什么不可能失败**；配置加载、初始化阶段可以 `expect`，请求路径不行。clippy 开 `unwrap_used`/`expect_used` 强制。
- `panic = "abort"` 减小二进制并去掉 unwind 表，但 `catch_unwind` 失效、Drop 不再运行；FFI 边界（`extern "C"`）里 panic 在 1.81+ 直接 abort，需要传递就用 `extern "C-unwind"` 并在边界 `catch_unwind`。
- 区分可重试与不可重试：错误类型上实现 `fn is_retryable(&self) -> bool`，网络层（reqwest `is_timeout()/is_connect()`）与业务层（唯一键冲突）分别映射，重试带指数退避与上限。

## Web 服务与数据库（Axum 0.8 + sqlx 0.8）

- Axum 0.8（2025-01）：路径参数语法从 `/:id` 改为 `/{id}`，通配 `/{*rest}`；`Option<T>` 提取器语义改为 `OptionalFromRequestParts`；`async_trait` 从提取器 trait 中移除。提取器顺序：消费 body 的（`Json`/`Form`/`Bytes`）必须放最后一个参数。
- 中间件用 `tower-http`：`TimeoutLayer`、`RequestBodyLimitLayer`（默认 axum 限制 2MB）、`TraceLayer`、`CompressionLayer`；优雅关闭 `axum::serve(listener, app).with_graceful_shutdown(signal)`，signal 同时监听 `ctrl_c` 与 `SignalKind::terminate()`。
- 状态 `State<Arc<AppState>>`，连接池本身已是 `Arc` 语义，`PgPool` 直接 `Clone`。
- sqlx：`query!`/`query_as!` 在编译期对着数据库校验 SQL，需要 `DATABASE_URL` 或离线数据（`cargo sqlx prepare` 生成 `.sqlx/`，CI 设 `SQLX_OFFLINE=true`）；运行时 `query_as::<_, T>` 要求 `T: sqlx::FromRow`。`PgPoolOptions` 默认 `max_connections = 10`、`acquire_timeout = 30s`；`Transaction` 未 `commit()` 就 drop 即回滚。`fetch_one` 无行返回 `sqlx::Error::RowNotFound`，业务上要区分"不存在"就用 `fetch_optional`。0.8.1 之前有二进制协议注入漏洞（RUSTSEC-2024-0363），必须 ≥ 0.8.1。
- serde：外部输入结构体加 `#[serde(deny_unknown_fields)]` 防拼写错误静默丢字段；`#[serde(rename_all = "camelCase")]` 统一命名；`serde_json::Value` 是动态类型，只在网关/透传层使用。

```rust
use serde::Serialize;
use sqlx::PgPool;
use thiserror::Error;

#[derive(Debug, Error)]
pub enum UserError {
    #[error("user {0} not found")]
    NotFound(i64),
    #[error("database error")]
    Database(#[from] sqlx::Error),      // #[from] 自动带 #[source]，链路里能看到底层错误
}

#[derive(Debug, Clone, Serialize, sqlx::FromRow)]
pub struct User {
    pub id: i64,
    pub email: String,
    pub balance_cents: i64,             // 金额整数分，不用 f64
}

pub async fn find_user(pool: &PgPool, user_id: i64) -> Result<User, UserError> {
    sqlx::query_as::<_, User>("SELECT id, email, balance_cents FROM users WHERE id = $1")
        .bind(user_id)
        .fetch_optional(pool)           // fetch_one 的 RowNotFound 无法与真实 DB 错误区分，故用 optional
        .await?
        .ok_or(UserError::NotFound(user_id))
}
```

依赖：`tokio = { features = ["full"] }`、`sqlx = { version = "0.8", features = ["runtime-tokio", "postgres"] }`、`thiserror = "2"`、`serde = { features = ["derive"] }`。

## 性能

- release profile 基线：`lto = "fat"`（或 `"thin"` 换编译时间）、`codegen-units = 1`、`opt-level = 3`；`panic = "abort"` 权衡见错误处理节；`debug = 1` 保留行号供 perf/flamegraph；`strip = true` 减体积。
- 先测再改：`cargo flamegraph`/`perf record` 看 CPU，`dhat`/`heaptrack` 看分配；`cargo build --timings` 看编译瓶颈；`criterion` 或 `divan` 做微基准，`#[bench]` 仍是 nightly。
- 分配是最常见热点：循环里 `format!`/`to_string()`/`collect::<Vec<_>>()` 中间结果、`String` 反复 `+`；用 `with_capacity`、`write!` 到复用 buffer、迭代器链到最后再 `collect`、`Bytes` 零拷贝切片、`SmallVec`。
- `HashMap` 默认 SipHash（抗 HashDoS），键可信时换 `ahash`/`rustc-hash`（FxHash）快 2–5 倍；`sort_unstable_by_key` 比 `sort_by_key` 快且无额外分配。
- 泛型单态化 vs `dyn Trait`：热路径小函数用泛型（可内联），插件/策略集合用 `Box<dyn Trait>` 控制编译时间与二进制体积；跨 crate 内联需要 `#[inline]` 或 LTO。
- 全局分配器：多线程高频分配换 `mimalloc`/`jemalloc`（`#[global_allocator]` 一行），常见 10–30% 提升。

## unsafe 准则

- 每个 `unsafe {}` 块前 `// SAFETY:` 写清依赖的不变量；`unsafe fn` 文档写 `# Safety` 段说明调用方义务。
- 不变量：任何时刻对同一内存不能同时存在 `&mut` 与其他引用；`mem::zeroed()`/`MaybeUninit::assume_init` 只对全零/已初始化合法的类型；`transmute` 是最后手段，先找 `from_ne_bytes`/`bytemuck`/`zerocopy`。
- FFI：`CString::new(s)?.as_ptr()` 临时值当行结束就被释放，指针悬垂——先绑定到变量再取指针；`#[repr(C)]` 才有稳定布局；指针来自 C 的内存要用 C 的释放函数。
- 含 unsafe 的 crate 在 CI 跑 `cargo +nightly miri test`（检测 UB：越界、悬垂、未初始化读、数据竞争）；`cargo geiger` 统计 unsafe 面。

## 工具链与工程治理

- `Cargo.toml` `[lints]` 表（1.74+）统一 lint，不靠每个文件的 `#![deny]`：

```toml
[lints.rust]
unsafe_op_in_unsafe_fn = "deny"
missing_docs = "warn"

[lints.clippy]
all = { level = "warn", priority = -1 }
pedantic = { level = "warn", priority = -1 }
unwrap_used = "warn"
expect_used = "warn"
await_holding_lock = "deny"
await_holding_refcell_ref = "deny"
```

- CI 门禁：`cargo fmt --check`、`cargo clippy --all-targets --all-features -- -D warnings`、`cargo nextest run`（进程级隔离、失败重试、分片；doctest 仍需单独 `cargo test --doc`）、`cargo deny check`（advisories/licenses/bans/sources 四合一）、`cargo audit`。
- 发库前 `cargo semver-checks check-release`：对着 crates.io 上一版检测破坏性变更（删公开项、trait 新增无默认方法、枚举加变体但没 `#[non_exhaustive]`）；`cargo public-api` 看公开面 diff。
- feature 组合用 `cargo hack --feature-powerset check`；无用依赖 `cargo machete`；重复版本 `cargo tree -d`；`Cargo.lock` 库与二进制都入库（2023 起官方建议）。
- `rust-toolchain.toml` 固定 channel；MSRV 写进 `rust-version` 并在 CI 用该版本编一遍。
- 测试：`proptest` 做属性测试、`insta` 做快照、`mockall` 做 trait mock；集成测试放 `tests/`，共享 fixture 放 `tests/common/mod.rs`；`#[tokio::test(flavor = "multi_thread")]` 只在需要真并发时用。

## 选型判断

| 场景 | 选择 | 理由 |
|---|---|---|
| async 运行时 | tokio | 生态事实标准；`async-std` 已停止维护；`smol` 只在嵌入/极简场景 |
| HTTP 服务 | Axum 0.8（tower 生态） | 与 tower/hyper 无缝；Actix-web 在纯吞吐基准略高但生态隔离 |
| 数据库 | sqlx（写 SQL、编译期校验）/ SeaORM、Diesel（要 ORM） | sqlx 心智最小；Diesel 同步且类型最强 |
| 错误 | 库 thiserror，应用 anyhow | 类型可匹配 vs 上下文链 |
| 序列化 | serde + serde_json；二进制 `bincode`/`postcard`；跨语言 protobuf（prost） | 按对端与体积要求 |
| 共享状态 | `Arc<Mutex>` → 争用高换 `parking_lot`/`dashmap` → 读多写少 `ArcSwap` | 先测争用再换 |
| 何时不该用 async | 纯 CPU 计算、单机 CLI、连接数 < 几百的同步服务 | 线程 + 阻塞 I/O 更简单，无取消安全问题 |
| 何时不该用 Rust | 原型验证期、团队无人能审 unsafe/生命周期、GC 语言已够用的 CRUD | 编译期成本要换来对应收益 |

## 审查清单

- [ ] `select!` 分支表达式里没有非取消安全操作（`read_exact`/`read_line`/`write_all`）；长 future 已 `pin!` 复用
- [ ] 没有跨 `.await` 持有 `std::sync::MutexGuard`/`RefCell` 借用；临界区在 await 前结束
- [ ] async 上下文无阻塞调用；CPU/阻塞 I/O 走 `spawn_blocking`/rayon
- [ ] `JoinHandle` 有归属（`JoinSet`/`TaskTracker`），关闭路径能等到任务结束
- [ ] 原子操作的 `Ordering` 有理由；跨原子的顺序依赖有 `loom` 测试
- [ ] 库 API 无 `anyhow::Error`/`Box<dyn Error>`；错误枚举 `#[non_exhaustive]`；大错误已 `Box`
- [ ] 请求路径无 `unwrap`/`expect`/`slice[i]`；整数转换用 `TryFrom`；金额非浮点
- [ ] 每个 `unsafe` 块有 `SAFETY:`；FFI 字符串指针不悬垂；`#[repr(C)]`
- [ ] 2024 edition：`unsafe extern`、`#[unsafe(no_mangle)]`、RPIT 捕获用 `use<>` 检查过
- [ ] `[lints]` 表存在；CI 跑 clippy `-D warnings`、nextest、deny/audit；发库跑 semver-checks
- [ ] sqlx ≥ 0.8.1；`query!` 有离线数据；事务显式 `commit`；`fetch_optional` 区分不存在
- [ ] tracing span 用 `.instrument()`，无 `enter()` 跨 await
