---
name: use-modern-php
description: 编写现代 PHP 代码的强制性规范指南。当用户编写任何 PHP 代码、要求 PHP 代码审查、PHP 重构、Laravel/Symfony 项目开发、或讨论 PHP 语法与最佳实践时，必须触发此 skill。即使用户没有明确提到"modern"或"现代"，只要涉及 PHP 代码生成、PHP 代码片段、PHP 函数/类编写、PHP 项目架构，都应触发。关键词包括但不限于：PHP、Laravel、Symfony、Composer、Eloquent、PHP 8、PHP 8.0+、PHP 8.1+、PHP 8.2+、PHP 8.3+、PHP 8.4+、PHP 8.5、enum、readonly、match、构造器属性提升、property hooks、非对称可见性、first-class callable、pipe operator、strict_types、PHP 代码审查、PHP 重构、PHP 升级。本 skill 是 senior-php-engineer 引用的专项 skill。
---

# Modern PHP Guidelines

本文所有语法与行为结论均在 **PHP 8.5.9**（官方 `php:cli` 镜像）上实测运行得出，
标注「实测」的即真实结果；每条特性都标了最低版本，便于对着项目的 `composer.json` 取舍。

## 目标 PHP 版本

**默认目标版本：PHP 8.5**

如果用户提供了 `composer.json` 的 `require.php` 约束或明确指定了版本，以用户指定的为准；
否则按 8.5 写，并在使用 8.2+ 特性时标注版本，方便对方判断能否升级。

## 核心原则

1. **每个文件顶部 `declare(strict_types=1);`** —— 没有它，`int` 形参会静默接受 `"5"`，类型声明形同虚设
2. 使用目标版本及以下的现代特性，绝不使用已有现代替代方案的旧模式
3. 类型声明写全：参数、返回值、属性，包括 `void`、`never`、`static`
4. 默认 `final` + 组合，不要为了复用而继承
5. 不可变优先：`readonly` 属性 / `readonly` 类

## PHP 8.0+

**构造器属性提升 + 命名参数：**

```php
// ✅ 实测
final class Money
{
    public function __construct(
        public readonly int $amount = 0,        // readonly 需 8.1
        public readonly string $currency = 'CNY',
    ) {}
}
$m = new Money(currency: 'USD', amount: 100);   // 命名参数，顺序无关

// ❌ 旧写法：声明属性 + 构造器逐个赋值，同样的信息写三遍
```

命名参数让布尔位置参数可读：`send($msg, retry: true)` 胜过 `send($msg, true)`。
但**命名参数是 API 契约的一部分**——改形参名就是破坏性变更。

**`match` 取代 `switch`：**

```php
// ✅ 实测：严格比较（===）、必须穷尽、有返回值、不会穿透
$label = match($status) {
    'paid', 'settled' => 'done',
    'pending'         => 'waiting',
    default           => throw new InvalidArgumentException("未知状态: {$status}"),
};

// ❌ switch 用 == 松散比较、需要 break、无返回值
```

`match` 无匹配且无 `default` 时抛 `UnhandledMatchError`——这是特性不是缺陷：新增枚举值时立刻炸，而不是静默走 default。

**其他 8.0：**

```php
$name = $user?->profile?->name;                  // nullsafe，实测 null 链路返回 NULL
str_contains($h, $n); str_starts_with($h, $n); str_ends_with($h, $n);   // 实测全部可用
function f(int|string $id): string|false {}      // 联合类型
try { risky(); } catch (RuntimeException) {}      // 实测：catch 可不绑变量
$x = $cond ? throw new LogicException() : $v;    // throw 作为表达式
```

## PHP 8.1+

**枚举取代常量类：**

```php
// ✅ 实测
enum Status: string
{
    case Paid    = 'paid';
    case Pending = 'pending';

    public function label(): string
    {
        return match($this) {
            Status::Paid    => '已支付',
            Status::Pending => '待支付',
        };
    }
}

Status::from('paid')->label();     // 实测 '已支付'；非法值抛 ValueError
Status::tryFrom('x');              // 实测 NULL，用于外部输入
Status::cases();                   // 全部 case，用于生成下拉/校验

// ❌ 旧写法：class Status { const PAID = 'paid'; } —— 没有类型，任意字符串都能冒充
```

枚举可实现接口、可有常量与静态方法，但**不能有状态**（没有实例属性）。

**`readonly` 属性 / first-class callable / `never`：**

```php
final class Order
{
    public readonly int $id;        // 只能在声明作用域内初始化一次，之后写入抛 Error

    public function __construct(int $id) { $this->id = $id; }

    public function handle(): void {}

    public function callables(): void
    {
        $fn = strlen(...);          // 实测：first-class callable，比 'strlen' 可静态分析
        $m  = $this->handle(...);   // 方法同理
        unset($fn, $m);
    }
}

function fail(string $m): never { throw new RuntimeException($m); }   // 实测返回类型 never

array_is_list([1, 2]);              // 实测 true；[1 => 'a'] 为 false —— 区分数组与字典
```

## PHP 8.2+

```php
// ✅ 实测：readonly 类 —— 所有属性自动 readonly，外部写入抛 Error
final readonly class Point
{
    public function __construct(public int $x, public int $y) {}
}

// ✅ 实测：trait 里可以定义常量
trait HasVersion { public const VERSION = '1.0'; }
```

DTO / 值对象一律 `final readonly class`。

## PHP 8.3+

