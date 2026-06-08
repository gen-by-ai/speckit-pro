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
| `knowledge-feature-dir` | no | Absolute path to `.knowledge/features/<feature>` dir (default: derived from git root) |

**Deriving `<knowledge-feature-dir>`** (when not passed explicitly):
```bash
PROJECT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
FEATURE_KNOWLEDGE_DIR="$PROJECT_ROOT/.knowledge/features/<feature>"
# Legacy: if missing but "$PROJECT_ROOT/.ai-knowledge/<feature>" exists, use that instead.
```
Create it if it doesn't exist: `mkdir -p "$FEATURE_KNOWLEDGE_DIR"`

## Pre-Iteration Setup

0. **Repo knowledge prime** (when `knowledge.enabled: true` and `knowledge.prime_each_loop_iteration: true` in `pro-config.yml`):

   ```
   EXECUTE_COMMAND: /pro.knowledge-sync --mode prime --query "<spec.md H1> <current work-unit heading from tasks.md>"
   ```

   Keep the `<pro-knowledge-prime>` block in context for this iteration. If `.knowledge/` is missing and `knowledge.auto_bootstrap: true`, bootstrap runs first.

   **Minimum manual load** (if prime was skipped): always read these when present (max 120 lines each):
   - `<PROJECT_ROOT>/.knowledge/domain/invariants.md`
   - `<PROJECT_ROOT>/.knowledge/domain/glossary.md`

1. **Load context files** — use the leanest context that's sufficient:

   **If `<spec-dir>/handoff.md` exists AND `iteration > 1`** (context-reset mode):
   - Load ONLY `<spec-dir>/handoff.md` — it contains everything needed for this sprint
   - Load `<spec-dir>/tasks.md` — to find next incomplete work unit
   - Do NOT load spec.md, plan.md, or progress.md unless you need a specific detail not in handoff.md

   **Legacy fallback**: if `handoff.md` is missing but `<spec-dir>/context-summary.md` exists (from pre-v1.5 SpecKit Pro runs), treat it as a handoff substitute. Load it instead of the full artifact set, and write a fresh `handoff.md` at the end of this iteration so subsequent iterations use the new schema.

   **Otherwise** (first iteration or no handoff/summary):
   - `<spec-dir>/spec.md` — requirements and user stories
   - `<spec-dir>/plan.md` — technical architecture
   - `<spec-dir>/tasks.md` — task checklist with completion state
   - `<knowledge-feature-dir>/progress.md` — history of previous iterations (if exists, last 10 entries only)
   - `<spec-dir>/session.md` — session state (if exists)

2. **Load `AGENT.md`** — if `<knowledge-feature-dir>/AGENT.md` exists, read it. It contains learnings from previous iterations about how to build, run, and test this project. Always honour the commands and sequences it records.

3. **Run smoke test** — if `<knowledge-feature-dir>/init.sh` exists, execute it:
   ```bash
   bash <knowledge-feature-dir>/init.sh
   ```
   - If it exits non-zero, fix the break before implementing new features and log it in `<knowledge-feature-dir>/progress.md` under `### Pre-iteration fix`.
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

## Task Complexity Routing

Before implementing, classify each task in the selected work unit. Route based on complexity — this prevents over-parallelising (wasted tokens + merge conflicts) and under-parallelising (sequential work that could be concurrent).

| Tier | Definition | Action |
|---|---|---|
| **Trivial** | Single, unambiguous, < 10 lines of change | Implement directly — no sub-agents |
| **Simple** | Clear scope, one domain, no unknowns | Implement as a focused sequential unit |
| **Moderate** | Multi-file, some unknowns | One sub-task at a time; verify each before proceeding |
| **Complex** | Cross-domain, parallel-safe sub-tasks | Dispatch parallel agents when domains are independent |
| **Research** | Requires exploration before implementation | Explore/read first, then implement; log findings in progress.md |

**Parallel dispatch** (ALL conditions must be met):
- 3+ unrelated sub-tasks OR clearly independent domains (frontend / backend / database)
- No shared state or file overlap between sub-tasks
- Clear file boundaries per sub-task
- Sub-task is marked `[P]` in tasks.md OR explicitly classified as parallel-safe above

**Sequential dispatch** (ANY condition triggers):
- Sub-tasks have dependencies (B needs output from A)
- Shared files or state (merge conflict risk)
- Scope is unclear — classify as Moderate or Research first, then implement

