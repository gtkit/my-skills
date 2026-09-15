# PHP 8.4–8.5 特性

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
钩子与 `readonly` 互斥：实测 `public readonly int $x { get => 1; }` 编译报错 `Hooked properties cannot be readonly`。

**非对称可见性 —— 外部只读、内部可写，不必写 getter：**

```php
// ✅ 实测
class Acct { public private(set) int $balance = 10; }
$a = new Acct();
$a->balance;                        // 实测 10，可读
$a->balance = 99;                   // 实测抛 Error
```
比 `readonly` 更灵活：`readonly` 连自己也只能写一次，`private(set)` 允许类内多次修改。
8.4 起 `readonly` 隐含 `protected(set)`，子类也能初始化它。外部改写**已初始化**的 readonly 属性报的仍是 `Cannot modify readonly property P::$x`（实测）；
`Cannot modify protected(set) readonly property P::$x from global scope` 这条只在从类外做 `clone($obj, [...])` 覆盖时出现（实测，见 8.5 节）。

**其他 8.4：**

```php
new DateTime('2026-01-01')->format('Y');       // 实测：new 后可直接链式调用，无需括号包裹
// ❌ 旧写法：(new DateTime('2026-01-01'))->format('Y')

array_find($nums,  fn($n) => $n > 4);          // 实测返回首个命中的「值」（不是索引）
array_any($nums,   fn($n) => $n > 10);         // 实测 bool
array_all($nums,   fn($n) => $n > 0);          // 实测 bool
// ❌ 旧写法：array_filter(...) 之后取 reset()/count()，多遍历一次还多建数组

#[\Deprecated(message: 'use bar() instead', since: '2.0')]
function foo(): int { return 1; }
foo();   // 实测 E_USER_DEPRECATED：Function foo() is deprecated since 2.0, use bar() instead
// 库作者用它替代 docblock @deprecated：调用方在运行时/CI 里真能看到，而不是靠 IDE 划线
```
8.4 起隐式可空参数废弃：`function f(string $s = null)` 实测报
`Implicitly marking parameter $s as nullable is deprecated, the explicit nullable type must be used instead`——升级 8.4 前全仓 `grep` 一遍改成 `?string $s = null`，Rector 规则 `ExplicitNullableParamTypeRector` 可批量处理。

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
**`clone(...)` 带属性覆盖 —— readonly 对象派生新值的官方解法：**

```php
// ✅ 实测
final readonly class P
{
    public function __construct(public int $x, public int $y) {}
    public function withX(int $x): static { return clone($this, ['x' => $x]); }
}
$q = new P(1, 2)->withX(9);        // 实测 $q->x === 9，$q->y === 2，原对象不变
clone(new P(1, 2), ['x' => 5]);    // 实测抛 Error：Cannot modify protected(set) readonly property P::$x from global scope
```
覆盖发生在 `__clone()` 之后，可见性按调用处作用域判定：所以 `withX()` 这类方法必须写在类内部。8.5 之前的等价写法是手写 `new static(x: $x, y: $this->y)`——字段一多就漏。

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
array_first([3 => 'a', 9 => 'b']);  // 实测 'a'；array_last(...) 实测 'b'；空数组实测 NULL
// ❌ 旧写法：reset($arr) 会移动内部指针，$arr[array_key_first($arr)] 写两遍

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

// 实测：常量表达式里可以放 first-class callable 与 static 闭包（类常量、默认参数、Attribute 参数、静态属性）
class C
{
    const FN = strlen(...);
    const DOUBLE = static function (int $x): int { return $x * 2; };
}
(C::FN)('hello');                   // 5
(C::DOUBLE)(21);                    // 42
// ❌ 实测：非 static 闭包报 "Closures in constant expressions must be static"
// ❌ 实测：箭头函数（含 static fn）报 "Constant expression contains invalid operations"——
//    因为箭头函数会自动按值捕获外层变量，常量表达式没有可捕获的作用域
```
8.5 起 `(integer)`/`(boolean)`/`(double)` 非规范类型转换废弃（实测原文 `Non-canonical cast (integer) is deprecated, use the (int) cast instead`）。