```php
// ✅ 实测：类常量带类型 —— 子类覆盖时类型不符会报错
final class Config
{
    public const string ENV = 'prod';
    public const int RETRIES = 3;
}

// ✅ 实测：json_validate() —— 只校验不构造对象，省内存
json_validate('{"a":1}');           // true
json_validate('{bad');              // false
// ❌ 旧写法：json_decode() 后判 json_last_error()，白白构造了整个对象

// ✅ 实测：动态取类常量
$name = 'RETRIES';
Config::{$name};                    // 3

abstract class Handler { abstract public function handle(): void; }

final class MyHandler extends Handler
{
    #[\Override]                    // 覆盖意图声明；父类没这方法就编译报错
    public function handle(): void {}
}
```

## PHP 8.4+

**属性钩子取代 getter/setter：**

```php
// ✅ 实测
class Temp
{
    public function __construct(private float $c = 0.0) {}

    public float $fahrenheit {
        get => $this->c * 9 / 5 + 32;
        set (float $v) { $this->c = ($v - 32) * 5 / 9; }
    }
}
$t = new Temp(100.0);
$t->fahrenheit;                     // 实测 212
$t->fahrenheit = 32.0;
$t->fahrenheit;                     // 实测 32
```

**非对称可见性 —— 外部只读、内部可写，不必写 getter：**

```php
// ✅ 实测
class Acct { public private(set) int $balance = 10; }
$a = new Acct();
$a->balance;                        // 实测 10，可读
$a->balance = 99;                   // 实测抛 Error
```

比 `readonly` 更灵活：`readonly` 连自己也只能写一次，`private(set)` 允许类内多次修改。

**其他 8.4：**

```php
new DateTime('2026-01-01')->format('Y');       // 实测：new 后可直接链式调用，无需括号包裹
// ❌ 旧写法：(new DateTime('2026-01-01'))->format('Y')

array_find($nums,  fn($n) => $n > 4);          // 实测返回首个命中的「值」（不是索引）
array_any($nums,   fn($n) => $n > 10);         // 实测 bool
array_all($nums,   fn($n) => $n > 0);          // 实测 bool
// ❌ 旧写法：array_filter(...) 之后取 reset()/count()，多遍历一次还多建数组
```

## PHP 8.5+

**管道运算符 `|>` —— 取代深层嵌套调用：**

```php
// ✅ 实测：右侧必须是「可调用值」，裸函数名不行
$slug = '  Hello World  '
    |> trim(...)
    |> strtolower(...)
    |> (fn(string $s): string => str_replace(' ', '-', $s));
// 实测结果：'hello-world'

// ❌ 写成 |> trim 会报 Undefined constant "trim" —— 必须用 first-class callable 语法
// ❌ 旧写法：str_replace(' ', '-', strtolower(trim($s))) —— 从里往外读
```

**`#[\NoDiscard]` + `(void)` —— 让"忽略返回值"变成显式决定：**

```php
// ✅ 实测
#[\NoDiscard('返回值是校验结果，必须处理')]
function validate(int $n): bool { return $n > 0; }

$ok = validate(1);                  // 正常消费
(void) validate(1);                 // 实测：显式声明故意不用，无告警
validate(2);                        // 实测告警：
// Warning: The return value of function validate() should either be used or
// intentionally ignored by casting it as (void), 返回值是校验结果，必须处理
```

给所有「返回值是错误状态/校验结果」的函数加 `#[\NoDiscard]`，把静默忽略变成可见告警。

**其他 8.5：**

```php
// 实测：静态属性也支持非对称可见性
final class Registry
{
    public private(set) static int $count = 0;
    public static function bump(): void { static::$count++; }
}
Registry::$count;                   // 实测 1（bump 之后）
Registry::$count = 99;              // 实测抛 Error

// 实测：构造器属性提升支持 final
class Base { public function __construct(public final string $id) {} }

// 实测：first-class callable 可用于常量表达式
class C { const FN = strlen(...); }
(C::FN)('hello');                   // 5
// 注意：箭头函数不行 —— const FN = fn($x) => $x 报
// "Constant expression contains invalid operations"
```

## 代码审查清单

审查 PHP 代码时逐项检查：

1. 文件顶部有 `declare(strict_types=1);`
2. `switch` → `match`（严格比较 + 穷尽性）
3. 常量类 → `enum`；外部输入用 `tryFrom` 而非 `from`
4. 属性声明 + 构造器赋值 → 构造器属性提升
5. DTO / 值对象 → `final readonly class`
6. 手写 getter/setter → 属性钩子（8.4）或 `public private(set)`（8.4）
7. `'strlen'` / `[$obj, 'method']` 字符串回调 → `strlen(...)` / `$obj->method(...)`
8. `if ($x === null) return null;` 链 → `?->`
9. `strpos($h, $n) !== false` → `str_contains`
10. `json_decode` + `json_last_error` 仅为校验 → `json_validate()`（8.3）
11. 类常量补类型声明（8.3）
12. `(new X(...))->m()` → `new X(...)->m()`（8.4）
13. `array_filter` 后只取首个/判空 → `array_find` / `array_any` / `array_all`（8.4）
14. 深层嵌套函数调用 → `|>`（8.5，右侧用 `f(...)`）
15. 返回错误状态的函数加 `#[\NoDiscard]`（8.5）
16. 覆盖父类方法加 `#[\Override]`（8.3）
17. 抛异常的终止函数标 `: never`
18. 类默认 `final`，需要继承才去掉
