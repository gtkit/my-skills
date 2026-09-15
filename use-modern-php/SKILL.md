---
name: use-modern-php
description: 现代 PHP 语法与版本归属（PHP 8.0–8.5）：match、enum、readonly、property hooks、pipe operator、clone with 等，附实测报错原文。编写、审查或升级 PHP 代码时使用；运行时与框架归 senior-php-engineer。
---

# Modern PHP Guidelines

本文所有语法与行为结论均在 **PHP 8.5.x**（官方 `php:cli` 镜像 8.5.9 与 php-wasm 8.5.8）上实测运行得出，
标注「实测」的即真实结果；每条特性都标了最低版本，便于对着项目的 `composer.json` 取舍。

## 目标 PHP 版本

**默认目标版本：PHP 8.5**。如果用户提供了 `composer.json` 的 `require.php` 约束或明确指定了版本，以用户指定的为准；
否则按 8.5 写，并在使用 8.2+ 特性时标注版本，方便对方判断能否升级。支持周期（2 年 active + 2 年 security）：8.1 已于 2025-12 停止安全更新，8.2 安全维护到 2026-12，
8.3 到 2027-12，8.4 到 2028-12。

## 核心原则

1. **每个文件顶部 `declare(strict_types=1);`** —— 没有它，`int` 形参会静默接受 `"5"`，类型声明形同虚设
2. 使用目标版本及以下的现代特性，绝不使用已有现代替代方案的旧模式
3. 类型声明写全：参数、返回值、属性，包括 `void`、`never`、`static`
4. 默认 `final` + 组合；只有被框架代理/继承的类（Doctrine 实体、Eloquent 模型、被 Mock 的抽象）才去掉 `final`
5. 不可变优先：`readonly` 属性 / `readonly` 类，派生新值用 8.5 `clone(...)`（见 `references/php8.4-8.5.md`）

## 按任务读取

以下内容按任务读取，只读本次需要的文件；核心规则与审查清单已覆盖其结论。

| 任务 | 读 |
|---|---|
| 项目 PHP 8.0–8.1（构造器属性提升、match、enum、readonly、first-class callable） | `references/php8.0-8.1.md` |
| 项目 PHP 8.2–8.3（只读类、DNF 类型、类型化常量、#[Override]） | `references/php8.2-8.3.md` |
| 项目 PHP 8.4–8.5（property hooks、非对称可见性、pipe operator、clone with） | `references/php8.4-8.5.md` |

## readonly 的边界（8.1–8.5 实测）

- 不能有默认值：`public readonly int $x = 1;` 编译报错 `Readonly property R::$x cannot have default value`；要默认值走构造器提升的参数默认值。
- `readonly class` 不能有静态属性、不能有动态属性；子类必须也是 `readonly class`。
- 浅不可变：属性里存的对象本身仍可变；但通过属性间接改数组元素（`$o->items[0]->v = 1`）实测抛 `Cannot indirectly modify readonly property Holder::$items`。
- `unserialize()` 能填充 readonly 属性（它绕过构造器，属性此时处于未初始化态），实测 `serialize`/`unserialize`
  往返后值保留、再写入抛 `Cannot modify readonly property Q::$x`。反序列化不是"绕过不可变"的漏洞，但 `unserialize` 外部输入本身是 RCE 面（见 senior-php-engineer）。
- Doctrine ORM 通过生成子类实现懒加载代理，实体类不能是 `final`；`final readonly class` 只给 DTO/值对象，不当实体。
- 8.3 之前 `__clone` 里不能改 readonly 属性，深拷贝无解；8.3 起可以，8.5 起优先用 `clone($this, [...])`。

## 运行时：类型与语法的代价在哪

- `strict_types` 与完整类型声明的运行时开销可忽略；请求耗时的大头是 autoload 的文件 I/O 与 OPcache 未命中。
  生产必须开 OPcache，不可变部署设 `opcache.validate_timestamps=0`，
  CPU 密集型代码再考虑 `opcache.jit=tracing`，Laravel 这类 I/O 型应用 JIT 收益通常在 5% 以内。
  参数、preload、Octane 常驻内存下的坑见 senior-php-engineer。
- Attributes 存在 AST 里，不受 `opcache.save_comments=0` 影响；docblock 注解会受影响。
- 静态分析是穷尽性、泛型（`array<int, User>`）、`mixed` 收窄的唯一保障：PHPStan 2.0（2024-11）共 0–10 级，
  新项目直接 level 9 起步（禁止隐式 `mixed`），老项目用 baseline 文件逐级抬。

## 代码审查清单

1. 文件顶部有 `declare(strict_types=1);`
2. `switch` → `match`（严格比较；穷尽性由 PHPStan 检查，不是引擎）
3. 常量类 → `enum`；外部输入用 `tryFrom` 而非 `from`
4. 属性声明 + 构造器赋值 → 构造器属性提升
5. DTO / 值对象 → `final readonly class`；派生新值用 `clone($this, [...])`（8.5）而非手写 `new static(...)`
6. 手写 getter/setter → 属性钩子（8.4）或 `public private(set)`（8.4）；钩子不能与 `readonly` 同用
7. `'strlen'` / `[$obj, 'method']` 字符串回调 → `strlen(...)` / `$obj->method(...)`
8. `if ($x === null) return null;` 链 → `?->`
9. `strpos($h, $n) !== false` → `str_contains`
10. `json_decode` + `json_last_error` 仅为校验 → `json_validate()`（8.3）
11. 类常量补类型声明（8.3）
12. `(new X(...))->m()` → `new X(...)->m()`（8.4）
13. `array_filter` 后只取首个/判空 → `array_find` / `array_any` / `array_all`（8.4）；取首尾元素 → `array_first`/`array_last`（8.5）
14. 深层嵌套函数调用 → `|>`（8.5，右侧用 `f(...)`）
15. 返回错误状态的函数加 `#[\NoDiscard]`（8.5）
16. 覆盖父类方法加 `#[\Override]`（8.3）；废弃 API 加 `#[\Deprecated]`（8.4）
17. 密码/token 参数加 `#[\SensitiveParameter]`（8.2）
18. `function f(T $x = null)` → `?T $x = null`（8.4 起废弃告警）；`(integer)` 等非规范转换 → `(int)`（8.5 起废弃）
19. 抛异常的终止函数标 `: never`
20. 类默认 `final`，需要继承/被代理才去掉
