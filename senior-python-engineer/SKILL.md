---
name: senior-python-engineer
description: 资深 Python 判断与代码：GIL 与 free-threading、asyncio 阻塞边界、FastAPI/Django、SQLAlchemy async、打包分发、类型与 lint 工具链、安全。写或审查 Python 代码、设计 Python 服务时使用。
---

# 资深 Python 工程师

面向 Python 3.10+（默认 3.12/3.13）的工程判断与可证伪事实。所有标注"实测"的结论在 CPython 3.13 上运行验证；标注"3.14"的为该版本新增特性，本机未运行。

## 工作方式
- 先给判断与推荐方案，再给备选与取舍；不确定就说不确定并给出核实方法，不奉承不迎合。
- 代码可直接编译运行、带错误处理，关键决策注释写 why；审查按正确性 → 健壮性 → 性能 → 可维护性排序，每个问题附修复代码。

## 核心规则

1. 金额用 `Decimal` 或整数分，禁止 `float`：`0.1 + 0.2 == 0.30000000000000004`，`round(2.5) == 2`（银行家舍入，实测）。
2. 协程内不得出现同步阻塞调用（`requests`、`time.sleep`、同步驱动、大文件读写）：一次阻塞冻结整个事件循环上的全部请求。阻塞 IO 用 `asyncio.to_thread`，CPU 密集用进程池。
3. `asyncio.create_task()` 的返回值必须持有引用（集合或 `TaskGroup`），事件循环只持弱引用，未被引用的任务可能在执行中途被 GC 回收（asyncio 官方文档明示）。
4. 反序列化外部输入禁止 `pickle.loads`、`yaml.load`（无 Loader）、`eval`/`exec`、`marshal`：实测一个带 `__reduce__` 的 pickle 对象在 `loads` 时直接执行任意函数。
5. SQLAlchemy async 的 `AsyncSession` 必须 `expire_on_commit=False`：commit 后访问属性会触发隐式同步加载，报 `sqlalchemy.exc.MissingGreenlet`。库存/余额类"先查后改"必须 `with_for_update()` 或原子 `UPDATE ... WHERE stock >= :n`。
6. 容器基础镜像用 `python:3.x-slim`（Debian），不用 `alpine`：musl 没有 manylinux wheel，numpy/pydantic-core/cryptography 等要么现场编译、要么根本装不上，镜像反而更大、构建更慢。
7. `except Exception:` 捕获后必须记录（`logger.exception`）或重新抛出；`except*` 只用于处理 `ExceptionGroup`（见版本表），不是裸 `except` 的替代。
8. 依赖锁定用 lockfile（`uv lock` 生成跨平台 universal lock），CI 与镜像用 `uv sync --frozen`；只写 `requirements.txt` 的项目无法复现构建。
9. 类型标注是契约：公开函数签名全部标注，`mypy --strict` 或 pyright strict 进 CI；`# type: ignore` 必须带错误码 `[code]` 与原因。
10. 日志用 `logger.info("x=%s", x)` 延迟格式化并保留结构，不用 f-string 拼进消息；用户可控字符串绝不能作为 `str.format` 的模板（见安全节）。

## 版本特性归属（避免错配）

| 特性 | 版本 | 说明 |
|---|---|---|
| `match` 结构化模式匹配 | 3.10 | 用于按形状解构（AST、事件、命令），不是 `dict.get` 或 `if/elif` 的通用替代 |
| `X \| None`、`ParamSpec`、`TypeGuard` | 3.10 | 内置泛型 `list[int]` 3.9 起 |
| `ExceptionGroup` / `except*` | 3.11 | `except*` 匹配的是组内异常；实测裸 `raise ValueError` 落入 `except* ValueError` 时被包装成 `ExceptionGroup` |
| `asyncio.TaskGroup`、`asyncio.timeout()` | 3.11 | 任一任务失败时兄弟任务被取消（实测），异常以 `ExceptionGroup` 抛出；`TimeoutError is asyncio.TimeoutError`（实测 True） |
| `tomllib`、`Self`、`StrEnum`、`typing.Never` | 3.11 | |
| PEP 695：`type X = ...`、`class Box[T]:` | 3.12 | `type` 语句定义**类型别名**（`TypeAliasType`，实测），与 `TypedDict`/`dataclass` 无关 |
| `typing.override`、`itertools.batched`、`Path.walk` | 3.12 | |
| `datetime.utcnow()` 弃用 | 3.12 | 实测 DeprecationWarning；改用 `datetime.now(UTC)` |
| `asyncio.get_event_loop()` 无运行中 loop | 3.12 | 实测 3.13 发 DeprecationWarning "There is no current event loop"；用 `asyncio.run()` / `get_running_loop()` |
| free-threaded 构建（PEP 703） | 3.13 | 实验性，需 `python3.13t`；`sys._is_gil_enabled()` 在标准构建返回 True（实测） |
| `warnings.deprecated`、`copy.replace`、PEP 667 `locals()` 语义 | 3.13 | |
| `concurrent.interpreters`（PEP 734） | 3.14 | 实测 3.13 无此模块；每个子解释器独立 GIL，可做进程内并行 |
| free-threading 转正（PEP 779）、t-string（PEP 750）、延迟求值注解（PEP 649） | 3.14 | 3.13 上 `def f(x: Undefined)` 立即 NameError（实测），3.14 起延迟 |
| `except A, B:` 免括号（PEP 758）、`finally` 中 `return/break` 告警（PEP 765） | 3.14 | 3.13 上前者 SyntaxError、后者静默通过（实测） |

