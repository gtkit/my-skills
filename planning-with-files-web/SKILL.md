---
name: planning-with-files-web
description: "Use for multi-step planning in Claude.ai Web; keep task_plan.md, findings.md, and progress.md as persistent memory."
---

# Planning with Files (Web Edition)

## 前置必读：拒绝猜测与改动边界

- 每次使用本 skill、恢复任务及执行任何改动前，先实际读取本节、当前运行环境已配置的全局规则，以及目标项目已有的协作规则和错误记录。按已明确的配置入口定位，不猜路径、不硬编码本机目录，不以记忆或摘要替代；必需规则无法读取时停止改动并说明。
- 需求、接口、字段、权限、默认值、路径、工具能力、依赖与兼容结论必须有用户指令、已读取源码/配置、已核实官方资料或真实执行证据。未知保持未确认，先核实；仍不明确就停止依赖该信息的步骤，不凭猜测补全，不重复询问已经明确的要求。
- 修改代码前先完成并落盘方案和逐步计划，写清范围、文件、兼容约束、风险、回滚和验收；只执行获准范围及阶段。计划、候选原因和未执行步骤标为待验证，不能当作事实或已完成结果。
- 只有真实执行并回读后才能报告完成或通过，区分失败、未执行、未验证和不适用；模拟与静态证据不冒充真实链路。纯文档、注释、规则或 skill 说明任务只编辑指定内容并回读，不因本 skill 的流程扩展为测试、构建、同步、打包或 OpenSpec 操作。

Manus-style persistent markdown planning adapted for Claude.ai's web/computer-use environment. Use the filesystem as external memory to overcome context window limitations.

## Core Principle

```
Context Window = RAM (volatile, limited)
Filesystem = Disk (persistent, unlimited)

→ Anything important gets written to disk.
```

In Claude.ai, Claude has access to a Linux computer with bash, file creation, and editing tools. This skill leverages that filesystem as persistent working memory — the same pattern that made Manus worth $2B.

## When to Use This Skill

**Use for:**
- Multi-step tasks (3+ steps)
- Research tasks requiring web search and synthesis
- Building/creating projects (code, documents, presentations)
- Tasks spanning many tool calls (>5)
- Any task where losing track of progress would be costly
- Complex document creation (reports, analyses)
- Multi-file code projects

**Skip for:**
- Simple questions or lookups
- Single-file edits
- Quick conversational responses
- Tasks completable in 1-2 tool calls

## Quick Start Workflow

Before an authorized complex task, use the actual environment and skill metadata to locate the skill directory, a writable planning directory, and any deliverable directory. In the examples below, `skill_dir`, `plan_dir`, and `output_dir` must already contain those verified paths; do not infer a fixed installation or home directory.

Read the templates and create only the authorized planning files, preserving any existing content:

```bash
cat "$skill_dir/templates/task_plan.md"
```

The bundled initialization and status scripts currently use a fixed working directory internally. Read their actual contents before considering execution; run them only when that destination is verified and authorized. Otherwise use the available file tools and templates. These scripts are not made configurable merely by setting the example variables. Then:

1. **Fill in `task_plan.md`** with the task goal, phases, and key questions
2. **Work through phases**, updating files as you go
3. **Re-read the plan before major decisions** to keep goals in attention
4. **Log all errors and findings** to prevent repetition and information loss
5. **Verify completion** before delivering to the user

## The 3-File Pattern

For an authorized complex task that needs these files, maintain THREE files in the verified `plan_dir`:

| File | Purpose | When to Update |
|------|---------|----------------|
| `task_plan.md` | Phases, progress, decisions, errors | After each phase completes |
| `findings.md` | Research discoveries, requirements, resources | After ANY discovery (2-Action Rule) |
| `progress.md` | Session log, test results, error details | Throughout session |

### File Templates

Templates are available at:
- `templates/task_plan.md` — Phase tracking with checkboxes
- `templates/findings.md` — Research and knowledge storage  
- `templates/progress.md` — Session logging and test results

Read these templates when creating new planning files:
```bash
cat "$skill_dir/templates/task_plan.md"
```

## Critical Rules

### Rule 1: Create Plan First (Non-Negotiable)

Never start a complex task without creating `task_plan.md`. This is your roadmap.

