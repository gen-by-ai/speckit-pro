---
description: 'Create a named checkpoint: commit all changes, save session snapshot,
  and log a rich progress entry — safe to call at any time during a run'
---


<!-- Extension: pro -->
<!-- Config: .specify/extensions/pro/ -->
# SpecKit Pro — Checkpoint

Create a named checkpoint that saves the current state of the autonomous run. Safe to call manually at any time, or automatically as a hook.

## User Input

```text
$ARGUMENTS
```

Optional:
- A checkpoint label (e.g., `after-auth-module`) — used in the commit message and session log
- If empty, an automatic label is generated from the current phase/iteration

## Detection

1. Run `.specify/scripts/bash/check-prerequisites.sh --json` to detect `FEATURE_DIR` (if available).
2. Load config from `.specify/extensions/pro/pro-config.yml` for checkpoint settings.
3. Detect current git branch: `git rev-parse --abbrev-ref HEAD 2>/dev/null`

## Checkpoint Actions

### 1. Parse current state

- Read `<FEATURE_DIR>/tasks.md`: count completed/total tasks
- Read `<FEATURE_DIR>/session.md`: get current phase
- Read `<FEATURE_DIR>/progress.md`: get iteration number (last entry)
- List modified files: `git status --short`

### 2. Generate checkpoint label

If `$ARGUMENTS` provides a label, use it. Otherwise auto-generate:
- Format: `<phase>-iter<N>-<completed>of<total>`
- Example: `implement-iter6-28of45`

### 3. Stage and commit

```bash
git add .
git commit -m "[Pro] Checkpoint: <label> (<completed>/<total> tasks, phase: <phase>)"
```

If there are no changes to commit: output `[Pro] Checkpoint skipped — no uncommitted changes.` and continue.

### 4. Append checkpoint entry to session.md

```markdown
## Checkpoint — <ISO timestamp>

- **Label**: <label>
- **Commit**: <git commit hash>
- **Phase**: <current phase>
- **Tasks**: <completed>/<total> (<percentage>%)
- **Files snapshotted**: <list of modified files>
- **Triggered by**: <manual | hook | orchestrator>
```

### 5. Append to progress.md

```markdown
### Checkpoint ✓ — <label>
Commit: `<hash>` | <ISO timestamp>
State saved: <completed>/<total> tasks complete.
```

## Output

```
[Pro] Checkpoint created ✓
  Label:   <label>
  Commit:  <short hash>
  Tasks:   <completed>/<total> (<percentage>%)
  Phase:   <current phase>

To resume from this checkpoint: /pro.resume
To view status:                 /pro.status
```

## Graceful Degradation

- If git is not available or directory is not a repo: skip the commit step, still log to session.md
- If FEATURE_DIR is not found: create a project-level checkpoint (commit all changes with generic message)
- If session.md does not exist: create it from the template before appending