## 语言陷阱（实测）

```python
def append(x, acc=[]):        # ❌ 默认值在定义时创建一次，跨调用共享：第二次返回 [1, 1]
    acc.append(x); return acc

fs = [lambda: i for i in range(3)]   # ❌ 闭包捕获变量而非值：全部返回 2
fs = [lambda i=i: i for i in range(3)]  # ✅ 或 functools.partial

for k in d: d[k + 10] = 1     # ❌ RuntimeError: dictionary changed size during iteration
for k in list(d): ...         # ✅ 先拷贝键

class Repo:
    @functools.lru_cache        # ❌ 缓存键含 self，实例永远不会被回收（实测 gc 后仍存活）
    def load(self, uid): ...   # ✅ 用 cachetools 的实例级缓存或模块级函数缓存
```

- `int("9" * 5000)` 抛 `ValueError: Exceeds the limit (4300 digits)`（3.11 起的 DoS 防护，实测）；解析超长数字字符串要先限长。
- naive 与 aware `datetime` 比较抛 `TypeError`（实测）；入库统一 UTC aware。
- `x is y` 只用于 `None`/`True`/`False`/哨兵；整数与字符串的 `is` 结果取决于解释器缓存，不是语言保证。
- `json.dumps(2**60)` 不丢精度，但对接 JavaScript 时超过 2^53 的整数要转字符串。
- 可变对象作为 dataclass 字段默认值要用 `field(default_factory=list)`，否则定义期直接报 `ValueError: mutable default`。

## 并发模型选择

| 负载 | 选择 | 理由 |
|---|---|---|
| 网络/磁盘 IO 密集、高连接数 | `asyncio`（FastAPI/aiohttp/httpx） | 单线程事件循环，无 GIL 争用 |
| 阻塞库（旧驱动、boto3、同步 SDK） | `asyncio.to_thread()` / `loop.run_in_executor(None, fn)` | 默认线程池上限 `min(32, cpu+4)`，长时间占满会拖慢其他阻塞调用，必要时自建 `ThreadPoolExecutor` |
| CPU 密集（纯 Python） | `ProcessPoolExecutor` / `multiprocessing`；3.14 起可选 `concurrent.interpreters`；3.13t/3.14t free-threaded 构建下线程可并行 | 标准构建 GIL 下线程无法并行执行字节码；"必须多进程"这一说法在 3.13/3.14 后有了进程内替代，但依赖 C 扩展是否声明支持 free-threading |
| CPU 密集（numpy/pandas/Polars/加密） | 直接用库，线程即可 | 这些库在 C 层释放 GIL |
| 后台任务、跨进程排队 | Celery / arq / Dramatiq | 不要用 `BackgroundTasks` 做需要重试、需要持久化的事情——进程退出即丢 |

```python
# asyncio 阻塞边界：把同步 SDK 推到线程池，事件循环不被冻结
async def fetch_report(client: LegacyClient, rid: str) -> bytes:
    return await asyncio.to_thread(client.download, rid)   # client.download 是同步阻塞 IO

# CPU 密集：进程池，注意参数与返回值都要可 pickle
async def crunch(loop: asyncio.AbstractEventLoop, pool: ProcessPoolExecutor, data: bytes) -> int:
    return await loop.run_in_executor(pool, heavy_compute, data)
```

## FastAPI + SQLAlchemy 2.0 async：事务边界

规则：一次请求一个 `AsyncSession`；事务边界在路由/服务层显式 `commit()`，依赖只负责失败时 `rollback()` 与关闭；`commit()` 必须在返回响应之前完成，否则唯一键冲突等错误会在响应发出后才暴露。

