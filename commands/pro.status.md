---
description: "Rich status dashboard showing current phase, task progress, session history, and health signals for the active autonomous run"
---

# SpecKit Pro — Status Dashboard

Display a comprehensive status view of the current (or most recent) autonomous run.

## User Input

```text
$ARGUMENTS
```

Optional flags in `$ARGUMENTS`:
- `--feature <name>` — show status for a specific feature (default: auto-detect active feature)
- `--verbose` — include full iteration log from `progress.md`
- `--json` — output machine-readable JSON

## Detection

1. Run `.specify/scripts/bash/check-prerequisites.sh --json` to detect `FEATURE_DIR`.
2. If `--feature` was provided, use that feature name to locate its spec directory.
3. If no single active feature is found, **fall through to Workspace Overview Mode** (below) instead of erroring out — the most common reason there's no active feature is that several were planned but none entered the loop, and the user wants to see them all to decide which to pick up.

## Workspace Overview Mode

Triggered when no active feature is detected, or when user passes `--workspace` explicitly. Shows every feature under `specs/` with its current phase and the suggested entry command.

### Data Collection

```bash
PROJECT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
SPECS_DIR="$PROJECT_ROOT/specs"
AI_KNOWLEDGE_ROOT="$PROJECT_ROOT/.ai-knowledge"
```

For each subdirectory under `specs/`:

| Artifacts present | Phase | Suggested entry |
|---|---|---|
| `spec.md` only | `spec-only` | `/speckit.plan` |
| + `plan.md` | `plan-only` | `/speckit.tasks` |
| + `tasks.md` (any `[ ]`), no contracts/ | `tasks-only` | `/pro.contract` then `/pro.pickup <feature>` |
| + contracts/, no `<AI_KNOWLEDGE_ROOT>/<feature>/` | `contracts-ready` | `/pro.pickup <feature>` |
| `<AI_KNOWLEDGE_ROOT>/<feature>/progress.md` exists, tasks remain | `in-loop` | `/pro.resume` |
| All `[x]` in tasks.md | `complete` | (none — done) |

Render:

```
╔══════════════════════════════════════════════════════════════╗
║  SpecKit Pro — Workspace Overview                            ║
╠══════════════════════════════════════════════════════════════╣
║  Feature                          Phase            Tasks      ║
╠══════════════════════════════════════════════════════════════╣
║  001-MP-1242-ensure-2-decimals    tasks-only       0/8        ║
║  002-payment-method               plan-only         —         ║
║  003-mp-1151-kb                   plan-only         —         ║
║  005-ipf-retry-type-flag          contracts-ready  0/12       ║
║  008-payment-method-audit-log     in-loop          8/11 (73%) ║
║  009-greenhouse-deflection        complete         24/24      ║
╠══════════════════════════════════════════════════════════════╣
║  PICKUP HINTS                                                 ║
╠══════════════════════════════════════════════════════════════╣
║  • /pro.pickup 005-ipf-retry-type-flag  — closest to running  ║
║  • /pro.resume                          — continue 008        ║
║  • /speckit.tasks                       — unblock 002, 003    ║
╚══════════════════════════════════════════════════════════════╝
```

Sort: `in-loop` first, then `contracts-ready`, then `tasks-only`, then `plan-only`, then `spec-only`, with `complete` at the bottom.

If `--json` is passed in workspace mode, output a list of feature objects with `{ name, phase, tasks: { total, completed }, suggested_command }`.

## Single-Feature Mode

Used when a feature is detected (or `--feature <name>` is provided).

## Data Collection

Read the following files from `<FEATURE_DIR>`:
- `tasks.md` — parse task completion state
- `session.md` — parse phase history and current status
- `progress.md` — parse iteration log (most recent 5 entries for default view)
- `spec.md` — extract feature name and user story count
- `plan.md` — extract tech stack summary (first line or title)

From git (if available):
- Current branch: `git rev-parse --abbrev-ref HEAD`
- Last commit: `git log -1 --format="%h %s %ar"`
- Uncommitted changes: `git status --short | wc -l`

