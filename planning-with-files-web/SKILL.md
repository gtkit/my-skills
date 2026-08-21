---
name: planning-with-files-web
description: Manus-style file-based planning for complex tasks in Claude.ai web environment. Creates task_plan.md, findings.md, and progress.md as persistent working memory. Use when asked to plan, break down, or organize any multi-step project, research task, coding project, document creation, or work requiring more than 5 tool calls. Also trigger when user says "plan this", "help me organize", "break this down", "track progress", or starts a complex build/research task. This skill ensures Claude doesn't lose track of goals, findings, or errors across long conversations.
---

# Planning with Files (Web Edition)

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

Before ANY complex task, run the initialization script:

```bash
bash /mnt/skills/user/planning-with-files-web/scripts/init-session.sh
```

This creates the three planning files in `/home/claude/`. Then:

1. **Fill in `task_plan.md`** with the task goal, phases, and key questions
2. **Work through phases**, updating files as you go
3. **Re-read the plan before major decisions** to keep goals in attention
4. **Log all errors and findings** to prevent repetition and information loss
5. **Verify completion** before delivering to the user

## The 3-File Pattern

For every complex task, maintain THREE files in `/home/claude/`:

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
cat /mnt/skills/user/planning-with-files-web/templates/task_plan.md
```

## Critical Rules

### Rule 1: Create Plan First (Non-Negotiable)

Never start a complex task without creating `task_plan.md`. This is your roadmap.

```bash
# Step 1: Initialize files
bash /mnt/skills/user/planning-with-files-web/scripts/init-session.sh

# Step 2: Fill in the goal and phases
str_replace task_plan.md "[One sentence describing the end state]" "Build a REST API with user auth and CRUD operations"
```

### Rule 2: The 2-Action Rule

> After every 2 view/browser/search operations, IMMEDIATELY save key findings to `findings.md`.

This prevents visual/multimodal information from being lost. Web search results, image content, and browser data are volatile — write them down before they disappear from attention.

### Rule 3: Read Before Decide

Before major decisions, re-read the plan file. This exploits the "attention manipulation" principle — recently read content gets more attention from the model.

```bash
# Re-read plan before a critical decision
cat /home/claude/task_plan.md
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
bash /mnt/skills/user/planning-with-files-web/scripts/check-status.sh
```

## Web Environment Adaptations

Unlike Claude Code, the web environment has some differences:

1. **No hooks** — You must manually re-read plans and update files (Claude Code has PreToolUse/PostToolUse hooks that do this automatically)
2. **Working directory** — Use `/home/claude/` for planning files, `/mnt/user-data/outputs/` for deliverables
3. **File delivery** — Use `present_files` tool to share final outputs with the user
4. **Session persistence** — Files persist within a session but reset between tasks. For multi-session work, deliver planning files to the user via outputs

### Delivering Planning Files Between Sessions

If the user needs to continue work in a future session, copy planning files to outputs:
```bash
cp /home/claude/task_plan.md /home/claude/findings.md /home/claude/progress.md /mnt/user-data/outputs/
```

The user can then upload these files in the next session to resume.

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
cat /mnt/skills/user/planning-with-files-web/references/manus-principles.md
```

## Scripts

- `scripts/init-session.sh` — Initialize all three planning files
- `scripts/check-status.sh` — Show current progress at a glance
- `scripts/check-complete.sh` — Verify all phases are complete before delivery
