<div align="center">
  <h1>⚡ SpecKit Pro</h1>
  <h3><em>SpecKit on steroids — built for long autonomous work.</em></h3>
</div>

<p align="center">
  <a href="https://github.com/github/spec-kit"><img src="https://img.shields.io/badge/Built%20on-Spec%20Kit-blue" alt="Built on Spec Kit"/></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-MIT-green" alt="MIT License"/></a>
  <img src="https://img.shields.io/badge/SpecKit-%3E%3D0.8.0-orange" alt="SpecKit >=0.8.0"/>
</p>

---

**SpecKit Pro** is a [Spec Kit](https://github.com/github/spec-kit) extension that supercharges the SDD workflow for long, autonomous AI-driven development sessions. It adds a full pipeline orchestrator, a self-healing implementation loop, session persistence, context compression, and rich observability — all while staying 100% on top of the standard SpecKit extension system.

## Why SpecKit Pro?

Standard SpecKit gives you powerful individual commands. SpecKit Pro wires them together for **hands-free, resumable, self-healing autonomous runs**:

| Standard SpecKit | SpecKit Pro |
|---|---|
| Each phase requires a manual command | Full pipeline in one command: `/speckit.pro.run` |
| Manual human gates between all phases | Configurable: gate per phase or fully autonomous |
| `/speckit.implement` runs one pass | Self-healing loop with circuit breaker and retry |
| Context grows unbounded over many iterations | Auto context compression at configurable thresholds |
| No session state — can't resume | Full session persistence → `/speckit.pro.resume` |
| No visibility into autonomous progress | Rich status dashboard → `/speckit.pro.status` |
| No cross-agent state handoff | `progress.md` + `session.md` carry state between iterations |

---

## Installation

### From GitHub (recommended)

```bash
specify extension add pro --from https://github.com/github/spec-kit-pro/archive/refs/tags/v1.0.0.zip
```

### From source (local dev)

```bash
git clone https://github.com/github/spec-kit-pro
cd my-project
specify extension add --dev /path/to/spec-kit-pro
```

### Verify

```bash
specify extension list
# ✓ SpecKit Pro (v1.0.0)
#   Autonomous long-run orchestration
#   Commands: 6 | Hooks: 1 | Status: Enabled
```

---

## Quick Start

### Option A: Full Autonomous Pipeline

Run the complete SDD cycle from description to implementation:

```
/speckit.pro.run Build a REST API for managing todo items with user authentication, PostgreSQL backend, and JWT tokens
```

SpecKit Pro will:
1. Create spec (with human gate to review)
2. Clarify underspecified areas (auto)
3. Generate plan (with human gate to review)
4. Generate tasks (auto)
5. Run cross-artifact analysis (auto)
6. Implement autonomously with progress tracking, checkpoints, and self-healing

### Option B: Autonomous Implementation Loop Only

If you've already done specify → plan → tasks with standard SpecKit:

```
/speckit.pro.loop feature=001-my-feature tasks=specs/001-my-feature/tasks.md spec-dir=specs/001-my-feature iteration=1 max=20
```

Or run the orchestrator script directly:

```bash
.specify/extensions/pro/scripts/bash/pro-orchestrate.sh \
  --feature-name "001-my-feature" \
  --tasks-path "specs/001-my-feature/tasks.md" \
  --spec-dir "specs/001-my-feature" \
  --max-iterations 20
```

---

## Commands

### Core Commands

| Command | Description |
|---|---|
| `/speckit.pro.run` | Full autonomous SDD pipeline with configurable gates |
| `/speckit.pro.loop` | Single autonomous iteration (loop worker) |
| `/speckit.pro.status` | Rich status dashboard |
| `/speckit.pro.resume` | Resume an interrupted run |
| `/speckit.pro.checkpoint` | Create a named checkpoint (commit + session log) |
| `/speckit.pro.compress` | Compress spec artifacts to reduce token usage |

### Aliases

- `/speckit.pro.go` → same as `/speckit.pro.run`

---

## Configuration

After installation, edit `.specify/extensions/pro/pro-config.yml`:

```yaml
# Human review gates (true = wait for approval, false = auto-proceed)
gates:
  after_specify: true   # Review the spec
  after_plan: true      # Review the plan
  after_clarify: false  # Auto-proceed
  after_tasks: false
  after_analyze: false
  after_implement: false

# Quality steps
quality:
  run_clarify: true     # Auto-run /speckit.clarify after specify
  run_analyze: true     # Auto-run /speckit.analyze before implement
  require_checklist: false

# Autonomous loop
loop:
  max_iterations: 20
  max_consecutive_failures: 3
  checkpoint_frequency: 3   # Commit every N iterations

# Context compression
context:
  auto_compress: false
  compression_threshold: 5  # Switch to context-summary.md after N iterations

# Model & agent
model: "claude-sonnet-4.6"
agent_cli: "copilot"        # copilot | claude | gemini | codex
```

### Environment Variable Overrides

```bash
export SPECKIT_PRO_MODEL="gpt-4.1"
export SPECKIT_PRO_MAX_ITERATIONS="30"
export SPECKIT_PRO_AGENT_CLI="claude"
```

---

## How the Loop Works

```
┌─────────────────────────────────────────────────────────┐
│  pro-orchestrate.sh starts                              │
│  load config, resolve agent CLI, init progress.md       │
└───────────────────────────┬─────────────────────────────┘
                            ▼
              ┌─────────────────────────┐
              │  Any tasks remaining?   │──No──▶ exit 0 ✓
              └──────────┬──────────────┘
                         │ Yes
                         ▼
          ┌──────────────────────────────────┐
          │  Spawn agent: speckit.pro.loop   │
          │  Reads: tasks.md + progress.md   │
          │  Implements ONE work unit        │
          │  Updates tasks.md + progress.md  │
          │  Outputs: <pro-status>TAG</pro-status>     │
          └──────────────┬───────────────────┘
                         ▼
          ┌──────────────────────────────────┐
          │  Parse status tag                │
          │  COMPLETE → exit 0 ✓             │
          │  CONTINUE → next iteration       │
          │  BLOCKED  → increment counter    │
          │  ERROR    → circuit breaker      │
          └──────────────┬───────────────────┘
                         │
          ┌──────────────▼──────────────┐
          │  Every N iterations:        │
          │  git add . && git commit    │
          │  (checkpoint)               │
          └─────────────────────────────┘
                         │
                  back to top
```

### Termination Conditions

| Condition | Exit Code | Action |
|---|---|---|
| All tasks `[x]` | `0` | Success — final checkpoint commit |
| Agent outputs `COMPLETE` | `0` | Success — final checkpoint commit |
| Max iterations reached | `1` | Checkpoint + resume instructions |
| 3 consecutive failures | `1` | Circuit breaker — checkpoint + error log |
| Ctrl+C | `130` | Clean interrupt — resume with `/speckit.pro.resume` |

---

## Session Persistence

SpecKit Pro maintains two tracking files in your feature spec directory:

**`session.md`** — Pipeline phase state:
```markdown
## Session Entry — 2026-05-04T10:30:00Z
- Phase: implement
- Status: in_progress
- Gate: bypassed
- Notes: Autonomous loop iteration 7
```

**`progress.md`** — Iteration-by-iteration log:
```markdown
## Iteration 7 — 2026-05-04T10:30:00Z

Work Unit: Phase 3 — User Authentication
Tasks completed: 4
Cumulative progress: 28/45 tasks (62%)
Files modified: src/auth/jwt.py, src/auth/middleware.py ...

Summary: Implemented JWT token generation and validation middleware...
```

These files allow `/speckit.pro.resume` to pick up exactly where you left off after any interruption.

---

## Context Compression

For long feature implementations (many tasks, complex specs), run:

```
/speckit.pro.compress
```

This creates `context-summary.md` — a compressed handoff document (~90% fewer tokens) that the loop worker automatically uses after `compression_threshold` iterations.

Estimated savings: `spec.md (4k) + plan.md (3k) + tasks.md (2k) + progress.md (3k)` → `context-summary.md (~1k)`

---

## Supported Agent CLIs

SpecKit Pro auto-detects your installed agent CLI. Supported:

| CLI | Install | Notes |
|---|---|---|
| `copilot` | [GitHub Copilot CLI](https://docs.github.com/en/copilot) | Default |
| `claude` | [Claude Code](https://claude.ai/code) | Full support |
| `gemini` | [Gemini CLI](https://ai.google.dev) | Full support |
| `codex` | [OpenAI Codex CLI](https://github.com/openai/codex) | Full support |

---

## Extension Structure

```
spec-kit-pro/
├── extension.yml                    # Extension manifest (SpecKit schema v1.0)
├── commands/
│   ├── speckit.pro.run.md           # Full autonomous pipeline
│   ├── speckit.pro.loop.md          # Single iteration worker
│   ├── speckit.pro.status.md        # Status dashboard
│   ├── speckit.pro.resume.md        # Resume interrupted run
│   ├── speckit.pro.checkpoint.md    # Named checkpoint
│   └── speckit.pro.compress.md      # Context compression
├── scripts/
│   ├── bash/
│   │   ├── pro-orchestrate.sh       # Main loop orchestrator (macOS/Linux)
│   │   ├── pro-status.sh            # Status reporter
│   │   └── pro-checkpoint.sh        # Checkpoint helper
│   └── powershell/
│       └── pro-orchestrate.ps1      # Main loop orchestrator (Windows)
├── agents/
│   └── speckit.pro.loop.agent.md    # Loop worker agent profile
├── templates/
│   ├── session-template.md          # Session state template
│   └── progress-template.md         # Progress log template
├── pro-config.template.yml          # Configuration template
├── README.md
├── CHANGELOG.md
└── .extensionignore                 # Distribution exclusions
```

---

## Best Practices for Long Autonomous Runs

1. **Always use the constitution first** — `/speckit.constitution` ensures the agent has firm guardrails for the entire run.

2. **Set `gates.after_plan: true`** — Review the technical plan before letting the loop run unattended. One bad architectural decision can cascade.

3. **Start with `max_iterations: 10`** — Increase after your first successful run. Better to resume than to let a stuck agent loop forever.

4. **Use `checkpoint_frequency: 3`** — Frequent checkpoints make recovery cheap. Each checkpoint is a git commit you can `git reset` to.

5. **Enable context compression for large features** — Set `context.auto_compress: true` for features with >30 tasks.

6. **Monitor with `/speckit.pro.status`** — Run this in a separate terminal window during autonomous runs.

7. **Use `--verbose` for debugging** — `/speckit.pro.status --verbose` shows the full iteration log.

---

## Contributing

SpecKit Pro is built on the [Spec Kit extension system](https://github.com/github/spec-kit/blob/main/extensions/EXTENSION-DEVELOPMENT-GUIDE.md). Contributions welcome — see [CONTRIBUTING.md](CONTRIBUTING.md).

## License

MIT © spec-kit-pro contributors. See [LICENSE](LICENSE).

Built on [GitHub Spec Kit](https://github.com/github/spec-kit) — MIT License.
