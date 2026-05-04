---
description: Rich status dashboard showing current phase, task progress, session history,
  and health signals for the active autonomous run
---


<!-- Extension: pro -->
<!-- Config: .specify/extensions/pro/ -->
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
3. If no feature is found, output: `[Pro] No active feature found. Run /speckit.pro.run <description> to start.`

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
║  • /speckit.pro.resume — continue the autonomous loop        ║
║  • /speckit.pro.checkpoint — save a manual checkpoint        ║
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