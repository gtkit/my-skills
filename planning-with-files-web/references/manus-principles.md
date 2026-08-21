# Manus Context Engineering Principles

Reference document for the context engineering principles behind this skill.

## The 6 Manus Principles

### Principle 1: Filesystem as External Memory

> "Markdown is my 'working memory' on disk."

Context Window = RAM (volatile, limited). Filesystem = Disk (persistent, unlimited).
Store important information in files, not in the context window. Compression must be restorable — keep URLs even if content is dropped, keep file paths when dropping document contents.

### Principle 2: Manipulate Attention Through Recitation

After ~50 tool calls, models forget original goals ("lost in the middle" effect). Re-reading `task_plan.md` before each decision pushes goals into the model's recent attention span, where they get the most weight.

### Principle 3: Keep the Wrong Stuff In

> "Leave the wrong turns in the context."

Failed actions with stack traces let the model implicitly update beliefs. This reduces mistake repetition. Error recovery is "one of the clearest signals of TRUE agentic behavior."

### Principle 4: Don't Get Few-Shotted

Repetitive action-observation pairs cause drift and hallucination. Introduce controlled variation — vary phrasings slightly, don't copy-paste patterns blindly, recalibrate on repetitive tasks.

### Principle 5: Design Around KV-Cache

Keep prompt prefixes stable. No timestamps in system prompts. Make context append-only with deterministic serialization. Cached tokens are 10x cheaper than uncached tokens.

### Principle 6: Mask, Don't Remove

Don't dynamically remove tools (breaks cache). Use consistent action prefixes for easier masking.

## The 3 Context Engineering Strategies

### Strategy 1: Context Reduction
- Apply compaction to stale (older) tool results
- Keep recent results full (to guide next decision)
- Use summarization when compaction reaches diminishing returns

### Strategy 2: Context Isolation (Multi-Agent)
- Planner agent assigns tasks to sub-agents
- Knowledge manager reviews conversations and stores to filesystem
- Executor sub-agents perform work with their own context windows

### Strategy 3: Context Offloading
- Use <20 atomic functions total
- Store full results in filesystem, not context
- Progressive disclosure: load information only as needed

## The Agent Loop

1. ANALYZE CONTEXT — Understand intent, assess state, review observations
2. THINK — Should I update the plan? What's next? Any blockers?
3. SELECT TOOL — Choose ONE tool, ensure parameters available
4. EXECUTE ACTION — Tool runs in sandbox
5. RECEIVE OBSERVATION — Result appended to context
6. ITERATE — Return to step 1
7. DELIVER OUTCOME — Send results to user with all files

## Critical Constraints

- Plan is Required: Agent must ALWAYS know goal, current phase, remaining phases
- Files are Memory: Context = volatile, Filesystem = persistent
- Never Repeat Failures: If action failed, next action MUST be different
- The 2-Action Rule: Save findings after every 2 search/view operations

## Source

Based on Manus's context engineering documentation:
https://manus.im/blog/Context-Engineering-for-AI-Agents-Lessons-from-Building-Manus
