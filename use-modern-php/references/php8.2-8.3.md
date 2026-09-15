# PHP 8.2–8.3 特性

## PHP 8.2+

```php
// ✅ 实测：readonly 类 —— 所有属性自动 readonly，外部写入抛 Error
final readonly class Point
{
    public function __construct(public int $x, public int $y) {}
}

// ✅ 实测：trait 里可以定义常量
trait HasVersion { public const VERSION = '1.0'; }

// ✅ 实测：#[\SensitiveParameter] —— 异常栈里该参数被替换为 SensitiveParameterValue 对象
function login(string $user, #[\SensitiveParameter] string $password): void { /* ... */ }
// getTrace()[0]['args'] 实测为 ['bob', object(SensitiveParameterValue)]，日志/Sentry 不再泄露明文
```
DTO / 值对象一律 `final readonly class`；密码、token、密钥类参数一律加 `#[\SensitiveParameter]`。
8.2 起动态属性（未声明就 `$obj->foo = 1`）废弃，需要的类显式加 `#[\AllowDynamicProperties]`。

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

// ✅ 实测：8.3 起 __clone 内可重新初始化 readonly 属性（深拷贝的官方入口）
final class Bag
{
    public function __construct(public readonly array $items) {}
    public function __clone(): void { $this->items = [...$this->items, 'cloned']; }
}
```
