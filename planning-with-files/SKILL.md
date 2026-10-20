---
name: planning-with-files
description: "Use for multi-step planning needing more than 5 tool calls; keep task_plan.md, findings.md, and progress.md on disk."
user-invocable: true
allowed-tools: "Read, Write, Edit, Bash, Glob, Grep, WebFetch, WebSearch"
hooks:
  PostToolUse:
    - matcher: "Write|Edit"
      hooks:
        - type: command
          command: "echo '[planning-with-files] File updated. If this completes a phase, update task_plan.md status.'"
metadata:
  version: "2.16.1"
---

# Planning with Files

## 前置必读：拒绝猜测与改动边界

- 每次使用本 skill、恢复任务及执行任何改动前，先实际读取本节、当前运行环境已配置的全局规则，以及目标项目已有的协作规则和错误记录。按已明确的配置入口定位，不猜路径、不硬编码本机目录，不以记忆或摘要替代；必需规则无法读取时停止改动并说明。
- 需求、接口、字段、权限、默认值、路径、工具能力、依赖与兼容结论必须有用户指令、已读取源码/配置、已核实官方资料或真实执行证据。未知保持未确认，先核实；仍不明确就停止依赖该信息的步骤，不凭猜测补全，不重复询问已经明确的要求。
- 修改代码前先完成并落盘方案和逐步计划，写清范围、文件、兼容约束、风险、回滚和验收；只执行获准范围及阶段。计划、候选原因和未执行步骤标为待验证，不能当作事实或已完成结果。
- 只有真实执行并回读后才能报告完成或通过，区分失败、未执行、未验证和不适用；模拟与静态证据不冒充真实链路。纯文档、注释、规则或 skill 说明任务只编辑指定内容并回读，不因本 skill 的流程扩展为测试、构建、同步、打包或 OpenSpec 操作。

Work like Manus: Use persistent markdown files as your "working memory on disk."

## Important: Where Files Go

- **Templates** are in `templates/` inside this skill directory.
- **Your planning files** go in **your project directory**.

| Location | What Goes There |
|----------|-----------------|
| Skill directory | Templates |
| Your project directory | `task_plan.md`, `findings.md`, `progress.md` |

### Keep planning files out of version control (mandatory)

Planning files are working artifacts, never repository content. When the project directory is a git repository, run this **before** creating the three files:

```bash
if git rev-parse --git-dir >/dev/null 2>&1; then
  ex="$(git rev-parse --git-dir)/info/exclude"
  for f in task_plan.md findings.md progress.md; do
    grep -qxF "$f" "$ex" 2>/dev/null || echo "$f" >> "$ex"
  done
fi
```

- The rule goes only into the local, untracked `.git/info/exclude` — **never into the tracked `.gitignore`** (a tracked ignore rule would itself leak the tooling into the repository).
- If any of the three files is already tracked, stop and report it. Removing a tracked file from the index requires explicit authorization; do not run `git rm --cached` as an automatic planning step.
- Before finishing a task, confirm with `git status --porcelain` that none of the three files shows up as untracked or modified.

## Quick Start

Before ANY complex task:

1. **Create `task_plan.md`** — Use [templates/task_plan.md](templates/task_plan.md) as reference
2. **Create `findings.md`** — Use [templates/findings.md](templates/findings.md) as reference
3. **Create `progress.md`** — Use [templates/progress.md](templates/progress.md) as reference
4. **Re-read plan before decisions** — Refreshes goals in attention window
5. **Update after each phase** — Mark complete, log errors

> **Note:** Planning files go in your project root, not the skill installation folder.

## The Core Pattern

```
Context Window = RAM (volatile, limited)
Filesystem = Disk (persistent, unlimited)

→ Anything important gets written to disk.
```

## File Purposes

| File | Purpose | When to Update |
|------|---------|----------------|
| `task_plan.md` | Phases, progress, decisions | After each phase |
| `findings.md` | Research, discoveries | After ANY discovery |
| `progress.md` | Session log, test results | Throughout session |

## Resuming after a gap or `/clear`

Planning files are the recovery mechanism. When resuming:

1. Read all three planning files.
2. Run `git diff --stat` to see what actually changed on disk since the plan was last updated.
3. Reconcile the two — the files record intent, the diff records reality — and update the planning files before continuing.

## Critical Rules

### 1. Create Plan First
Never start a complex task without `task_plan.md`. Non-negotiable.

### 2. The 2-Action Rule
> "After every 2 view/browser/search operations, IMMEDIATELY save key findings to text files."

This prevents visual/multimodal information from being lost.

### 3. Read Before Decide
Before major decisions, read the plan file. This keeps goals in your attention window.

### 4. Update After Act
After completing any phase:
- Mark phase status: `in_progress` → `complete`
- Log any errors encountered
- Note files created/modified

### 5. Log ALL Errors
Every error goes in the plan file. This builds knowledge and prevents repetition.

```markdown
## Errors Encountered
| Error | Attempt | Resolution |
|-------|---------|------------|
| FileNotFoundError | 1 | Created default config |
| API timeout | 2 | Added retry logic |
```

### 6. Never Repeat Failures
```
if action_failed:
    next_action != same_action
```
Track what you tried. Mutate the approach.

## The 3-Strike Error Protocol

```
ATTEMPT 1: Diagnose & Fix
  → Read error carefully
  → Identify root cause
  → Apply targeted fix

ATTEMPT 2: Alternative Approach
  → Same error? Try different method
  → Different tool? Different library?
  → NEVER repeat exact same failing action

ATTEMPT 3: Broader Rethink
  → Question assumptions
  → Search for solutions
  → Consider updating the plan

AFTER 3 FAILURES: Escalate to User
  → Explain what you tried
  → Share the specific error
  → Ask for guidance
```

## Read vs Write Decision Matrix

| Situation | Action | Reason |
|-----------|--------|--------|
| Just wrote a file | DON'T read | Content still in context |
| Viewed image/PDF | Write findings NOW | Multimodal → text before lost |
| Browser returned data | Write to file | Screenshots don't persist |
| Starting new phase | Read plan/findings | Re-orient if context stale |
| Error occurred | Read relevant file | Need current state to fix |
| Resuming after gap | Read all planning files | Recover state |

## The 5-Question Reboot Test

If you can answer these, your context management is solid:

| Question | Answer Source |
|----------|---------------|
| Where am I? | Current phase in task_plan.md |
| Where am I going? | Remaining phases |
| What's the goal? | Goal statement in plan |
| What have I learned? | findings.md |
| What have I done? | progress.md |

## When to Use This Pattern

**Use for:**
- Multi-step tasks (3+ steps)
- Research tasks
- Building/creating projects
- Tasks spanning many tool calls
- Anything requiring organization

**Skip for:**
- Simple questions
- Single-file edits
- Quick lookups

## Anti-Patterns

| Don't | Do Instead |
|-------|------------|
| Use TodoWrite for persistence | Create task_plan.md file |
| State goals once and forget | Re-read plan before decisions |
| Hide errors and retry silently | Log errors to plan file |
| Stuff everything in context | Store large content in files |
| Start executing immediately | Create plan file FIRST |
| Repeat failed actions | Track attempts, mutate approach |
| Create files in skill directory | Create files in your project |
