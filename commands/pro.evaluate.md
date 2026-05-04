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

### Step 1 — Calibrate Against Past Evaluations

Before scoring anything, read all files in `<spec-dir>/evaluations/` (sorted oldest → newest). Look for:
- **Score drift**: are scores trending too high/low across sprints?
- **Recurring failures**: issues the generator keeps reintroducing (log these as higher severity this sprint)
- **Resolved issues**: things previously flagged that are now genuinely fixed

Use this to set your scoring bar. If Sprint 1 scored 72 and Sprint 2 scored 91 with no obvious quality jump, your evaluator is drifting generous — correct for it.

### Step 2 — Load the Sprint Contract

Read `<spec-dir>/contracts/sprint-<N>.md`. The acceptance criteria table is the definitive definition of "done". Every CRITICAL criterion must pass for the sprint to pass.

### Step 3 — Live Browser Testing (if applicable)

If `<spec-dir>/init.sh` exists and the contract includes UI or API criteria, run the app and test it live:

```bash
bash <spec-dir>/init.sh   # start the dev server
```

Then use the **agent-browser skill** (`.agents/skills/agent-browser/SKILL.md`) to exercise the running application as a real user would:

```bash
agent-browser open http://localhost:<port>
agent-browser snapshot -i
# Click through every user flow listed in the contract criteria
# Screenshot on failure: agent-browser screenshot <label>
```

**Test every CRITICAL contract criterion** by actually clicking through the UI or hitting the API endpoint — not by reading source code alone. Record findings as `PASS` / `FAIL` with exact reproduction steps.

If the app fails to start, mark all UI criteria as FAIL with reason `app-not-startable`.

### Step 4 — Static Code Review

Read the actual code files changed this sprint (check `git diff HEAD~1` or the handoff.md file list). Verify:
- Edge cases and error paths (not just happy path)
- Security issues: SQL injection, XSS, hardcoded secrets, broken auth
- Stub or placeholder implementations (auto-fail if found)
- Broken imports or wiring

### Step 5 — Write Evaluation & Verdict

Write evaluation to `<spec-dir>/evaluations/sprint-<N>.md`.
Apply the four severity tiers: CRITICAL / MEDIUM / LOW / INFO.
Output `<pro-eval>VERDICT:details</pro-eval>` as final line.

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