> Positive framing: state what you will implement, not what you won't. "Implement X for the frontend agent and Y for the backend agent simultaneously" outperforms "don't try to do this in one response."

## Sprint Contract (pre-implementation)

**Before writing any code**, check for a sprint contract:

1. Look for `<knowledge-feature-dir>/contracts/sprint-<iteration>.md`
2. If it exists: read it — the acceptance criteria define what "done" means for this sprint. Implement against those criteria, not just the task descriptions.
3. If it does NOT exist: create one at `<knowledge-feature-dir>/contracts/sprint-<iteration>.md` using this structure:

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
- Stage `.knowledge/features/` paths in any commit — workspace-only state must never reach a feature branch destined for PR review (see Checkpoint Commit Scope below)
- **Edit, delete, or re-hash a *sealed* sprint contract or its `.sha256` seal.** Once `/pro.contract` has written `contracts/sprint-<N>.md` and its committed `contracts/sprint-<N>.sha256`, that rubric is **frozen for the sprint** — it is the independent yardstick `/pro.evaluate` grades you against, and a generator that can rewrite its own rubric (or recompute its seal to match an edit) defeats the entire evaluation. The contract rubric is owned by `/pro.contract`, never by the loop. If a contract row is genuinely missing (e.g. the Branching control-flow rule says you must add a row for a new guarded branch), **do not add or change the row yourself**: STOP, emit a contract-row-needed uncertainty, and let `/pro.contract` add the row and **re-seal**:
  ```
  <pro-uncertainty>Contract row needed: <what the row must assert> in sprint-<N>.md.
  The contract is sealed — re-sealing is owned by /pro.contract. Pausing for /pro.contract to add the row and re-seal before I implement the affected branch.</pro-uncertainty>
  ```
  Adding the row yourself and re-running `shasum`/`sha256sum` over the edited file would forge a valid-looking seal over a rubric you weakened — `/pro.evaluate` would then emit `FAIL:rubric-mutated` (mismatch against the committed seal) or, worse, silently grade you against your own softened bar. Touching the `.sha256` is therefore as forbidden as touching the contract body.

**Prefer reversible over irreversible:**
- Favour additive changes (add a new function, add a new route) over modifying existing ones when both achieve the goal
- Commit before any major refactor, not just at checkpoint frequency — small commits = cheap rollbacks
- If a task requires a destructive action, implement the safest equivalent and note the limitation

These rules exist because actions at the file-system and database level are not easily undone across agent iterations. If `constitution.md` exists in the project, its constraints take precedence over everything — including these defaults.

## Sub-Agent Invocation Quality

When spawning sub-agents or delegating focused tasks, every invocation must include four components. Vague invocations produce vague results — sub-agents cannot ask clarifying questions; they work from what they receive.

| Component | Bad | Good |
|---|---|---|
| **Scope** | "Fix auth" | "Fix OAuth redirect loop in `src/lib/auth.ts:handleCallback()`" |
| **File paths** | "the auth file" | "`src/lib/auth.ts`, `src/middleware/session.ts`" |
| **Acceptance criteria** | "make it work" | "After login, response is `302 /dashboard`, not `302 /login`" |
| **Dependency context** | (omitted) | "Previous agent created the `users` table — use that schema" |

**Invocation template** (use this when dispatching any sub-agent):
```
Task: <one-sentence description>
Files in scope: <exact paths>
Files out of scope: <anything that must not be touched>
Accepts when: <one or more verifiable criteria>
Depends on: <output from previous step, if any>
```

Front-load file paths — the model processes paths literally. Passing `apps/web/src/app/page.tsx` saves tool calls versus "the homepage file."

## Implementation

