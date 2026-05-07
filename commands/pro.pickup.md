---
description: "Pick up an existing feature that has spec/plan/tasks but never started the implement loop — diagnoses the stuck phase, runs missing prerequisites, and jumps into /pro.loop."
---

# SpecKit Pro — Pickup (`pro.pickup`)

`pro.pickup` is the entry point for features that **were planned but never implemented**. The single most common SpecKit Pro stall pattern is: spec.md, plan.md, and tasks.md exist in `specs/<feature>/`, but the `.ai-knowledge/<feature>/` directory was never created and no loop iteration ever ran. `pro.pickup` finishes the missing pieces and starts the loop.

Use `pro.pickup` when:
- You created a feature months ago, planned it through `/speckit.plan` or `/speckit.tasks`, and never returned to it.
- `/pro.go` flagged an existing feature in its pre-flight scan and you chose to resume it.
- You want to skip planning entirely because the spec is already correct.

## User Input

```text
$ARGUMENTS
```

| Argument | Required | Description |
|---|---|---|
| `<feature-dir>` | yes | Feature directory under `specs/` (e.g. `005-mp-1225-ipf-retry`). Pass the directory **name**, not the full path. |
| `--from <phase>` | no | Force entry at a specific phase (`tasks`, `contract`, `loop`). Default: auto-detect. |
| `--max-iterations <N>` | no | Override `loop.max_iterations` for this run. |

If `<feature-dir>` is omitted, list all features under `specs/` with their detected phase and ask the user to pick one.

## Phase Detection

Inspect the feature dir and `.ai-knowledge/<feature>/` to classify it:

```bash
PROJECT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
SPEC_DIR="$PROJECT_ROOT/specs/<feature-dir>"
AI_KNOWLEDGE_DIR="$PROJECT_ROOT/.ai-knowledge/<feature-dir>"
```

| Condition | Phase | Action |
|---|---|---|
| `spec.md` missing | `no-spec` | Refuse — `/pro.pickup` is for existing features. Suggest `/pro.go`. |
| `plan.md` missing | `spec-only` | Run `/speckit.plan`, then continue. |
| `tasks.md` missing | `plan-only` | Run `/speckit.tasks`, then continue. |
| `tasks.md` exists, all `[x]` | `complete` | Print summary; exit. Suggest `/pro.evaluate` for a final QA pass. |
| `tasks.md` exists, no `<AI_KNOWLEDGE_DIR>` | `tasks-only` | Run Phase 5b (init.sh + AGENT.md), generate sprint-1 contract, start loop. |
| `<AI_KNOWLEDGE_DIR>/contracts/` is empty | `contracts-missing` | Run `/pro.contract`, then start loop. |
| `<AI_KNOWLEDGE_DIR>/init.sh` missing | `no-initializer` | Run Phase 5b only, then start loop. |
| Loop has run before (any progress.md entries) | `mid-loop` | Refuse — suggest `/pro.resume` instead. |
| Otherwise | `ready-to-loop` | Start loop directly. |

## Confirmation Banner

```
╔══════════════════════════════════════════════════════════════╗
║  SpecKit Pro — Pickup                                        ║
╠══════════════════════════════════════════════════════════════╣
║  Feature:        <feature-dir>                               ║
║  Detected phase: <phase>                                     ║
║  Action plan:                                                ║
║    1. <step 1 — e.g. Run /speckit.tasks>                     ║
║    2. <step 2 — e.g. Generate sprint-1 contract>             ║
║    3. <step 3 — Run Phase 5b initializer setup>              ║
║    4. <step 4 — Start /pro.loop iterations>                  ║
║                                                              ║
║  Tasks remaining: <N> of <total>                             ║
╚══════════════════════════════════════════════════════════════╝

Proceed? (yes / no / dry-run)
```

`dry-run` prints what would happen and exits without changes.

## Execution

Run only the steps the action plan calls for, in order. Each step uses the same execution protocol as `/pro.go`:

### Step: Plan (if needed)
```
EXECUTE_COMMAND: /speckit.plan
```
After completion, re-classify (the new state may unlock more steps).

### Step: Tasks (if needed)
```
EXECUTE_COMMAND: /speckit.tasks
```
The `after_tasks` hook will fire `/pro.contract` automatically. If hook is disabled, manually invoke:
```
EXECUTE_COMMAND: /pro.contract
```

### Step: Contract (if needed)
```
EXECUTE_COMMAND: /pro.contract
```

### Step: Phase 5b — Initializer Setup
Reuse the full Phase 5b protocol from `pro.go.md`:
1. Derive `<AI_KNOWLEDGE_DIR>` and create directories.
2. Update `.gitignore` (`.ai-knowledge/`, optionally `specs/`).
3. Generate stack-aware `init.sh`.
4. Prepopulate `AGENT.md` from `package.json`, `Makefile`, `.github/workflows/`, `.claude/rules/`, `.cursor/rules/`, `CLAUDE.md`, and project memory.

If `<AI_KNOWLEDGE_DIR>/AGENT.md` already exists from a previous abandoned attempt, **do not overwrite** — append a `## Pickup Notes — <ISO timestamp>` section noting the resumption.

### Step: Start the loop

The pickup command is the loop driver. Execute iterations directly per the protocol in `pro.go.md` Phase 6 — load context, run smoke test, find work unit, implement, log progress, write handoff, checkpoint, update AGENT.md.

For high-iteration runs from a terminal, the orchestrator script is:
```bash
.specify/extensions/pro/scripts/bash/pro-orchestrate.sh \
  --feature-name "<feature-dir>" \
  --tasks-path "$SPEC_DIR/tasks.md" \
  --spec-dir "$SPEC_DIR" \
  --ai-knowledge-dir "$AI_KNOWLEDGE_DIR" \
  --resume
```

## Examples

```
/pro.pickup 005-mp-1225-ipf-retry
→ Detected phase: tasks-only
→ Action: generate sprint-1 contract, run Phase 5b, start loop
```

```
/pro.pickup 002-payment-method --from tasks
→ Forces entry at /speckit.tasks even if other artifacts exist
```

```
/pro.pickup
→ Lists all features under specs/ with their detected phase, prompts to pick one
```

## Why a Separate Command?

`/pro.go` always starts at `/speckit.specify`. Forcing it to "skip to phase N" via flags muddles its purpose. `/pro.pickup` is the explicit entry point for resuming planned-but-unimplemented work — the most common reason features stall in real projects. Splitting them keeps each command's intent clear and makes the pre-flight overlap-detection in `/pro.go` actionable: "Found existing feature → run `/pro.pickup <feature>`."
