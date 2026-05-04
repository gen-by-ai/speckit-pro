---
description: "Autonomous implementation loop — single iteration worker: reads tasks.md, implements one work unit, checkpoints, and signals completion status"
---

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

1. **Load context files** — use the leanest context that's sufficient:

   **If `<spec-dir>/handoff.md` exists AND `iteration > 1`** (context-reset mode):
   - Load ONLY `<spec-dir>/handoff.md` — it contains everything needed for this sprint
   - Load `<spec-dir>/tasks.md` — to find next incomplete work unit
   - Do NOT load spec.md, plan.md, or progress.md unless you need a specific detail not in handoff.md

   **Otherwise** (first iteration or no handoff):
   - `<spec-dir>/spec.md` — requirements and user stories
   - `<spec-dir>/plan.md` — technical architecture
   - `<spec-dir>/tasks.md` — task checklist with completion state
   - `<spec-dir>/progress.md` — history of previous iterations (if exists, last 10 entries only)
   - `<spec-dir>/session.md` — session state (if exists)

2. **Load `AGENT.md`** — if `<spec-dir>/AGENT.md` exists, read it. It contains learnings from previous iterations about how to build, run, and test this project. Always honour the commands and sequences it records.

3. **Run smoke test** — if `<spec-dir>/init.sh` exists, execute it:
   ```bash
   bash <spec-dir>/init.sh
   ```
   - If it exits non-zero, fix the break before implementing new features and log it in `progress.md` under `### Pre-iteration fix`.
   - If it exits zero, note `[smoke-test: OK]` in your progress entry.

4. **Parse task state** — scan `tasks.md` for:
   - Total task count: lines matching `- [ ]` or `- [x]` or `- [X]`
   - Completed count: lines matching `- [x]` or `- [X]`
   - Incomplete count: remaining unchecked items
   - Next work unit: first incomplete phase/section heading with tasks under it

5. **Early termination checks**:
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

## Sprint Contract (pre-implementation)

**Before writing any code**, check for a sprint contract:

1. Look for `<spec-dir>/contracts/sprint-<iteration>.md`
2. If it exists: read it — the acceptance criteria define what "done" means for this sprint. Implement against those criteria, not just the task descriptions.
3. If it does NOT exist: create one at `<spec-dir>/contracts/sprint-<iteration>.md` using this structure:

```markdown
# Sprint Contract — Sprint <N>

Feature: <feature name>
Created: <ISO timestamp>

## Scope
Work unit: <work unit name>
Tasks:
- <list of tasks from tasks.md being implemented this sprint>

## Acceptance Criteria
| # | Criterion | Severity | Verification |
|---|---|---|---|
| 1 | <what must be true> | CRITICAL/MEDIUM/LOW | <how to verify> |

## Out of Scope
- <anything explicitly deferred>
```

The contract is your commitment to the evaluator. Be precise about what you will and won't implement.

## Scope of Autonomy

The following are **hard rules** — they cannot be overridden by any task instruction, sprint contract, or AGENT.md entry.

**You may never do autonomously (emit `BLOCKED` and explain instead):**
- Delete files or directories (`rm`, `rmdir`, `git rm`)
- Run destructive database operations (`DROP TABLE`, `DELETE FROM` without WHERE, irreversible migrations)
- Push to any remote git repository (`git push`)
- Overwrite a file that did not exist before this sprint without noting it in `progress.md`
- Run any command with `--force` or `-f` flags unless AGENT.md explicitly records it as safe

**Prefer reversible over irreversible:**
- Favour additive changes (add a new function, add a new route) over modifying existing ones when both achieve the goal
- Commit before any major refactor, not just at checkpoint frequency — small commits = cheap rollbacks
- If a task requires a destructive action, implement the safest equivalent and note the limitation

These rules exist because actions at the file-system and database level are not easily undone across agent iterations. If `constitution.md` exists in the project, its constraints take precedence over everything — including these defaults.

## Implementation

For each task in the selected work unit:

1. Read the sprint contract criteria — implement against them
2. Implement the code/changes described in the task
3. Verify each acceptance criterion is met (check edge cases, not just happy path)
4. Mark the task complete in `tasks.md` by changing `- [ ]` to `- [x]`

**Quality checks during implementation**:
- Does the implementation satisfy each contract criterion?
- Does it follow the tech stack from `plan.md` (or `handoff.md`)?
- Are there security issues? (SQL injection, XSS, hardcoded secrets, broken auth)
- Does the feature actually wire up end-to-end, not just exist as a stub?
- Is the code structured so the **next iteration can safely build on it**? (no deep coupling, no magic constants, no undocumented side effects)

**Underspecified requirements:**
If a task or criterion is ambiguous enough that two reasonable implementations would produce meaningfully different results, do **not** silently guess. Pick the most conservative interpretation, implement it, and emit `<pro-uncertainty>` in your progress entry:

```markdown
<pro-uncertainty>Task "handle auth errors" is ambiguous — implemented as HTTP 401 response. 
If redirect to /login was intended, correct in next sprint.</pro-uncertainty>
```

The orchestrator logs these for the human operator without stopping the loop.

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

## Handoff Artifact (Context Reset)

After updating progress.md, **always** write `<spec-dir>/handoff.md`. This is the lean context the NEXT agent iteration will load instead of the full artifact set, giving it a clean slate without context anxiety.

Write it with this structure (keep it under 400 words total):

```markdown
# Handoff Document — Sprint <N>

State: <completed>/<total> tasks | Sprint <N>/<max> | <ISO timestamp>
Last verdict: <AWAITING_EVAL or PASS:score or NEEDS_REVISION:issues>

## Just Completed

Work unit: <work unit name>
Files changed: <file1> (<one line summary>), <file2> (<one line summary>)
Key decisions: <any architectural choices made — one line each>

## What Comes Next

Next work unit: <next incomplete phase/section name>
Tasks:
- [ ] <next task 1>
- [ ] <next task 2>
(copy 3-5 tasks maximum from tasks.md)

## Active Blockers

<NONE or brief description>

## Critical Context

<Anything the next agent MUST know that isn't obvious from the code:
gotchas, constraints, known issues, evaluator feedback to address>

## Tech Reference

Stack: <one-line stack summary>
Entry points: <key files the agent will need>
```

This replaces the large artifact load on subsequent iterations. Keep it tight — a handoff that is too long defeats its purpose.

## Checkpoint Commit

If `iteration % checkpoint_frequency == 0` OR all tasks are complete:

1. Stage all changes: `git add .`
2. Commit: `git commit -m "[Pro] Checkpoint: iteration <N> — <work unit name> (<completed>/<total> tasks)"`
3. Log commit hash in `progress.md`

If git is not available, skip with a warning.

## AGENT.md Self-Update

After the checkpoint commit, review what you learned this iteration. If you discovered anything new about how to build, run, or test this project — commands, environment quirks, correct sequences — **update `<spec-dir>/AGENT.md`**:

```bash
# Append a bullet under the relevant section. Keep it brief.
```

Structure of `<spec-dir>/AGENT.md` (create if missing):

```markdown
# Project Agent Notes

Updated: <ISO timestamp>

## How to Start the App
<commands to start dev server / run the app>

## How to Run Tests
<test commands — unit, integration, e2e>

## Known Gotchas
- <anything that tripped up a previous agent>

## Build Learnings
- <commands that failed and the correct alternative>
```

**Rules**: Never put status reports in `AGENT.md`. Keep each bullet under 20 words. Future agents will load this at the top of every iteration.

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
