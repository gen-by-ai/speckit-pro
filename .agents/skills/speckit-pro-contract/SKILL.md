---
name: speckit-pro-contract
description: Generate a sprint contract from tasks.md — defines acceptance criteria
  before implementation starts. Fires automatically after /speckit.tasks via hook.
compatibility: Requires spec-kit project structure with .specify/ directory
metadata:
  author: github-spec-kit
  source: pro:commands/pro.contract.md
---

# SpecKit Pro — Sprint Contract Generator (`pro.contract`)

Generates a **sprint contract** from the current `tasks.md`. The contract defines what "done" means for the next implementation phase — bridging the gap between high-level task descriptions and concrete, testable acceptance criteria.

Inspired by the Anthropic harness pattern: the generator and evaluator must agree on success criteria *before* coding starts. This eliminates post-hoc rationalization.

This command is safe to call multiple times — it appends a versioned contract rather than overwriting.

## User Input

```text
$ARGUMENTS
```

Optional: `--spec-dir <path>` to target a specific feature. If omitted, auto-detect.

## Auto-Detection

If `--spec-dir` is not provided:

1. Run `.specify/scripts/bash/check-prerequisites.sh --json` to find `FEATURE_DIR`
2. Fall back: find the most recently modified `tasks.md` under `specs/` or `features/`
3. If still not found: ask the user which feature to generate a contract for

## Steps

### 1. Load tasks.md

Read `<SPEC_DIR>/tasks.md`. Extract:
- Feature name (from H1 heading or filename)
- Total incomplete tasks grouped by phase/section
- The NEXT phase to be implemented (first section with `[ ]` items)

### 2. Determine sprint scope

The sprint scope = **one phase/section** of tasks (matching the loop worker's work unit concept).

If there are no phase sections, take the first ≤5 incomplete tasks as the sprint scope.

### 3. Read supporting context

To write meaningful acceptance criteria, read:
- `<SPEC_DIR>/spec.md` — user stories and business requirements
- `<SPEC_DIR>/plan.md` — technical architecture decisions

If these files are large (>3000 words), only read the sections relevant to the sprint scope.

### 4. Generate the contract

Write the contract to `<SPEC_DIR>/contracts/sprint-<N>.md` where N is the next sprint number (count existing contracts + 1).

Contract structure:

```markdown
# Sprint Contract — Sprint <N>

Feature: <feature name from spec.md>
Generated: <ISO timestamp>
Scope: <phase/section name>

## Tasks in Scope

- [ ] <task 1 from tasks.md>
- [ ] <task 2>
...

## Acceptance Criteria

| # | Criterion | Severity | How to Verify |
|---|---|---|---|
| 1 | <concrete, testable criterion> | CRITICAL | <specific test or check> |
| 2 | <criterion> | MEDIUM | <how to verify> |
| 3 | <criterion> | LOW | <how to verify> |

## Out of Scope (Explicit Deferrals)

- <anything from spec.md or plan.md NOT in this sprint>

## Definition of Done

This sprint is DONE when:
1. All CRITICAL criteria pass
2. All tasks are marked [x] in tasks.md
3. No broken imports, no missing wiring

## Notes for Evaluator

<any ambiguities the evaluator should know about>
```

**Criteria writing rules:**
- CRITICAL: functional requirements that, if missing, mean the feature doesn't work at all
- MEDIUM: quality requirements (error handling, edge cases) that matter but aren't blockers
- LOW: polish items (logging, comments) that are nice-to-have
- Write criteria as **verifiable facts**, not vague intentions ("returns HTTP 404 for unknown IDs" not "handles errors")
- Include at least one CRITICAL criterion per major task

### 5. Create sprint pointer

Write/update `<SPEC_DIR>/contracts/current.md` with a single line pointing to the latest contract:

```
sprint-<N>
```

This is how the loop worker and evaluator find the current contract without needing explicit args.

### 6. Checkpoint

```bash
git add .
git commit -m "[Pro] Sprint <N> contract generated — <phase name>"
```

If no git changes: skip commit.

### 7. Output

Print a summary:

```
╔═══════════════════════════════════════════════════════════╗
║  Sprint Contract Generated ✓                              ║
╠═══════════════════════════════════════════════════════════╣
║  Sprint: <N>                                              ║
║  Scope:  <phase name>                                     ║
║  Tasks:  <N tasks in scope>                               ║
║  File:   <SPEC_DIR>/contracts/sprint-<N>.md               ║
╚═══════════════════════════════════════════════════════════╝

CRITICAL criteria: <N>
MEDIUM criteria:   <N>
LOW criteria:      <N>

The evaluator will grade the next sprint against these criteria.
Review: <SPEC_DIR>/contracts/sprint-<N>.md
```