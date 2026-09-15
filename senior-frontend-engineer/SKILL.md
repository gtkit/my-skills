---
name: senior-frontend-engineer
description: 资深前端判断与可运行代码：Core Web Vitals、React/Vue 渲染与水合、现代 CSS 与兼容、Vite 构建与包体、前端安全、可访问性。涉及浏览器端页面、组件、样式、构建时使用；Node 服务端归 senior-nodejs-engineer。
---

# 资深前端工程师

面向生产的浏览器端工程：性能指标、渲染与水合、框架行为、CSS 兼容、安全与可访问性。Node 服务端归 senior-nodejs-engineer。

## 工作方式
- 先给判断与推荐方案，再给备选与取舍；不确定就说不确定并给出核实方法，不奉承不迎合。
- 代码可直接编译运行、带错误处理，关键决策注释写 why；审查按正确性 → 健壮性 → 性能 → 可维护性排序，每个问题附修复代码。

## 版本口径

- React 19（2024-12）；19.1 Owner Stacks；19.2（2025-10）`<Activity>`、`useEffectEvent`、`cacheSignal`、DevTools Performance Tracks。React Compiler 1.0（2025-10）配 `eslint-plugin-react-hooks` 6。
- Vue 3.5（2024-09）：`useTemplateRef`、props 响应式解构稳定、`useId`、懒水合（`hydrateOnVisible` 等）。Nuxt 4（2025-07）：`app/` 目录（检测到旧结构会继续按旧结构工作）、`useAsyncData`/`useFetch` 返回 `shallowRef` 且同 key 组件共享数据、卸载时自动清理。`compatibilityVersion` 的方向按大版本相反：Nuxt 3.12+ 写 `4` 提前试新行为，Nuxt 4 里写 `3` 才是回退。
- Next.js 15（2024-10）：React 19、`fetch`/GET Route Handler **默认不缓存**、`params`/`searchParams`/`cookies()`/`headers()` 变成 Promise。Next.js 16（2025-10）：Turbopack 默认、`middleware.ts` 改名 `proxy.ts`、Cache Components（`use cache`）。
- Vite 7（2025-06）：ESM-only、Node 20.19+/22.12+、默认构建目标 `baseline-widely-available`。Rolldown（Rust 实现的 Rollup 替代）在 Vite 7 以 `rolldown-vite` 包提供，Vite 8 起为默认打包器；dev 的 TS/JSX 转换与 prod 压缩由 Oxc 承担，esbuild/Rollup/terser 退出默认链路。
- TypeScript 7.0（2026-07）是 Go 原生移植，全量构建快 8–12 倍；6.0（2026-03）是 JS 代码库的最后一版，作为迁移桥：6.0 里废弃的选项在 7.0 直接报错。7.0 新默认值 `strict: true`、`module: esnext`、`types: []`、`rootDir: ./`，升级时先把这些显式写进 tsconfig。Tailwind 4（2025-01）CSS-first 配置（`@theme`），要求 Safari 16.4+/Chrome 111+/Firefox 128+。
- 浏览器兼容用 Baseline 表述：Widely available = 四大引擎（Chrome/Edge/Firefox/Safari）都支持满 30 个月；Newly available = 四引擎已齐但未满 30 个月。

## Core Web Vitals 与性能