## Output Format

### Default (rich text) view:

```
╔══════════════════════════════════════════════════════════════╗
║  SpecKit Pro — Status Dashboard                              ║
╠══════════════════════════════════════════════════════════════╣
║  Feature:  <feature name from spec.md>                       ║
║  Branch:   <git branch>                                      ║
║  Tech:     <tech stack summary>                              ║
╠══════════════════════════════════════════════════════════════╣
║  PIPELINE PHASE PROGRESS                                     ║
╠══════════════════════════════════════════════════════════════╣
║  ✓ specify     ✓ clarify     ✓ plan                          ║
║  ✓ tasks       ✓ analyze     ⟳ implement (in progress)       ║
╠══════════════════════════════════════════════════════════════╣
║  IMPLEMENTATION PROGRESS                                     ║
╠══════════════════════════════════════════════════════════════╣
║  Tasks:    ██████████░░░░░░░░  28/45 (62%)                   ║
║  Phases:   Phase 3 of 6 in progress                          ║
║  Iteration: 7 / 20 max                                       ║
║  Last checkpoint: "Checkpoint: iteration 6 — User Auth"      ║
╠══════════════════════════════════════════════════════════════╣
║  HEALTH SIGNALS                                              ║
╠══════════════════════════════════════════════════════════════╣
║  ✓ No blocked tasks                                          ║
║  ✓ No consecutive failures                                   ║
║  ⚠ 2 uncommitted changes                                    ║
╠══════════════════════════════════════════════════════════════╣
║  RECENT ACTIVITY (last 3 iterations)                         ║
╠══════════════════════════════════════════════════════════════╣
║  Iter 7: User Profile CRUD — 4 tasks, 3 files modified       ║
║  Iter 6: Auth middleware — 5 tasks, 6 files ✓ checkpoint     ║
║  Iter 5: JWT token service — 3 tasks, 2 files modified       ║
╠══════════════════════════════════════════════════════════════╣
║  NEXT ACTIONS                                                ║
╠══════════════════════════════════════════════════════════════╣
║  • /pro.resume — continue the autonomous loop        ║
║  • /pro.checkpoint — save a manual checkpoint        ║
╚══════════════════════════════════════════════════════════════╝
```

### Construction Logic

**Pipeline phase icons**:
- `✓` — phase artifact exists (spec.md, plan.md, tasks.md, etc.)
- `⟳` — phase currently in progress (from session.md)
- `○` — phase not yet started
- `✗` — phase failed (from session.md)

**Task progress bar**:
- Count `- [x]` and `- [X]` lines as completed
- Count `- [ ]` lines as incomplete
- Render a 20-character progress bar: `█` for completed, `░` for remaining

**Blocked task detection**:
- Search `tasks.md` for `<!-- BLOCKED:` comments
- List each blocked task description

**Health signals**:
- Consecutive failures: check last N entries in `progress.md` for `ERROR:` tags
- Uncommitted changes: `git status --short | wc -l`
- Context saturation: check `progress.md` for `<!-- Context: HIGH -->` markers

## JSON Output (--json flag)

```json
{
  "feature": "<name>",
  "branch": "<branch>",
  "pipeline": {
    "specify": "complete",
    "clarify": "complete",
    "plan": "complete",
    "tasks": "complete",
    "analyze": "complete",
    "implement": "in_progress"
  },
  "tasks": {
    "total": 45,
    "completed": 28,
    "blocked": 0,
    "percentage": 62
  },
  "loop": {
    "current_iteration": 7,
    "max_iterations": 20,
    "consecutive_failures": 0
  },
  "health": {
    "blocked_tasks": [],
    "uncommitted_changes": 2,
    "context_saturation": false
  },
  "last_activity": "<ISO timestamp>"
}
```

## Graceful Degradation

- If `tasks.md` is missing: report "Tasks not yet generated"
- If `session.md` is missing: report "No session state found"
- If `progress.md` is missing: report "No iterations logged yet"
- If git is not available: skip git-related fields
