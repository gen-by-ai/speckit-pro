---
name: speckit-pro-resume
description: Resume an interrupted autonomous run from the last saved session checkpoint
  — reads session state and continues from the correct phase
compatibility: Requires spec-kit project structure with .specify/ directory
metadata:
  author: github-spec-kit
  source: pro:commands/speckit.pro.resume.md
---

# SpecKit Pro — Resume

Resume an interrupted SpecKit Pro autonomous run. Reads `session.md` to determine where the pipeline stopped and continues from that point.

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
2. Load `<FEATURE_DIR>/session.md` to determine last known state.
3. Load `<FEATURE_DIR>/progress.md` to understand iteration history.

If no `session.md` exists:
```
[Pro] No session state found.
• To start a new pipeline: /speckit.pro.run <description>
• To resume the implement loop only: /speckit.pro.loop feature=<name> tasks=<path> ...
```

## Session Analysis

Parse `session.md` to find:
- Last completed phase
- Last phase status (completed / failed / in_progress)
- Current iteration (if in implement loop)
- Any blocked tasks noted

Display the resume plan:

```
╔══════════════════════════════════════════════════════╗
║  SpecKit Pro — Resume                                ║
╠══════════════════════════════════════════════════════╣
║  Feature:        <feature name>                      ║
║  Last phase:     <phase> (<status>)                  ║
║  Resuming from:  <next phase or implement loop>      ║
║  Loop iteration: <N> / <max>  (if in implement)      ║
╚══════════════════════════════════════════════════════╝

Confirm resume? (yes/no)
```

## Resume Logic

### If interrupted during implement loop (most common):

Check tasks.md for remaining work:
- If all tasks done: output success summary, no action needed
- If tasks remain: restart the orchestrator script:

**Bash**:
```bash
.specify/extensions/pro/scripts/bash/pro-orchestrate.sh \
  --feature-name "<FEATURE_DIR_NAME>" \
  --tasks-path "<FEATURE_DIR>/tasks.md" \
  --spec-dir "<FEATURE_DIR>" \
  --resume \
  --max-iterations <remaining_iterations> \
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
  -MaxIterations <remaining_iterations> `
  -CheckpointFrequency <checkpoint_freq> `
  -Model "<model>" `
  -AgentCli "<agent_cli>"
```

### If interrupted during a pipeline phase:

Resume from the correct phase using the same phase execution protocol as `/speckit.pro.run`:

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

## Session State Update

After resuming, append to `session.md`:

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