```python
"""订单服务：库存扣减（行锁）+ 金额用 Decimal。"""

from __future__ import annotations

from collections.abc import AsyncIterator
from decimal import Decimal
from typing import Annotated
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException, status
from pydantic import BaseModel, Field
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker, create_async_engine

from app.models import Order, Product

engine = create_async_engine("postgresql+asyncpg://app:secret@db/app", pool_pre_ping=True)
# expire_on_commit=False：async 下 commit 后再访问属性会触发隐式加载并抛 MissingGreenlet
SessionFactory = async_sessionmaker(engine, expire_on_commit=False)


async def get_session() -> AsyncIterator[AsyncSession]:
    async with SessionFactory() as session:
        try:
            yield session
        except Exception:
            await session.rollback()   # 路由未提交或中途抛错：回滚，不吞异常
            raise


router = APIRouter(prefix="/orders", tags=["orders"])


class CreateOrderRequest(BaseModel):
    product_id: UUID
    quantity: int = Field(gt=0, le=1000)


class OrderResponse(BaseModel):
    model_config = {"from_attributes": True}

    id: UUID
    product_id: UUID
    quantity: int
    total_price: Decimal   # 序列化为字符串，客户端不会丢精度


@router.post("/", response_model=OrderResponse, status_code=status.HTTP_201_CREATED)
async def create_order(
    body: CreateOrderRequest,
    session: Annotated[AsyncSession, Depends(get_session)],
) -> Order:
    # with_for_update：对该行加锁，并发请求在此串行，避免超卖
    product = await session.scalar(
        select(Product).where(Product.id == body.product_id).with_for_update()
    )
    if product is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "product not found")
    if product.stock < body.quantity:
        raise HTTPException(status.HTTP_409_CONFLICT, f"insufficient stock: {product.stock}")

    order = Order(
        product_id=product.id,
        quantity=body.quantity,
        total_price=product.price * body.quantity,   # price 列为 Numeric，Python 侧即 Decimal
    )
    product.stock -= body.quantity
    session.add(order)
    await session.commit()          # 提交在返回之前：冲突/约束错误在此处变成 5xx，而非响应后
    return order
```

- 高并发扣减优先用一条原子 SQL：`UPDATE product SET stock = stock - :n WHERE id = :id AND stock >= :n`，按 `rowcount` 判断成败，比行锁更省连接。
- `pool_size` × worker 进程数 ≤ 数据库 `max_connections`；异步应用每个 worker 只有一个进程，连接池大小按并发估，不按 CPU 数。
- Pydantic v2 的 `model_config = {"from_attributes": True}` 替代 v1 的 `orm_mode`；请求体与 ORM 模型分离，禁止把 ORM 对象直接当请求体。

## 数据脚本模板（Polars）

```python
"""清洗 CSV → Parquet；金额转整数分，避免浮点。"""

from __future__ import annotations

import logging
import sys
from pathlib import Path

import polars as pl

logger = logging.getLogger(__name__)


def clean(input_path: Path, output_path: Path) -> tuple[int, int]:
    """返回 (输入行数, 输出行数)。只读一次源文件：行数从同一 DataFrame 取。"""
    if not input_path.is_file():
        raise FileNotFoundError(input_path)

    raw = pl.read_csv(input_path, schema_overrides={"amount": pl.Utf8})   # 金额先当字符串读，防止 float 解析
    cleaned = (
        raw.filter(pl.col("status").is_in(["active", "pending"]))
        .with_columns(
            pl.col("created_at").str.to_datetime("%Y-%m-%d %H:%M:%S"),
            (pl.col("amount").cast(pl.Decimal(scale=2)) * 100).cast(pl.Int64).alias("amount_cents"),
        )
        .drop("amount")
        .drop_nulls(subset=["user_id", "amount_cents"])
        .sort("created_at")
    )
    output_path.parent.mkdir(parents=True, exist_ok=True)
    cleaned.write_parquet(output_path)
    return raw.height, cleaned.height


def main(argv: list[str]) -> int:
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    if len(argv) != 3:
        print(f"usage: {argv[0]} <input.csv> <output.parquet>", file=sys.stderr)
        return 2
    try:
        before, after = clean(Path(argv[1]), Path(argv[2]))
    except (FileNotFoundError, pl.exceptions.PolarsError) as exc:
        logger.error("clean failed: %s", exc)
        return 1
    logger.info("rows %d -> %d", before, after)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
```

超过内存的数据集改用 `pl.scan_csv(...).sink_parquet(...)` 流式执行；pandas 下逐行 `iterrows`/`apply(axis=1)` 是 O(n) Python 调用，改向量化或 Polars。

## 安全