- 三项指标：**LCP ≤ 2.5s、INP ≤ 200ms、CLS ≤ 0.1**，按真实用户 p75 判定。FID 已于 2024-03 从 CWV 移除，还在讲 FID 的资料一律过时。
- 实验室 ≠ 现场：Lighthouse 没有真实交互，拿不到 INP。RUM 用 `web-vitals` 库（`onLCP/onINP/onCLS`），`web-vitals/attribution` 版本带归因字段（`interactionTarget`、`lcpEntry.element`、`largestShiftTarget`），在 `visibilitychange` 时 `navigator.sendBeacon` 上报。
- LCP：候选元素 `fetchpriority="high"`，**不加 `loading="lazy"`**（首屏图加 lazy 是 LCP 恶化最常见原因）；`<link rel="preload">` 只给发现晚的资源（CSS 背景图、字体）；TTFB > 800ms 时先修后端/CDN 缓存，前端优化只是零头。
- INP：主线程长任务（> 50ms）阻塞输入响应。拆任务用 `scheduler.yield()`（Chromium 129+，其他引擎回退 `setTimeout(0)`）；React 用 `useTransition`/`useDeferredValue` 降级非紧急更新；事件处理器只做最小状态更新，昂贵渲染延后；第三方脚本 `async` 或 Partytown 挪进 worker。
- CLS：图片/视频/广告位写死 `width`/`height` 或 `aspect-ratio`；字体 `font-display: optional` 或用 `size-adjust` 匹配回退字体度量；动态内容只在交互后或首屏下方插入；动画用 `transform`，不用 `top/left`。
- 性能预算进 CI：`size-limit` 或 Lighthouse CI `budget.json`（如首屏 JS ≤ 200KB gzip、LCP p75 ≤ 2.5s），超预算的 PR 直接失败。
- 包体：barrel file（`index.ts` re-export 全部）让 tree shaking 与 dev 冷启动一起变差，直接导入子路径；`sideEffects: false` 让打包器敢删；按路由 `import()` 切分 + `<link rel="modulepreload">`；图片 AVIF/WebP + `srcset`/`sizes`；`content-visibility: auto` 跳过屏外渲染；长列表虚拟化。

## 渲染、hydration 与 RSC

- 渲染流水线：Parse → Style → Layout → Paint → Composite。读 `offsetWidth`/`getBoundingClientRect()` 之后立刻写样式会强制同步布局（layout thrashing），读写分批。
- Hydration mismatch 的确定性来源：渲染里用 `Date.now()`/`Math.random()`/`Intl` 本地化/`typeof window` 分支；无效 HTML 嵌套（`<p><div>`、`<a>` 套 `<a>`、`<tr>` 不在 `<tbody>`）被浏览器改写 DOM；浏览器扩展注入节点。修法：客户端专属值放 `useEffect`，或 `useSyncExternalStore(subscribe, getSnapshot, getServerSnapshot)`；时间戳类允许 `suppressHydrationWarning`（只作用一层）。React 19 的报错自带 diff，直接看差异。Vue/Nuxt 用 `<ClientOnly>`。
- RSC 边界：Server Component 不能用 state/effect/浏览器 API；`'use client'` 标记边界文件，**该文件及其静态导入的所有模块都进客户端包**。Server → Client 的 props 必须可序列化：普通对象/数组/Date/Map/Set/Promise（流式传输）可以，函数（`'use server'` Action 除外）、类实例、Symbol 不行，报 `Functions cannot be passed directly to Client Components`。Client 组件不能 import Server 组件，但可以通过 `children` 接收。
- Server Actions（`'use server'`）是**公开 HTTP 端点**：每个 action 自己做鉴权与参数校验（zod），参数视为不可信输入；`server-only` 包防止服务端模块被客户端误引。
- 服务端渲染的 HTML 与客户端首屏状态必须来自同一份数据快照，不要在客户端 `useEffect` 里再请求一遍覆盖。

## React 19 具体行为

- `use(promise)`/`use(Context)` 可在条件与循环里调用（Hooks 规则的例外）。传入的 Promise 必须缓存（来自 Server Component props、TanStack Query 或 `useMemo`）；渲染里 `use(fetch(...))` 每次渲染新建 Promise → 无限挂起，控制台报 `A component was suspended by an uncached promise`。
- Actions：`useTransition` 接受 async 函数，`isPending` 覆盖整个异步过程；`<form action={fn}>` + `useActionState(fn, initial)` 返回 `[state, formAction, isPending]`；`useFormStatus()` 必须在 `<form>` 的**子组件**里调用，同层拿不到；`useOptimistic(state, reducer)` 在 action 进行中显示乐观值，失败自动回滚。
- `ref` 是普通 prop（`forwardRef` 不再需要）；ref 回调可返回清理函数；`<Context value>` 直接当 Provider；移除 `propTypes`、函数组件 `defaultProps`、字符串 ref、`ReactDOM.render`；组件里写 `<title>`/`<meta>`/`<link>` 会自动提升到 `<head>`。
- React Compiler 自动 memo 化组件与 Hook，前提是遵守 Rules of React（渲染是纯函数、不在渲染期改 props/state、不在渲染期读写 `ref.current`）。`eslint-plugin-react-hooks` 6 内置编译器 lint（`react-hooks/purity`、`refs`、`immutability`、`set-state-in-effect`）。开了编译器后手写 `memo/useMemo/useCallback` 退为兜底：审查先看是否违反规则导致组件被编译器跳过；`"use no memo"` 是逃生口不是常态。
- StrictMode 开发环境双调用渲染与 effect（挂载→卸载→挂载）：订阅没配清理函数就会重复，这是在暴露 bug，不要关 StrictMode 来"修"。
- 19.2：`<Activity mode="hidden">` 保留状态但卸载 effect 并降低渲染优先级，替代"用 `display:none` 藏路由"；`useEffectEvent` 解决"effect 要读最新 props 但不想因它重跑"的问题，取代手工 `useRef` 同步。