```bash
# Read the template from the verified skill directory.
cat "$skill_dir/templates/task_plan.md"

# Use the available file-editing tool to create or update the authorized
# task_plan.md in plan_dir, then write the actual goal and approved phases.
```

### Rule 2: The 2-Action Rule

> After every 2 view/browser/search operations, IMMEDIATELY save key findings to `findings.md`.

This prevents visual/multimodal information from being lost. Web search results, image content, and browser data are volatile — write them down before they disappear from attention.

### Rule 3: Read Before Decide

Before major decisions, re-read the plan file. This exploits the "attention manipulation" principle — recently read content gets more attention from the model.

```bash
# Re-read plan before a critical decision
cat "$plan_dir/task_plan.md"
```

### Rule 4: Update After Act

After completing any phase:
- Mark phase status: `pending` → `in_progress` → `complete`
- Log any errors encountered
- Note files created/modified
- Update progress.md with actions taken

### Rule 5: Log ALL Errors

Every error goes in both `task_plan.md` (summary) and `progress.md` (details). This builds knowledge and prevents repeating the same mistakes.

### Rule 6: Never Repeat Failures

```
if action_failed:
    next_action != same_action
```

Track what you tried. Mutate the approach. Follow the 3-Strike Protocol.

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
| Just wrote a file | DON'T read it back | Content still in context |
| Did web search | Write findings NOW | Search results don't persist well |
| Viewed image/PDF | Write findings NOW | Multimodal → text before lost |
| Starting new phase | Read plan + findings | Re-orient goals in attention |
| Error occurred | Read relevant file | Need current state to fix |
| Many tool calls done | Read plan | Prevent goal drift |

## The 5-Question Reboot Test

If you can answer all five, your context management is solid:

| Question | Answer Source |
|----------|---------------|
| Where am I? | Current phase in task_plan.md |
| Where am I going? | Remaining phases |
| What's the goal? | Goal statement in plan |
| What have I learned? | findings.md |
| What have I done? | progress.md |

Periodically run this check, especially after many tool calls:
```bash
cat "$plan_dir/task_plan.md"
```

## Web Environment Adaptations

Unlike Claude Code, the web environment has some differences:

1. **Hooks** — Verify the actual environment capabilities; when no applicable hooks are available, re-read plans and update authorized files manually.
2. **Working directory** — Resolve writable planning and deliverable directories from the actual environment and authorization; do not hardcode machine paths.
3. **File delivery** — Use the file-delivery tool or artifact links actually available in the current environment; do not assume a tool name or API.
4. **Session persistence** — Verify the actual storage lifetime. For multi-session work, deliver the authorized planning files through the verified output location.

### Delivering Planning Files Between Sessions

If the user needs to continue work in a future session, copy planning files to outputs:
```bash
cp "$plan_dir/task_plan.md" "$plan_dir/findings.md" "$plan_dir/progress.md" "$output_dir/"
```

The user can then upload these files in the next session to resume.

### Never let planning files enter a repository

Choose a verified planning location outside a project checkout unless the user requests the plan in the project. If a task requires writing them inside a git working tree (for example, the user asks for the plan next to the code), add them to the local, untracked exclude list first — never to the tracked `.gitignore`:

```bash
ex="$(git rev-parse --git-dir)/info/exclude"
for f in task_plan.md findings.md progress.md; do
  grep -qxF "$f" "$ex" 2>/dev/null || echo "$f" >> "$ex"
done
```

Confirm with `git status --porcelain` before delivering that none of the three files is untracked or modified.

## Anti-Patterns

| Don't | Do Instead |
|-------|------------|
| Start executing immediately | Create plan file FIRST |
| State goals once and forget | Re-read plan before decisions |
| Hide errors and retry silently | Log errors to plan file |
| Stuff everything in context | Store large content in files |
| Repeat failed actions | Track attempts, mutate approach |
| Forget to update progress | Update after each phase |
| Skip findings for web searches | Apply 2-Action Rule strictly |

## Advanced: Manus Principles Reference

For deeper understanding of the context engineering principles behind this skill, read:
```bash
cat "$skill_dir/references/manus-principles.md"
```

## Scripts

- `scripts/init-session.sh` — Initialize all three planning files
- `scripts/check-status.sh` — Show current progress at a glance
- `scripts/check-complete.sh` — Verify all phases are complete before delivery