| 风险 | 事实 | 做法 |
|---|---|---|
| `pickle`/`marshal`/`shelve` | `loads` 执行 `__reduce__` 返回的任意可调用对象（实测） | 外部数据只用 JSON/msgpack；内部缓存要 pickle 则签名（HMAC）后再读 |
| `yaml.load(s)` | PyYAML ≥ 6 强制传 `Loader`，`Loader=yaml.Loader` 可构造任意 Python 对象 | 一律 `yaml.safe_load` |
| `subprocess(..., shell=True)` | 参数拼进 shell 字符串即命令注入 | 传列表 `subprocess.run(["ls", path])`；必须拼字符串时 `shlex.quote`（实测 `'a;rm -rf /'` 被整体引用） |
| `str.format` 模板来自用户 | `"{0.__class__}".format(obj)` 能沿属性链读取任意对象（实测） | 模板只能是代码常量；用户输入只做参数 |
| SSRF | `requests.get(user_url)` 可打到 169.254.169.254、内网服务 | 解析域名后校验 IP 不在私网/链路本地段，禁用自动重定向或对重定向目标再校验，走出站代理白名单 |
| 路径穿越 | `open(base / user_name)` 中 `..` 逃出目录 | `p = (base / name).resolve(); p.is_relative_to(base.resolve())` 为假则拒绝 |
| 随机数 | `random` 可预测 | 令牌/盐用 `secrets.token_urlsafe()` |
| 供应链 | `pip install` 无锁无校验 | lockfile + `--require-hashes`；`pip-audit`；私有 index 用 `--index-url` 而非 `--extra-index-url`（后者会被公共同名包抢注） |

## 打包与部署

- `pyproject.toml`（PEP 621）+ 单一 build backend（`hatchling`/`setuptools>=61`/`uv_build`）；库发 wheel + sdist，纯 Python 发 `py3-none-any`，含 C 扩展按 manylinux/musllinux/macOS/Windows 分别构建（cibuildwheel）。
- 应用不发 wheel，用 lockfile：`uv lock` 生成一份跨平台锁，`uv sync --frozen --no-dev` 在镜像里安装。
- Docker：多阶段，builder 阶段建 venv 装依赖，runtime 阶段只拷 venv + 源码；`PYTHONDONTWRITEBYTECODE=1`、`PYTHONUNBUFFERED=1`；非 root 用户；基础镜像 `python:3.13-slim`。
- ASGI：`uvicorn --workers N` 或 `gunicorn -k uvicorn.workers.UvicornWorker`；N 取 CPU 数级别即可，异步应用的并发靠事件循环不靠进程数；同步 Django/Flask 用 gunicorn sync/gthread worker，`--timeout` 要大于最慢请求。
- 进程内不要自己写 `while True` 定时器做定时任务；用 APScheduler/Celery beat 并保证多副本下只跑一份（分布式锁）。

## 选型判断

| 场景 | 选择 | 理由 |
|---|---|---|
| 新 Web API | FastAPI + Pydantic v2 + SQLAlchemy 2.0 async | 类型即校验即文档；同步 ORM 在 async 路由里会阻塞循环 |
| 后台 Admin、内容站、团队熟 Django | Django（ASGI 可选） | Admin/迁移/权限开箱即用，重写这些不划算 |
| 校验/配置 | Pydantic v2 / `pydantic-settings` | 比 dataclass 多校验；纯内部数据结构用 `@dataclass(slots=True, frozen=True)` |
| 数据处理 > 内存 | Polars lazy + `sink_*` | pandas 全量载入且单线程 |
| 依赖/环境管理 | uv | lock、venv、Python 版本管理一体；Poetry 可用，pip-tools 仅维护存量 |
| 任务队列 | Celery（生态）/ arq（纯 async，Redis） | Celery 与 asyncio 混用要 `asgiref.sync` 桥接，能不混就不混 |
| 类型检查 | pyright（快、推断强）或 mypy（插件生态） | 二选一进 CI，不并行跑两个 |

## 审查清单

- [ ] 协程内没有同步阻塞调用；阻塞库经 `to_thread`/executor
- [ ] `create_task` 结果被持有或使用 `TaskGroup`
- [ ] 金额、比例等精度敏感值用 `Decimal`/整数，无 `float`
- [ ] `AsyncSession` 配 `expire_on_commit=False`；写路径 `commit()` 在响应返回前；扣减用行锁或原子 UPDATE
- [ ] 无 `pickle.loads`/`yaml.load`/`eval` 处理外部输入；`subprocess` 不用 `shell=True`
- [ ] 用户可控字符串未作为 `str.format`/`%` 模板；出站 URL 做了 SSRF 校验
- [ ] 无可变默认参数；闭包在循环中绑定了当前值
- [ ] `except` 分支记录或重抛，`except*` 只出现在 `ExceptionGroup` 场景
- [ ] `datetime` 全部 aware UTC；无 `utcnow()`
- [ ] 版本特性与目标解释器匹配（`type` 语句 3.12、`TaskGroup` 3.11、`concurrent.interpreters` 3.14）
- [ ] lockfile 存在且 CI 用 `--frozen` 安装；基础镜像非 alpine
- [ ] 公开函数完整类型标注；`# type: ignore[code]` 带原因
