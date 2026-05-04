---
description: 'Autonomous implementation loop — single iteration worker: reads tasks.md,
  implements one work unit, checkpoints, and signals completion status'
---


<!-- Extension: pro -->
<!-- Config: .specify/extensions/pro/ -->
# SpecKit Pro — Autonomous Loop Worker

This command executes a **single iteration** of the autonomous implementation loop. It is invoked repeatedly by the `pro-orchestrate.sh` / `pro-orchestrate.ps1` orchestrator script.

Each iteration:
1. Reads `tasks.md` to find the next incomplete work unit (phase/user-story group)
2. Implements all tasks within that work unit
3. Updates `tasks.md` checkbox state
4. Appends a progress entry to `progress.md`
5. Creates a git checkpoint commit
6. Signals completion status via a terminal tag

## User Input

```text
$ARGUMENTS
```

Parse the following from `$ARGUMENTS` (space-separated key=value pairs):

| Argument | Required | Description |
|---|---|---|
| `feature` | yes | Feature directory name (e.g., `001-my-feature`) |
| `tasks` | yes | Absolute path to `tasks.md` |
| `spec-dir` | yes | Absolute path to feature spec directory |
| `iteration` | yes | Current iteration number (1-based) |
| `max` | yes | Maximum iterations allowed |
| `checkpoint-freq` | no | Commit every N iterations (default: 3) |

## Pre-Iteration Setup

1. **Load context files** — read these in order (they provide the agent's working memory):
   - `<spec-dir>/spec.md` — requirements and user stories
   - `<spec-dir>/plan.md` — technical architecture
   - `<spec-dir>/tasks.md` — task checklist with completion state
   - `<spec-dir>/progress.md` — history of previous iterations (if exists)
   - `<spec-dir>/session.md` — session state (if exists)

2. **Parse task state** — scan `tasks.md` for:
   - Total task count: lines matching `- [ ]` or `- [x]` or `- [X]`
   - Completed count: lines matching `- [x]` or `- [X]`
   - Incomplete count: remaining unchecked items
   - Next work unit: first incomplete phase/section heading with tasks under it

3. **Early termination checks**:
   - If `incomplete_count == 0`: output `<pro-status>COMPLETE</pro-status>` and stop
   - If `iteration > max`: output `<pro-status>MAX_ITERATIONS</pro-status>` and stop

## Work Unit Detection

A "work unit" is defined as one of:
- A Phase section (e.g., `## Phase 3: User Authentication`) with its tasks
- If no phases exist: a logical group of ≤5 consecutive incomplete tasks

**Rules**:
- Never cross phase boundaries in a single iteration
- If a phase has parallel tasks marked `[P]`, implement them conceptually in parallel (same iteration)
- Skip fully-completed phases

## Implementation

For each task in the selected work unit:

1. Read the task description carefully
2. Implement the code/changes described
3. Verify the implementation is correct and follows the plan
4. Mark the task complete in `tasks.md` by changing `- [ ]` to `- [x]`

**Quality checks during implementation**:
- Does the implementation match `spec.md` user story requirements?
- Does it follow the tech stack from `plan.md`?
- Are there any obvious bugs or security issues?

If you encounter a blocker (cannot implement a task):
- Leave the task as `- [ ]` with a note `<!-- BLOCKED: <reason> -->`
- Log the blocker in `progress.md`
- Output `<pro-status>BLOCKED:<task description></pro-status>` after completing other tasks

## Progress Tracking

After implementing the work unit, append to `<spec-dir>/progress.md`:

```markdown
## Iteration <N> — <ISO timestamp>

**Work Unit**: <phase/section name>
**Tasks completed this iteration**: <count>
**Cumulative progress**: <completed>/<total> tasks (<percentage>%)
**Files modified**: <list of files changed>

### Summary
<2-3 sentence summary of what was implemented>

### Decisions made
<any architectural or implementation decisions made>

### Issues encountered
<any problems, workarounds, or deferred items>

---
```

If `progress.md` does not exist, create it with this header first:

```markdown
# Implementation Progress Log

Feature: <feature name>
Started: <ISO timestamp>

---
```

## Checkpoint Commit

If `iteration % checkpoint_frequency == 0` OR all tasks are complete:

1. Stage all changes: `git add .`
2. Commit: `git commit -m "[Pro] Checkpoint: iteration <N> — <work unit name> (<completed>/<total> tasks)"`
3. Log commit hash in `progress.md`

If git is not available, skip with a warning.

## Completion Signals

Output **exactly one** of these terminal tags as the last line of output:

| Tag | Meaning |
|---|---|
| `<pro-status>COMPLETE</pro-status>` | All tasks done — terminate loop successfully |
| `<pro-status>CONTINUE</pro-status>` | Work unit done — more tasks remain, continue loop |
| `<pro-status>BLOCKED:<reason></pro-status>` | Stuck on a task — orchestrator decides whether to retry |
| `<pro-status>ERROR:<message></pro-status>` | Unexpected error — orchestrator applies circuit breaker |
| `<pro-status>MAX_ITERATIONS</pro-status>` | Safety limit reached — terminate loop |

## Context Efficiency Guidelines

To maintain effectiveness across many iterations:
- Focus only on the current work unit — do not re-read or re-implement previous phases
- Keep `progress.md` entries concise (< 200 words per iteration)
- Reference `spec.md` and `plan.md` for intent, not line-by-line
- If context feels saturated, note it in progress.md with `<!-- Context: HIGH -->`