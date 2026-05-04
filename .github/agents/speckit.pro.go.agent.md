---
description: 'Full autonomous SDD pipeline: specify → clarify → plan → tasks → analyze
  → implement with configurable human gates'
---


<!-- Extension: pro -->
<!-- Config: .specify/extensions/pro/ -->
# SpecKit Pro — Autonomous Pipeline Runner

Run the complete Spec-Driven Development pipeline autonomously from specification to implementation. Each phase can be gated (wait for human review) or autonomous (proceed automatically) via `pro-config.yml`.

## User Input

```text
$ARGUMENTS
```

The arguments are passed as the feature description to `/speckit.specify`. If empty, you must ask the user for a feature description before proceeding.

## Pre-Flight Checks

1. Load config from `.specify/extensions/pro/pro-config.yml` (fall back to defaults if missing):
   - `gates.after_specify` (default: `true`)
   - `gates.after_plan` (default: `true`)
   - `gates.after_clarify` (default: `false`)
   - `gates.after_tasks` (default: `false`)
   - `gates.after_analyze` (default: `false`)
   - `quality.run_clarify` (default: `true`)
   - `quality.run_analyze` (default: `true`)
   - `loop.max_iterations` (default: `20`)
   - `loop.checkpoint_frequency` (default: `3`)
   - `model` (default: `claude-sonnet-4.6`)
   - `agent_cli` (default: `copilot`)

2. Display the run plan to the user before proceeding:

   ```
   ┌─────────────────────────────────────────────────────┐
   │  SpecKit Pro — Autonomous Pipeline                  │
   ├─────────────────────────────────────────────────────┤
   │  Phases:                                            │
   │  1. specify       gate: [YES/NO]                    │
   │  2. clarify       gate: [YES/NO]  skip: [YES/NO]    │
   │  3. plan          gate: [YES/NO]                    │
   │  4. tasks         gate: [YES/NO]                    │
   │  5. analyze       gate: [YES/NO]  skip: [YES/NO]    │
   │  6. implement     loop: max N iterations            │
   ├─────────────────────────────────────────────────────┤
   │  Model: <model>  |  Agent CLI: <agent_cli>          │
   └─────────────────────────────────────────────────────┘
   ```

3. Confirm with the user: "Proceed with this pipeline configuration? (yes/no)"
   - If no: abort with message "Pipeline cancelled. Run `/speckit.pro.run <description>` to start again."

## Phase Execution Protocol

For **each phase** below, follow this pattern:

**A. Announce the phase**:
```
═══════════════════════════════════════════
  SpecKit Pro │ Phase N/6: <PHASE_NAME>
  Started: <timestamp>
═══════════════════════════════════════════
```

**B. Execute the phase command** (using the appropriate agent handoff or EXECUTE_COMMAND).

**C. Update session state** by appending to the session file (see Session Tracking below).

**D. Apply gate logic**:
- If `gates.after_<phase>` is `true`: pause and ask "Phase complete. Review and type `proceed` to continue or `abort` to stop."
- If `gates.after_<phase>` is `false`: automatically continue to the next phase.

## Pipeline Phases

### Phase 1: Specify

```
EXECUTE_COMMAND: speckit.specify
ARGUMENTS: <feature description from $ARGUMENTS>
```

After completion:
- Note the feature directory created (e.g., `specs/001-feature-name/`)
- Apply gate: `gates.after_specify`

### Phase 2: Clarify (conditional)

If `quality.run_clarify` is `false`, skip this phase with a note: `[Pro] Skipping clarify (disabled in config)`.

```
EXECUTE_COMMAND: speckit.clarify
```

After completion:
- Apply gate: `gates.after_clarify`

### Phase 3: Plan

```
EXECUTE_COMMAND: speckit.plan
ARGUMENTS: <any tech stack details from user input, if provided>
```

After completion:
- Apply gate: `gates.after_plan`

### Phase 4: Tasks

```
EXECUTE_COMMAND: speckit.tasks
```

After completion:
- Apply gate: `gates.after_tasks`

### Phase 5: Analyze (conditional)

If `quality.run_analyze` is `false`, skip this phase with a note: `[Pro] Skipping analyze (disabled in config)`.

```
EXECUTE_COMMAND: speckit.analyze
```

After completion:
- Apply gate: `gates.after_analyze`
- If analyze found critical issues, pause and ask the user even if gate is disabled

### Phase 6: Implement (Autonomous Loop)

This is the long-running autonomous phase. Use the orchestrator script:

**Bash (macOS/Linux)**:
```bash
.specify/extensions/pro/scripts/bash/pro-orchestrate.sh \
  --feature-name "<FEATURE_DIR_NAME>" \
  --tasks-path "<FEATURE_DIR>/tasks.md" \
  --spec-dir "<FEATURE_DIR>" \
  --max-iterations <loop.max_iterations> \
  --checkpoint-frequency <loop.checkpoint_frequency> \
  --model "<model>" \
  --agent-cli "<agent_cli>"
```

**PowerShell (Windows)**:
```powershell
.specify\extensions\pro\scripts\powershell\pro-orchestrate.ps1 `
  -FeatureName "<FEATURE_DIR_NAME>" `
  -TasksPath "<FEATURE_DIR>\tasks.md" `
  -SpecDir "<FEATURE_DIR>" `
  -MaxIterations <loop.max_iterations> `
  -CheckpointFrequency <loop.checkpoint_frequency> `
  -Model "<model>" `
  -AgentCli "<agent_cli>"
```

After the loop exits:
- Exit code `0`: All tasks complete → show success summary
- Exit code `1`: Max iterations or failures → show status, offer to resume
- Exit code `130`: User interrupted → show status, offer to resume

## Session Tracking

Maintain a session file at `<FEATURE_DIR>/session.md`. On each phase transition, append:

```markdown
## Session Entry — <ISO timestamp>

- **Phase**: <phase_name>
- **Status**: started | completed | skipped | failed
- **Gate**: applied | bypassed
- **Notes**: <any relevant notes>
```

If the session file does not exist, create it from the template at `.specify/extensions/pro/templates/session-template.md`.

## Completion Summary

When all phases complete, output:

```
╔═══════════════════════════════════════════════════════╗
║  SpecKit Pro — Pipeline Complete ✓                    ║
╠═══════════════════════════════════════════════════════╣
║  Feature:    <feature name>                           ║
║  Branch:     <git branch>                            ║
║  Duration:   <total time>                             ║
║                                                       ║
║  Phases completed:                                    ║
║    ✓ specify  ✓ clarify  ✓ plan                       ║
║    ✓ tasks    ✓ analyze  ✓ implement                  ║
╚═══════════════════════════════════════════════════════╝

Next steps:
- Review implementation: git diff main
- Run tests if available
- Create PR: /speckit.taskstoissues or gh pr create
```

## Error Handling

- **Phase failure**: Log to session.md, ask user whether to retry, skip, or abort
- **Gate timeout**: If waiting for human input for >5 minutes (in CI context), apply gate based on `autonomous.enabled` setting
- **Script not found**: Fall back to agent-based implementation using `/speckit.implement`

## Graceful Degradation

If the orchestrator script is not available (e.g., fresh install without scripts):
- Fall back to standard SpecKit commands: run each phase as an agent handoff
- Continue with manual `/speckit.implement` for the implement phase
- Note the degradation in session.md