## 状态与数据

- 三类状态三种工具：服务端数据 → TanStack Query 5（`staleTime` 默认 0，每次挂载都重新请求；`useSuspenseQuery` 配 Suspense；queryFn 接收 `signal` 支持取消）；客户端 UI 状态 → `useState`/Zustand/Jotai（Vue 用 Pinia）；URL 可表达的（筛选、分页、tab）→ 搜索参数（`nuqs`），刷新可复现、可分享。
- 服务端数据复制进全局 store 是过时做法：失去缓存失效、请求去重与后台刷新。Redux Toolkit 只在需要严格可追溯的复杂客户端状态机时用，数据层用 RTK Query 而不是手写 thunk。
- 表单：`react-hook-form` + zod resolver（非受控，输入不触发整树重渲染）；简单表单直接 `<form action>` + `useActionState`。
- 派生值不存 state：能从 props/state 算出的值不要用 `useEffect` 同步到另一个 state（多一次渲染且有中间态不一致）。

## 现代 CSS 与 Baseline 兼容

- Widely available（直接用）：容器查询 `@container`、`:has()`、原生嵌套（早期 Chromium 112–119 要求嵌套的元素选择器前加 `&`，120 起不用）、`@layer`、`color-mix()`/`oklch()`、`dvh/svh`、`inset`、逻辑属性、`subgrid`、`:focus-visible`、`inert`、`<dialog>`。
- Newly available（四引擎已齐，看目标用户占比再决定；MDN Baseline 徽章上有转 Newly 的月份，+30 个月即转 Widely）：`text-wrap: balance`（2024-03）、`popover` 属性（2024-04，无 JS 浮层）、`@starting-style` + `transition-behavior: allow-discrete`（2024-08，`display: none` ↔ 可见带过渡）、同文档 View Transitions `document.startViewTransition()`（2025-10）、锚定定位 `anchor-name`/`position-anchor`（2026-01）、`@scope`（2026-03）、`field-sizing: content`（2026-06）。用 `@supports` 渐进增强，核心功能不依赖它们。
- Limited availability（仍只有 Chromium，只能做纯增强）：`interpolate-size`/`calc-size()`（`height: auto` 动画）、滚动驱动动画 `animation-timeline: scroll()`。
- 跨文档 View Transitions（`@view-transition { navigation: auto }`）+ Speculation Rules 预渲染让 MPA 拿到 SPA 级切页体验，是"要不要为了动效上 SPA"的新答案。
- browserslist 直接写 `baseline widely available`（Vite 7 默认）；`last 2 versions` 会漏掉仍有用户的老 Safari，又把无人使用的版本算进去。
- 运行时 CSS-in-JS（styled-components/Emotion）在 RSC 中不可用（需要客户端运行时注入样式），新项目用 Tailwind 4、CSS Modules 或零运行时方案（vanilla-extract、Panda）。

## 前端安全

