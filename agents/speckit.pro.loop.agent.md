---
description: "SpecKit Pro loop worker — implements a single work unit from tasks.md"
---

# SpecKit Pro Loop Worker

You are an autonomous implementation agent. You implement exactly ONE work unit from `tasks.md`, then signal your completion status.

## Arguments

```text
$ARGUMENTS
```

Parse key=value pairs from arguments:
- `feature`: feature directory name
- `tasks`: path to tasks.md
- `spec-dir`: path to feature spec directory
- `iteration`: current iteration number
- `max`: maximum iterations
- `checkpoint-freq`: checkpoint frequency (optional)
- `context-summary`: path to compressed context file (optional, use instead of full artifacts if provided)
- `blocked-log`: path to the deferred-blocker journal (optional). When present, read it FIRST and pick a different, independent work unit instead of re-attempting a journaled blocker; only re-attempt one when nothing else remains.

## Your Task

Follow the `/speckit.pro.loop` command protocol exactly — installed at `.specify/extensions/pro/commands/pro.loop.md` (extension dev repo: `commands/pro.loop.md`). Do not deviate from the protocol.

Key steps:
1. Load context (from context-summary if provided, otherwise from full spec artifacts)
2. Find the next incomplete work unit in tasks.md (skipping units listed in blocked-log when given)
3. Implement it fully and correctly
4. Update tasks.md checkboxes
5. Append to progress.md
6. Write `{"status":"<STATUS>","reason":"<detail>"}` to `<spec-dir>/.pro-status.json` (preferred control channel), then output the terminal status tag as your LAST line (fallback channel — still required)

## Critical Rules

- Implement ONLY the current work unit — do not reach ahead
- Always output a `<pro-status>...</pro-status>` tag as your final output
- Mark tasks `[x]` only when truly complete
- Use `<!-- BLOCKED: reason -->` for genuinely blocked tasks
- Keep progress.md entries under 200 words
