# 按栈发布与回滚检查

只检查本次发布涉及的栈；命令跟随项目脚本、工具版本与部署平台。计划请求和缺少平台授权时只填写方案，不执行 reload、迁移、流量切换或清缓存。下列命令名是待核对入口，不是自动执行指令。

## Go

- 固定 binary/镜像 digest、构建 commit 和配置版本，逐实例读取脱敏运行版本。
- readiness 摘流与排空顺序按项目生命周期约定；HTTP/gRPC、WebSocket/SSE 和后台 worker 分开统计在途工作。
- 设置有来源的排空期限及强制退出处理；确认旧实例退出、新实例接流量、幂等与重试语义未变化。
- 回滚前确认旧代码能处理扩展后的 schema、已发消息和缓存格式；不能只恢复二进制。

## PHP-FPM / OPcache

- 确认 PHP/扩展/Composer platform、依赖归档、发布目录或镜像、config/route/view cache 与环境匹配。
- 核对 OPcache timestamp/preload 和发布路径策略，使用项目批准的 FPM reload/restart 或替换实例方式使新代码生效；不要假定 CLI 的 opcache reset 会清理 FPM 缓存。
- 检查新 worker 实际响应版本、旧 worker 排空、错误日志与 slowlog；进程命令成功不等于全部 worker 已使用新代码。
- 回滚将代码、vendor、配置缓存及 FPM/OPcache 更新作为一组检查，随后复测关键请求。

## Laravel Octane / Queue / Horizon / Scheduler

- 列出全部常驻进程、队列、supervisor/平台托管方式与实例。用本项目 `artisan list` 或锁定版本文档确认支持的 reload/restart 命令。
- 可能的入口包括 `octane:reload`、`queue:restart`、`horizon:terminate` 或版本支持的统一 reload；只执行项目适用的一条管理路径，不盲目串行执行全部命令。
- 确认进程管理器能拉起退出的 worker，检查旧任务结束、新任务使用新代码；核对 job timeout 与重投窗口、幂等及新旧 payload 兼容。
- Scheduler 核对是否存在常驻进程/秒级任务及跨版本重复调度；按项目支持的中断/更新方式处理，不默认重启整机。
- 回滚前检查已投递 job、failed_jobs/DLQ、在途副作用和旧消费者兼容性；禁止自动清空队列或全量重放。

## Vue / 前端静态资产

- 校验入口 HTML、manifest、base/public path、内容 hash 和实际返回的 JS/CSS/动态 chunk；测试刷新、深层路由和懒加载。
- 缓存策略区分入口 HTML 和带内容 hash 的资源；旧页面可能继续加载旧 chunk，在批准的客户端/缓存窗口内保留对应资源。
- 核对 CDN/代理及 service worker（仅项目使用时）的更新行为。失效或回滚必须定向且可追踪，不用全量清缓存替代兼容验证。
- 验证旧页面→新 API、新页面→可回滚 API 的允许组合。回滚 HTML 时确认其引用的资源仍可访问。

## OpenResty / 网关

- 保存脱敏配置与版本，语法检查通过后才按授权 reload/切流；具体操作读取 `openresty-gateway-operations`。
- 检查新 worker/路由实际生效、upstream、TLS 和关键业务请求；长连接、流式响应和慢上传单独观察排空。
- 回滚配置、上游、证书引用、缓存版本和限流状态需考虑兼容性；reload 不证明共享状态已清理，也不能把删除 shared dict/缓存作为默认恢复动作。

## 证据与依据

每项记录目标、前后版本、命令/退出码、实例或worker覆盖、观测窗口、请求样本、回滚与结果。没运行就保持未验证；不适用写理由。

参考：[Laravel 部署](https://laravel.com/docs/12.x/deployment)、[PHP OPcache 配置](https://www.php.net/manual/en/opcache.configuration.php)、[Nginx reload](https://nginx.org/en/docs/control.html)。执行前以项目锁定版本、脚本和授权范围为准。