- XSS 入口：`dangerouslySetInnerHTML`/`v-html`/`innerHTML`/`insertAdjacentHTML`、`<a href={userUrl}>`（`javascript:` scheme）、`iframe src`、把 JSON 塞进 `<script>` 不转义 `<`（`</script>` 逃逸，用 `JSON.stringify(x).replace(/</g, '\\u003c')`）。富文本一律 `DOMPurify.sanitize()`，配 `RETURN_TRUSTED_TYPE: true`。
- CSP：`script-src 'self' 'nonce-<每次响应随机>' 'strict-dynamic'`，禁 `'unsafe-inline'`/`'unsafe-eval'`；Next.js 在 middleware/proxy 里生成 nonce 传给 `<Script>`；先 `Content-Security-Policy-Report-Only` 跑一周收集违规再强制。
- Trusted Types：`require-trusted-types-for 'script'` 让 `innerHTML`/`eval`/`script.src` 等注入点只接受策略对象，DOM XSS 在赋值处被拦；Chromium 全线支持，其他引擎以 Baseline 数据为准，同样先 Report-Only。
- Token 存储：`localStorage` 里的 token 任何 XSS 都能拿走；优先 `HttpOnly; Secure; SameSite=Lax` cookie + CSRF token；`postMessage` 必须校验 `event.origin`；`target="_blank"` 现代浏览器默认 `noopener`，老浏览器仍要显式写。
- 供应链：lockfile 入库、`npm ci`、pnpm `minimumReleaseAge`（10.16+）；CDN 脚本加 `integrity`（SRI）+ `crossorigin`；生产不上传 sourcemap 到公网（或 `hidden` 模式只传错误平台）；`import.meta.env.VITE_*` 会打进包里，密钥不能放前端 env。
- 依赖里的原型污染与 ReDoS 同样影响浏览器端：合并对象用 `structuredClone`/`Object.hasOwn`，正则避免嵌套量词。

## 可访问性与测试

- 原生元素优先：`<button>` 而不是 `div onClick`（省掉 role/tabIndex/键盘事件三件套）；每个 `<input>` 有 `<label>`；图标按钮 `aria-label`；对话框用 `<dialog>`（自带焦点困住与 Esc）；路由切换后把焦点移到新页面标题；`prefers-reduced-motion` 关闭大动效；文本对比度 ≥ 4.5:1。
- 测试分层：Vitest + Testing Library（`getByRole` 优先，查询本身就是可访问性检查）测行为；Playwright 测关键路径 E2E；MSW 拦网络；`axe-core`（`vitest-axe`/`@axe-core/playwright`）扫 a11y；视觉回归只对设计系统组件做。不测实现细节（state 值、内部函数调用次数）。

## 代码模板：搜索框（真防抖 + AbortController + 竞态保护）

```tsx
import { useEffect, useId, useRef, useState } from 'react';

export interface SearchResult {
  id: string;
  title: string;
}

export interface SearchProps {
  /** 必须把 signal 传给 fetch：否则"取消"只是丢弃结果，请求本身仍占用连接与服务端资源 */
  onSearch: (query: string, signal: AbortSignal) => Promise<SearchResult[]>;
  /** 防抖毫秒，默认 300 */
  debounceMs?: number;
  placeholder?: string;
}

type Status = 'idle' | 'loading' | 'error';

export function Search({ onSearch, debounceMs = 300, placeholder = '搜索…' }: SearchProps) {
  const [query, setQuery] = useState('');
  const [results, setResults] = useState<SearchResult[]>([]);
  const [status, setStatus] = useState<Status>('idle');
  const listId = useId();
  // 父组件常把 onSearch 写成内联箭头函数：放进 effect 依赖会让每次父渲染都重发请求，用 ref 持有最新值
  const onSearchRef = useRef(onSearch);
  useEffect(() => {
    onSearchRef.current = onSearch;
  }, [onSearch]);
  // 递增序号：即使 onSearch 忽略了 signal，过期响应也不会覆盖新结果
  const seq = useRef(0);

  useEffect(() => {
    const q = query.trim();
    if (q === '') {
      // 也要占用一个新序号：否则清空输入后，忽略 signal 的 onSearch 迟到返回时
      // mySeq === seq.current 仍成立，已清空的列表会被旧结果重新填上
      seq.current += 1;
      setResults([]);
      setStatus('idle');
      return;
    }
    const controller = new AbortController();
    const mySeq = ++seq.current;
    const timer = setTimeout(async () => {
      setStatus('loading');
      try {
        const data = await onSearchRef.current(q, controller.signal);
        if (mySeq !== seq.current) return; // 已有更新的请求在途，丢弃
        setResults(data);
        setStatus('idle');
      } catch {
        if (controller.signal.aborted || mySeq !== seq.current) return; // 主动取消不是错误
        setStatus('error');
      }
    }, debounceMs);
    // 清理在 query 再变或组件卸载时执行：取消定时器（防抖本体）与在途请求
    return () => {
      clearTimeout(timer);
      controller.abort();
    };
  }, [query, debounceMs]);

  return (
    <div role="search">
      <input
        type="search"
        value={query}
        onChange={(e) => setQuery(e.target.value)}
        placeholder={placeholder}
        aria-controls={listId}
        aria-busy={status === 'loading'}
      />
      {status === 'error' && <p role="alert">搜索失败，请重试</p>}
      <ul id={listId} aria-live="polite">
        {results.map((r) => (
          <li key={r.id}>{r.title}</li>
        ))}
      </ul>
    </div>
  );
}
```

