---
description: "Resume an interrupted autonomous run from durable artifacts (session.md optional) — derives the correct phase and remaining iteration budget deterministically and continues from that point"
---

# SpecKit Pro — Resume

Resume an interrupted SpecKit Pro autonomous run. State is derived from durable artifacts (spec.md, plan.md, tasks.md, contracts, progress.md) by a deterministic detector — `session.md` is optional enrichment, never a prerequisite.

## User Input

```text
$ARGUMENTS
```

Optional:
- `--feature <name>` — specify which feature to resume (default: auto-detect)
- `--from <phase>` — force resume from a specific phase (overrides session state)
- `--skip-gate` — bypass the gate confirmation for the resumed phase

## Detection

1. Run `.specify/scripts/bash/check-prerequisites.sh --json` to detect `FEATURE_DIR`.
2. Run the deterministic detector and **trust its output**:

   ```bash
   PRO_SCRIPTS="$(git rev-parse --show-toplevel)/.specify/extensions/pro/scripts/bash"
   [ -f "$PRO_SCRIPTS/pro-resume-detect.sh" ] || PRO_SCRIPTS="$(git rev-parse --show-toplevel)/scripts/bash"
   bash "$PRO_SCRIPTS/pro-resume-detect.sh" --feature <slug> [--max-iterations <N from config>]
   ```

   The detector prints `KEY=VALUE` lines:
   - `PHASE` — one of `none|spec-only|plan-only|tasks-only|contracts-ready|in-loop|complete`
   - `NEXT` — the suggested command
   - `ITER_LAST` — last completed loop iteration
   - `REMAINING` — remaining iteration budget
   - zero or more `WARNING=` lines (e.g. a stale `handoff.md` naming a different feature, or `tasks.md` modified after the last checkpoint)
3. `session.md` and `progress.md` are **optional enrichment** — when present, load them to display history in the resume banner; their absence MUST NOT block resume. If `session.md` is missing, print one line and continue:

   ```
   [Pro] session.md absent — state derived from artifacts (this is normal after an interrupted run).
   ```

### Phase decision table

The detector's `PHASE` maps to a resume action as follows — this mapping is explicit, never guess:

| Artifacts present | PHASE | Resume action |
|---|---|---|
| no spec.md | none | `/pro.go <description>` (nothing to resume) |
| spec.md only | spec-only | continue at `/speckit.plan` |
| + plan.md | plan-only | continue at `/speckit.tasks` |
| + tasks.md, no contracts | tasks-only | `/pro.contract` then the implement loop |
| + `.knowledge/features/<slug>/contracts/` | contracts-ready | implement loop, iteration 1 |
| + progress.md with `## Iteration N` entries | in-loop | implement loop at iteration N+1 with remaining budget = max_iterations − N |
| tasks.md fully `[x]` | complete | Phase 7/8 wrap-up (reconcile → evaluate → report) only if not yet evaluated |

## Session Analysis

The banner is driven by the detector output. When `session.md` / `progress.md` exist, additionally parse them to enrich the display with:
- Last completed phase and status (completed / failed / in_progress)
- Iteration history
- Any blocked tasks noted

Display the resume plan:

```
╔══════════════════════════════════════════════════════╗
║  SpecKit Pro — Resume                                ║
╠══════════════════════════════════════════════════════╣
║  Feature:        <feature name>                      ║
║  Phase:          <PHASE>                             ║
║  Resuming from:  <NEXT>                              ║
║  Loop iteration: <ITER_LAST+1> / <max>  (if in-loop) ║
║  Remaining:      <REMAINING> iterations (if in-loop) ║
║  Source:         artifacts (detector)                ║
╚══════════════════════════════════════════════════════╝
⚠ <each WARNING= line from the detector, verbatim>

Confirm resume? (yes/no)
```

## Resume Logic

### If interrupted during implement loop (most common):

Check tasks.md for remaining work:
- If all tasks done: run **`pro.go.md` Phase 7** (post-implement) — do not stop at implement-complete:
  ```
  EXECUTE_COMMAND: /pro.reconcile
  EXECUTE_COMMAND: /pro.local-review
  EXECUTE_COMMAND: /pro.evaluate
  EXECUTE_COMMAND: /pro.knowledge-sync
  ```
  Run knowledge-sync only after evaluator **PASS** (`knowledge.sync_after_evaluate: true`).
- If tasks remain: restart the orchestrator script (each iteration still primes per `pro.loop.md` step 0 when enabled).

**Remaining-iterations rule**: total iterations across all sessions MUST NOT exceed `loop.max_iterations`. The loop resumes at iteration `ITER_LAST+1` and runs at most `REMAINING` further iterations — both values come from the detector. When invoking the orchestrator script, pass `--max-iterations <REMAINING>`.

**Bash**:
```bash
.specify/extensions/pro/scripts/bash/pro-orchestrate.sh \
  --feature-name "<FEATURE_DIR_NAME>" \
  --tasks-path "<FEATURE_DIR>/tasks.md" \
  --spec-dir "<FEATURE_DIR>" \
  --resume \
  --max-iterations <REMAINING> \
  --checkpoint-frequency <checkpoint_freq> \
  --model "<model>" \
  --agent-cli "<agent_cli>"
```

**PowerShell**:
```powershell
.specify\extensions\pro\scripts\powershell\pro-orchestrate.ps1 `
  -FeatureName "<FEATURE_DIR_NAME>" `
  -TasksPath "<FEATURE_DIR>\tasks.md" `
  -SpecDir "<FEATURE_DIR>" `
  -Resume `
  -MaxIterations <REMAINING> `
  -CheckpointFrequency <checkpoint_freq> `
  -Model "<model>" `
  -AgentCli "<agent_cli>"
```

### If interrupted during a pipeline phase:

Resume from the correct phase using the same phase execution protocol as `/pro.go` (including knowledge prime at Phase 0, 2.5, 4, 5a, and Phase 7 after implement when complete):

- `specify`: EXECUTE_COMMAND speckit.specify
- `clarify`: EXECUTE_COMMAND speckit.clarify
- `plan`: EXECUTE_COMMAND speckit.plan
- `tasks`: EXECUTE_COMMAND speckit.tasks
- `analyze`: EXECUTE_COMMAND speckit.analyze

Then continue with subsequent phases.

### Blocked task recovery

If `progress.md` or `tasks.md` contains `<!-- BLOCKED:` entries:
1. Show the blocked tasks to the user
2. Ask: "These tasks were blocked in the previous run. How should we handle them? (retry / skip / resolve-manually)"
3. If retry: proceed normally — the agent will re-attempt
4. If skip: mark blocked tasks as `- [x] (skipped)` with a note
5. If resolve-manually: pause and wait for user to edit `tasks.md`

## Consistency Checks

- Every `WARNING=` line from the detector MUST be surfaced in the resume banner.
- A stale `handoff.md` naming a different feature is **ignored** — the loop falls back to progress.md + tasks.md context.
- If tasks.md changed after the last checkpoint commit: note it in the banner and continue — the detector's verdict is the most conservative valid entry point. Never guess silently.

## Session State Update

After resuming, append to `session.md` (create it if absent):

```markdown
## Session Entry — <ISO timestamp>

- **Phase**: <resumed_phase>
- **Status**: resumed
- **Gate**: bypassed (resume)
- **Notes**: Resumed from iteration <N>. Remaining tasks: <count>.
```

## Graceful Degradation

- If `--from <phase>` is specified but that phase's prerequisites are missing: warn but proceed
- If the orchestrator script is missing: fall back to `/speckit.implement` agent command
- If git is not available: skip checkpoint restoration