For each contract row in scope (the contract's Acceptance Criteria table is the canonical to-do list — `tasks.md` is the high-level grouping):

1. **TDD-first** — write the Browser Test script (and the Verified By unit/integration test) **before** the implementation that satisfies them.
2. Run the Browser Test script. It MUST fail. If it passes against the unmodified code, the contract row is not specific enough — sharpen the assertion or you are not actually testing anything.
3. Implement the code/changes described in the task.
4. Run the Browser Test script again. It MUST pass. If it does not, iterate on the implementation — never weaken the test to make it green.
5. Run the Verified By unit/integration test. Same protocol: must fail before, pass after.
6. Mark the task complete in `tasks.md` only when both green.

**A task is NOT complete until every contract row it covers has a passing Browser Test script committed to `<spec-dir>/browser-tests/`.** Marking a task `[x]` without the script is a contract violation and produces a NEEDS_REVISION verdict from the evaluator.

### Browser-test script requirements

For each CRITICAL row in the sprint contract, write `<spec-dir>/browser-tests/<flow>/<NN>-<state>.sh`. Reference `templates/browser-test-template.sh` (copied into the spec dir as `_template.sh` by `/speckit.pro.contract`) for the canonical shape.

Hard rules:
- **Hermetic setup** — every script clears `localStorage`, `sessionStorage`, cookies before asserting. No script may depend on the order in which siblings ran.
- **Asserts one row** — one script asserts exactly one contract row. Multi-assert scripts are forbidden; they hide which row regressed when the script fails.
- **Time-boxed** — no `wait-for` longer than 10s; explicit timeouts only. A test that hangs is worse than one that fails.
- **Exit codes** — `0` PASS, `1` FAIL (assertion failed), `2` ERROR (app/infra problem). Anything other than 0 is a sprint blocker.
- **Re-runnable** — a re-run on a clean build MUST produce the same verdict. Flaky scripts are immediate NEEDS_REVISION.
- **Negative assertions matter** — every script must assert what should NOT be visible (stuck spinner, blank container, raw error text) in addition to what should. The MP-1435 lesson: a happy-path-only assertion missed the empty-store regression entirely.

### Branching control-flow rule

If your diff introduces a guard, short-circuit, or any new branch into an existing function (e.g. `if (X) return;`, `if (!ok) throw;`, an early-exit `return null` inside a `useEffect`), the contract must have at least one row asserting behavior when the guarded condition is true AND one row asserting the original path is unaffected. **Add the row to the contract before implementing the branch.** This is the structural fix for the MP-1435 class of bug: every new branch must have a contract row.

If the contract does not yet have those rows, stop implementation and emit:

```
<pro-uncertainty>Adding a new branch in <file>:<line>. Contract row needed for guarded path
and unaffected original path. Pausing for contract update.</pro-uncertainty>
```

Then add the rows and resume — **but mind the seal**: if the contract has a committed `contracts/sprint-<N>.sha256`, it is frozen and you may **not** edit it or re-hash the seal yourself (see Scope of Autonomy). Emit the contract-row-needed uncertainty and let `/pro.contract` add the rows and re-seal, then resume against the re-sealed rubric. Only when the contract is **unsealed** (no `.sha256`, or the seal carries the literal `UNSEALED` token) may the loop append the rows under the current sprint and commit the contract update directly.

**Quality checks during implementation**:
- Does the implementation satisfy each contract row's Browser Test? (Run them — don't infer from reading code.)
- Does it follow the tech stack from `plan.md` (or `handoff.md`)?
- Are there security issues? (SQL injection, XSS, hardcoded secrets, broken auth)
- Does the feature actually wire up end-to-end, not just exist as a stub?
- Is the code structured so the **next iteration can safely build on it**? (no deep coupling, no magic constants, no undocumented side effects)
- For every new branch you introduced: is there a Browser Test row asserting its behavior?

### Stub-and-no-op self-check

Before marking ANY task complete, scan your own diff for:
- `TODO`, `FIXME`, `XXX`, `HACK` markers
- `throw new Error('not implemented')`, `raise NotImplementedError`
- Function bodies that are just `return;`, `return null;`, `return {};`, `pass`
- Components that render `<></>`, `null`, or a comment-only JSX block
- Empty `catch` blocks that swallow errors silently

If any match exists in a file the contract claims to have implemented, the task is NOT done. Either complete it or mark the task with `<!-- BLOCKED: <reason> -->` and emit `BLOCKED`. Do not signal `CONTINUE` with stubs in the diff — the evaluator will auto-FAIL the sprint.

**Underspecified requirements:**
If a task or criterion is ambiguous enough that two reasonable implementations would produce meaningfully different results, do **not** silently guess. Pick the most conservative interpretation, implement it, and emit `<pro-uncertainty>` in your progress entry:

```markdown
<pro-uncertainty>Task "handle auth errors" is ambiguous — implemented as HTTP 401 response. 
If redirect to /login was intended, correct in next sprint.</pro-uncertainty>
```

The orchestrator logs these for the human operator without stopping the loop.