真实项目里这段逻辑通常交给 TanStack Query：`useQuery({ queryKey: ['search', debouncedQuery], queryFn: ({ signal }) => api(q, signal), placeholderData: keepPreviousData })`，取消与竞态由缓存层处理，组件只管防抖后的 key。

## 选型判断

| 场景 | 选择 | 理由 |
|---|---|---|
| 内容/营销站、SEO 优先、交互少 | Astro（岛屿）或 Next/Nuxt SSG | 默认零 JS，CWV 最容易达标 |
| 登录后使用的复杂业务后台 | Vite SPA + React Router/TanStack Router | 不需要 SSR 复杂度，构建部署最简单 |
| SEO + 大量交互 + 团队能运维 Node | Next.js（App Router/RSC）或 Nuxt 4 | 服务端组件减小客户端包，代价是两套心智与服务端运维 |
| 已有 Vue 团队 | Vue 3.5 + Nuxt 4 / Vite | 团队熟悉度胜过框架间的微小差异 |
| 跨框架复用的组件库 | Web Components（Lit）或按框架各发一版 | WC 的 SSR/表单参与/样式隔离仍有代价 |
| 样式 | Tailwind 4 或 CSS Modules；RSC 项目不用运行时 CSS-in-JS | 零运行时、与服务端组件兼容 |
| 数据层 | TanStack Query（客户端拉取）/ RSC + Server Actions（Next） | 缓存失效与去重不要自己写 |
| 何时不该用 RSC | 纯客户端应用、无 Node 服务端、团队不熟 | 只有 SPA 需求时 RSC 是纯成本 |
| 何时不该用微前端 | 单团队、单发布节奏 | 微前端解决的是组织问题，不是技术问题 |

## 审查清单

- [ ] 首屏 LCP 元素无 `loading="lazy"`，有 `fetchpriority="high"`；图片/媒体有尺寸或 `aspect-ratio`
- [ ] 输入处理器内无重计算；长任务已拆分或走 `useTransition`/worker
- [ ] 没有在渲染期读写 `ref.current`、改 props/state（编译器与 StrictMode 都会暴露）
- [ ] `use()` 的 Promise 已缓存；`useFormStatus` 在 form 子组件中
- [ ] 异步 effect 有清理：`AbortController`、清定时器、竞态保护
- [ ] Server → Client props 可序列化；Server Action 内有鉴权与校验
- [ ] 渲染里没有 `Date.now()`/随机数/仅浏览器 API；HTML 嵌套合法
- [ ] 无 `dangerouslySetInnerHTML`/`v-html` 直出用户内容；`href` 校验 scheme；有 CSP nonce 方案
- [ ] Token 不在 `localStorage`；`postMessage` 校验 origin；前端 env 无密钥
- [ ] 可交互元素是原生 `<button>`/`<a>`，有 label；对话框焦点管理；`prefers-reduced-motion`
- [ ] 无 barrel file 全量导入；路由级代码分割；包体在预算内
- [ ] browserslist 为 Baseline 查询；新 CSS 特性有 `@supports` 回退
- [ ] 测试用 `getByRole` 查询，不断言实现细节

## 与其他 skill 的配合

| 领域 | 对应 skill | 何时参考 |
|---|---|---|
| Node 服务端（BFF、API、SSR 服务器进程、发包） | senior-nodejs-engineer | 优雅关闭、流、ESM/CJS、服务端安全 |
| 部署、CDN、Nginx、HTTP 缓存头 | senior-devops-engineer | 静态资源缓存策略、TLS、边缘配置 |
