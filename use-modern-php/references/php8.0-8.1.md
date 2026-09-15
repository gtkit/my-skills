# PHP 8.0–8.1 特性

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
// ✅ 实测：严格比较（===）、有返回值、不会穿透
$label = match($status) {
    'paid', 'settled' => 'done',
    'pending'         => 'waiting',
    default           => throw new InvalidArgumentException("未知状态: {$status}"),
};

// ❌ switch 用 == 松散比较、需要 break、无返回值
```
`match` **没有编译期穷尽检查**：无匹配且无 `default` 时在运行时抛 `UnhandledMatchError`
（实测原文 `Unhandled match case 5`）。这是特性不是缺陷：新增枚举值时立刻炸，而不是静默走 default。真正的静态穷尽检查靠 PHPStan/Psalm 对 enum 分支的分析，不要指望引擎。

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
