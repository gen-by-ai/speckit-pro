---
description: "Evaluate a completed sprint against its contract — strict QA review with concrete feedback for the generator"
---

# SpecKit Pro — Sprint Evaluator

This command runs a **strict QA evaluation** of a completed generator sprint. It compares the implementation against the sprint contract and produces a verdict with actionable feedback.

Inspired by the Anthropic harness pattern: separating the generator from the evaluator eliminates self-praise bias — agents cannot reliably grade their own work.

## User Input

```text
$ARGUMENTS
```

Parse from `$ARGUMENTS`:

| Argument | Required | Description |
|---|---|---|
| `feature` | yes | Feature directory name |
| `spec-dir` | yes | Absolute path to spec directory |
| `sprint` | yes | Sprint/iteration number being evaluated |
| `contract` | yes | Path to sprint contract file |
| `tasks` | yes | Path to tasks.md |

## Evaluation Steps

Follow the instructions in `agents/pro.evaluate.agent.md` exactly.

Key behaviors:
1. Load the sprint contract — it defines what "done" means
2. Read the actual code, not just the generator's self-report
3. Check edge cases and error paths
4. Apply the four severity tiers: CRITICAL / MEDIUM / LOW / INFO
5. Write evaluation to `<spec-dir>/evaluations/sprint-<N>.md`
6. Output `<pro-eval>VERDICT:details</pro-eval>` as final line

## Output Protocol

The final line of your response must be one of:
- `<pro-eval>PASS:<score></pro-eval>` — sprint accepted, loop continues
- `<pro-eval>NEEDS_REVISION:<issues></pro-eval>` — generator gets another pass
- `<pro-eval>FAIL:<reason></pro-eval>` — sprint failed, human review required

## Evaluation Criteria

Grade each sprint on:

### 1. Contract Completeness (40%)
Is everything the contract specified actually implemented and wired up?

### 2. Correctness (30%)
Does the implementation behave correctly? Check happy path AND edge cases.

### 3. Code Quality (20%)
No security bugs, no broken imports, no obvious logic errors.

### 4. Spec Alignment (10%)
Does the implementation match the user stories in spec.md?

## What NOT to Do

- Do not be generous because the generator "tried"
- Do not pass a sprint because most things work — CRITICAL failures are blocking
- Do not accept stub implementations
- Do not skip reading the actual code files
