# Polyglot Engineering SOP Skills Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 新增 11 个跨栈工程 SOP skill，并更新仓库索引和路由校验。

**Architecture:** 每个 skill 是独立目录，入口 `SKILL.md` 只保留触发、核心流程、证据和边界；不新增项目专属脚本。README 说明组合方式，catalog.yaml 记录元数据，evals/routing.md 记录静态场景。

**Tech Stack:** Markdown、YAML、PowerShell 验证脚本。

---

### Task 1: Create P0 skill documents

**Files:**
- Create: `cross-stack-api-contract/SKILL.md`
- Create: `polyglot-release-engineering/SKILL.md`
- Create: `php-enterprise-quality/SKILL.md`
- Create: `incident-response/SKILL.md`

- [ ] Each document has valid frontmatter, a discriminating trigger, workflow, evidence requirements, completion criteria, and non-trigger boundaries.
- [ ] Keep each document under 400 lines and avoid duplicating existing skill bodies.

### Task 2: Create P1 skill documents

**Files:**
- Create: `cross-stack-observability/SKILL.md`
- Create: `openresty-gateway-operations/SKILL.md`
- Create: `polyglot-security-supply-chain/SKILL.md`
- Create: `polyglot-test-engineering/SKILL.md`

- [ ] Include routing to existing Go/PHP/frontend/OpenResty skills where implementation detail belongs elsewhere.
- [ ] Include negative boundaries for ordinary coding, framework-specific implementation, and release acceptance.

### Task 3: Create P2 skill documents

**Files:**
- Create: `runtime-upgrade-migration/SKILL.md`
- Create: `fullstack-performance/SKILL.md`
- Create: `async-job-contracts/SKILL.md`

- [ ] Make upgrade, performance, and async message behavior evidence-driven and explicitly mark assumptions.

### Task 4: Update repository indexes and routes

**Files:**
- Modify: `README.md`
- Modify: `catalog.yaml`
- Modify: `evals/routing.md`

- [ ] Add all 11 skills to the appropriate README groups and composition rules.
- [ ] Add active catalog entries with platforms, references, templates, and scripts.
- [ ] Add positive, negative, and cross-boundary routing scenarios.

### Task 5: Validate and reconcile

**Files:**
- Modify: `task_plan.md`
- Modify: `findings.md`
- Modify: `progress.md`

- [ ] Run `pwsh -File scripts/validate.ps1`.
- [ ] Run static checks for missing references, description length, line count, and catalog coverage.
- [ ] Confirm planning files are excluded and `git status --porcelain` contains only intended repository changes.
- [ ] Record real-runtime limitations; do not claim model trigger improvements.
