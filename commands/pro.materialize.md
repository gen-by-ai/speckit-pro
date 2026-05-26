---
description: "Materialize tasks.md into per-task packets under <SPEC_DIR>/task-packets/TASK-NNN-<slug>.md. Local-model refined when Ollama is available; deterministic skeletons otherwise."
---

# SpecKit Pro — Task Packet Materializer (`pro.materialize`)

Splits a feature's `tasks.md` into **one self-contained Markdown packet per task** so the implementing agent can read a tight context bundle instead of the whole spec/plan/tasks set.

This is the cheapest single offload from Claude — task-packet generation is largely deterministic (parse tasks, slugify, lay out template), and the only judgement-y bit (file paths to read first, dependencies, edge cases) is exactly the kind of work local 7B-class models do well.

## When this runs

- Manual: `/speckit.pro.materialize [--spec-dir <path>] [--only NNN,NNN] [--start NNN] [--end NNN] [--force]`
- Pipeline: `pro.go` Phase 4b — together with `/pro.local-prep` after `/speckit.tasks` if `local_models.auto_run.after_tasks: true`.

## What it writes

```
<SPEC_DIR>/task-packets/
  TASK-001-add-payment-retry.md
  TASK-002-replay-on-timeout.md
  ...
```

Each packet follows `templates/local/task-packet.prompt.md`:

```
# TASK-<id> — <short title>

## Goal
## Acceptance criteria
## Files likely to change
## Files to read first
## Dependencies on other tasks
## Test plan
## Risks / edge cases
## Out of scope for this packet
```

## Behavior matrix

| `local_models.enabled` | Ollama reachable | Packet content                                            |
|------------------------|------------------|-----------------------------------------------------------|
| `false`                | n/a              | Deterministic skeleton with `UNKNOWN` placeholders        |
| `true`                 | no               | Skeleton (warning printed)                                |
| `true`                 | yes              | Local-model refined (uses `local_models.code_model`)      |

Skeletons are still useful: they hold the right shape so the implementer fills the blanks in one pass instead of inventing structure on the fly.

## User Input

```text
$ARGUMENTS
```

Optional flags:
- `--spec-dir <path>` — target feature directory; auto-detected otherwise.
- `--only NNN,NNN` — comma-separated task IDs (zero-padded form, e.g. `001,003`).
- `--start NNN` / `--end NNN` — inclusive ID range filter.
- `--force` — overwrite existing packets.
- `--dry-run` — print what would happen.

## Steps

### 1. Resolve target

Auto-detect `<SPEC_DIR>` via `.specify/scripts/bash/check-prerequisites.sh --json` unless `--spec-dir` is passed.

### 2. Parse `tasks.md`

The driver accepts these task-line shapes (existing SpecKit conventions):
```
- [ ] T001 Title goes here
- [ ] **T001** Title
- [x] T010 Title
- [ ] Title with no ID (we assign AUTO-NNN)
```

It also captures the most recent H1/H2 heading as `section` (the work-unit grouping the loop already uses).

### 3. Generate packets

For each selected task:
- Build a per-task prompt that injects `TASK-<id>` and the title at the bottom of `templates/local/task-packet.prompt.md`.
- Feed the local model: this prompt + a tiny task-context file + `spec.md` + `plan.md` + `tasks.md` + `repo-map.md` (if present).
- If local generation fails, fall back to the skeleton (same shape, `UNKNOWN` markers).

### 4. Output

Files are written to `<SPEC_DIR>/task-packets/TASK-NNN-<slug>.md`. The slug is a 40-char `[a-z0-9-]` slug of the title.

## How the implementer uses these

Once packets exist, the implement loop in `pro.go` Phase 6 can load `<SPEC_DIR>/task-packets/TASK-<id>-<slug>.md` instead of re-reading `spec.md + plan.md + tasks.md` for every work unit. Typical token savings per iteration: 60–80 %.

The loop's context-load rule becomes:
```
1. handoff.md (always)
2. context-pack.md (if present, replaces spec/plan/tasks)
3. task-packets/TASK-<current>-<slug>.md (for the current work unit)
```

This is the "Markdown-heavy harness reads selectively" pattern from `.dev-work/dev.md`.

## Configuration knobs

```yaml
local_models:
  enabled: false
  code_model: "qwen2.5-coder:7b"
  tasks:
    task_packets: true
  auto_run:
    after_tasks: true
```

Set `tasks.task_packets: false` if you want `pro.local-prep` to fire after tasks but skip packet materialization (e.g. you have your own packet format).

## What this command does NOT do

- It does not modify `tasks.md`. The source of truth is unchanged.
- It does not implement anything. It just lays out per-task context.
- It does not commit. Run `/pro.checkpoint` afterwards if you want a snapshot.