If you encounter a blocker (cannot implement a task):
- Leave the task as `- [ ]` with a note `<!-- BLOCKED: <reason> -->`
- Log the blocker in `<knowledge-feature-dir>/progress.md`
   - Output `<pro-status>BLOCKED:<task description></pro-status>` after completing other tasks

## Progress Tracking

After implementing the work unit, append to `<knowledge-feature-dir>/progress.md`:

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

If `<knowledge-feature-dir>/progress.md` does not exist, create it with this header first:

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

1. **Stage with PR-safe scope**. Never `git add .` blindly — that pulls workspace-only state (`.knowledge/features/`, optionally `specs/`) into the feature branch.

   Use a pathspec exclusion:
   ```bash
   # Always exclude .knowledge/features/ — it's machine-generated workspace state.
   # When commit_artifacts is false (default), also exclude specs/.
   git add -- ':!.knowledge/features' ':!.knowledge/features/**' ':!.knowledge/metrics' ':!.knowledge/metrics/**' \
     ${COMMIT_ARTIFACTS:+} ${COMMIT_ARTIFACTS:-':!specs' ':!specs/**'} .
   ```
   Or, more simply, stage explicit paths the iteration actually changed (preferred — narrowest blast radius):
   ```bash
   git add <file1> <file2> ...   # the files you modified this iteration
   ```

   `tasks.md` lives under `specs/<feature>/`. When `commit_artifacts: false`, its `[ ]` → `[x]` updates are intentionally **not** committed — the loop tracks them locally; the final PR is graded by the code, not the planning artifacts. When `commit_artifacts: true`, include `tasks.md` in the staged set.

2. Commit: `git commit -m "[Pro] Checkpoint: iteration <N> — <work unit name> (<completed>/<total> tasks)"`

3. Log commit hash in `<knowledge-feature-dir>/progress.md`.

4. **Sanity-check the staged set** before each checkpoint. Run:
   ```bash
   git diff --cached --name-only | grep -E '^(\.knowledge/features|\.knowledge/metrics|\.specify/extensions/pro)/' || true
   ```
   If anything matches, you have leaked workspace state into the commit — unstage with `git restore --staged <path>` and recommit. Note the leak in progress.md so the operator can audit.

If git is not available, skip with a warning.

### Why PR-safe scope matters

The most common operator pain in real projects is force-pushing a feature branch to remove SpecKit artifacts before opening a PR. The default behavior of `git add .` plus an unsuspecting `git push` lands `.knowledge/features/AGENT.md`, `progress.md`, sprint contracts, and evaluations into reviewer scope. Exclude them at staging time — not after the fact.

## AGENT.md Self-Update

After the checkpoint commit, review what you learned this iteration. If you discovered anything new about how to build, run, or test this project — commands, environment quirks, correct sequences — **update `<knowledge-feature-dir>/AGENT.md`**:

```bash
# Append a bullet under the relevant section. Keep it brief.
```

Structure of `<knowledge-feature-dir>/AGENT.md` (create if missing):

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

## System Evolution (End of Iteration)

Every repeated problem is a system gap, not a one-time mistake. After updating `AGENT.md`, apply the system evolution check:

**Ask**: "What rule, reference, or constraint would have prevented the friction I hit this sprint?"

**Act**:
- Repeated routing mistake → add a routing rule to the task complexity table in your next invocation
- Recurring architectural decision → add it to `spec.md` as an established constraint
- New tech convention → add to `plan.md` or create a skill reference under `.specify/skills/`
- Recurring evaluator feedback → tighten the sprint contract template to catch it next time
- Broken command or environment setup → update `<knowledge-feature-dir>/AGENT.md`

Append system-level improvements to `<knowledge-feature-dir>/progress.md` under a `### System Improvements` sub-header. The orchestrator surfaces these in the final run summary so the human operator can act on them.

> Per-feature workspace (`AGENT.md`, `init.sh`, `contracts/`, `evaluations/`, `progress.md`) lives under `<project-root>/.knowledge/features/<feature>/`. Shared team knowledge (`INDEX.md`, `domain/`, `decisions/`) lives at `<project-root>/.knowledge/` root and is committed to git. `handoff.md` and `session.md` remain in `<spec-dir>/` as transient per-sprint state.

## Completion Signals

Output **exactly one** of these terminal tags as the last line of output:

| Tag | Meaning |
|---|---|
| `<pro-status>COMPLETE</pro-status>` | All tasks done — terminate loop successfully |
| `<pro-status>CONTINUE</pro-status>` | Work unit done — more tasks remain, continue loop |
| `<pro-status>BLOCKED:<reason></pro-status>` | Stuck on a task — orchestrator decides whether to retry |
| `<pro-status>ERROR:<message></pro-status>` | Unexpected error — orchestrator applies circuit breaker |
| `<pro-status>MAX_ITERATIONS</pro-status>` | Safety limit reached — terminate loop |

> **Headless JSON path — the tag must be the final line of the textual answer.** When this loop runs unattended via `pro-orchestrate.sh` with `--output-format json`, the orchestrator does **not** read your raw stdout — it parses the CLI's JSON result object and scrapes the `<pro-status>` tag out of the `.result` string field (the assistant's textual answer), defensively (python3, then a text scrape; no jq). So the tag must still be emitted as plain text in your answer **and still be the last line of that answer** — exactly as in the in-harness path. Do not move it into a tool call, a code fence the model might drop, or a trailing summary after it; if it is not the final line of `.result`, the orchestrator cannot derive a control signal and treats the iteration as `ERROR:*` (which counts toward the circuit breaker). One tag, last line, every time — text path and JSON path alike.

## Context Efficiency Guidelines

To maintain effectiveness across many iterations:
- Focus only on the current work unit — do not re-read or re-implement previous phases
- Keep `<knowledge-feature-dir>/progress.md` entries concise (< 200 words per iteration)
- Reference `spec.md` and `plan.md` for intent, not line-by-line

### The Four Failure Modes — Recognize and Avoid

| Failure Mode | Symptom | Counter |
|---|---|---|
| **Context Poisoning** | Errors compound as prior mistakes anchor new reasoning | Fresh session via `handoff.md` reset |
| **Context Distraction** | Over-reliance on conversation history rather than fresh reasoning | Strategic chunking — one work unit per iteration |
| **Context Confusion** | Irrelevant files or docs pulled into context misdirect execution | Scope reads to current work unit only |
| **Context Clash** | Contradictory instructions (spec vs progress vs AGENT.md) | AGENT.md is ground truth for runtime facts |

### The 80/20 Rule — Stop Before You're Full

Context anxiety is real: models prematurely wrap up or make shortcuts as they approach their limit. Apply the 80/20 rule:

- **At ~80% estimated context fill** — stop complex multi-file work. Complete the current write, save the handoff, close the iteration with `CONTINUE`.
- **Never start a new sub-agent invocation** when your own context is already above 70% — the sub-agent inherits a rich context and will hit limits faster than expected.
- **Emit `<!-- Context: HIGH -->` in progress.md** when you estimate >75% context fill. The orchestrator surfaces this in the run summary.
- **Task chunking**: fully complete one work unit (a single component, file, or test suite) before integrating with other units. Integration at 90% context almost always produces incomplete results.

### Proactive Backup Over Lossy Compaction

The `handoff.md` protocol IS your proactive backup strategy. Treat it accordingly:

- **Write `handoff.md` at the end of every iteration** — even `CONTINUE` iterations. A handoff written at 60% context is clean; a compaction triggered at 83% loses nuance.
- Proactive clearing (write → fresh start) **always beats** auto-compaction. Compaction preserves tokens but creates a lossy summary that cannot recover precise implementation state.
- If you reach a natural checkpoint (function written, tests passing, file saved), that is the correct moment to write the handoff and signal `CONTINUE` — regardless of remaining context.

### Iteration Orientation (High-Count Iterations)

If `iteration > 5`, open each iteration with a one-sentence orientation:
> "Continuing `<feature>`: previously completed `<last work unit>`, now starting `<current work unit>`."

This prevents drift in long runs where earlier context has been compacted or reset.

## Post-loop (when driven by `/pro.go` or `/pro.pickup`)

The orchestrator script (`pro-orchestrate.sh`) ends at implement-complete. When the parent command is **`/pro.go`** or **`/pro.pickup`**, the **parent agent** must run **`pro.go.md` Phase 7** after the last iteration — not only hooks:

```
EXECUTE_COMMAND: /pro.reconcile
EXECUTE_COMMAND: /pro.local-review
EXECUTE_COMMAND: /pro.evaluate
EXECUTE_COMMAND: /pro.knowledge-sync
```

Skip knowledge-sync if the evaluator did not PASS or `knowledge.sync_after_evaluate: false`.
