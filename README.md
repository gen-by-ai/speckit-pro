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

**SpecKit Pro** is a [Spec Kit](https://github.com/github/spec-kit) extension that turns SpecKit into an overnight, hands-off coding engine.

The core idea: native SpecKit gives you great individual commands — `specify`, `plan`, `tasks`, `implement`. SpecKit Pro wires them into a **self-healing autonomous loop** you can start, walk away from, and come back to a finished feature. It implements the patterns Anthropic found essential for long autonomous runs: a separate evaluator agent (so the agent can't grade its own work), sprint contracts negotiated before coding starts, per-sprint context resets via `handoff.md` (so context anxiety never accumulates), a living `AGENT.md` that the loop writes to itself as it learns about the project, and live browser testing of the running app — not just source code review.

It hooks into native SpecKit rather than replacing it, so upstream improvements to `speckit.plan` or `speckit.implement` benefit you automatically.

## Why SpecKit Pro?

Standard SpecKit gives you powerful individual commands. SpecKit Pro wires them together for **hands-free, resumable, self-healing autonomous runs**:

| Standard SpecKit | SpecKit Pro |
|---|---|
| Each phase requires a manual command | Full pipeline in one command: `/speckit.pro.go` |
| Manual human gates between all phases | Configurable: gate per phase or fully autonomous |
| `/speckit.implement` runs one pass | Self-healing loop with circuit breaker and retry |
| No quality gate between tasks and implement | Sprint contracts auto-generated via `after_tasks` hook |
| No independent QA — agent grades its own work | Separate evaluator agent via `after_implement` hook |
| Evaluator reads code statically | Evaluator uses **agent-browser** to click through the live running app |
| Context grows unbounded over many iterations | Per-sprint `handoff.md` resets context cleanly |
| No project memory across context windows | `AGENT.md` — loop writes its own learnings each iteration |
| No pre-flight sanity check | `init.sh` smoke-tests the app before each new work unit |
| No session state — can't resume | Full session persistence → `/speckit.pro.resume` |
| No visibility into autonomous progress | Rich status dashboard → `/speckit.pro.status` |

---

## Installation

### From GitHub (recommended)

```bash
specify extension add pro --from https://github.com/gen-by-ai/speckit-pro/archive/refs/tags/v1.3.0.zip
```

### From source (local dev)

```bash
git clone https://github.com/gen-by-ai/speckit-pro
cd my-project
specify extension add --dev /path/to/spec-kit-pro
```

### Verify

```bash
specify extension list
# ✓ SpecKit Pro (v1.3.0)
#   Autonomous long-run orchestration
#   Commands: 8 | Hooks: 2 | Status: Enabled
```

---

## Quick Start

### Option A: Full Autonomous Pipeline

Run the complete SDD cycle from description to implementation:

```
/speckit.pro.go Build a REST API for managing todo items with user authentication, PostgreSQL backend, and JWT tokens
```

SpecKit Pro will:
1. Run `/speckit.specify` (gate: review spec)
2. Run `/speckit.clarify` (auto)
3. Run `/speckit.plan` (gate: review plan)
4. Run `/speckit.tasks` → `after_tasks` hook auto-generates sprint contract
5. Run `/speckit.analyze` (auto)
6. Run the implement loop → `after_implement` hook auto-runs evaluator

### Option B: Native Commands + Pro Hooks

Run native SpecKit commands as normal — Pro hooks fire automatically:

```
/speckit.tasks          # generates tasks.md
                        # → speckit.pro.contract fires automatically

/speckit.implement      # implements the feature
                        # → speckit.pro.evaluate fires automatically
```

### Option C: Implementation Loop Only

If you've already done specify → plan → tasks:

```bash
.specify/extensions/pro/scripts/bash/pro-orchestrate.sh \
  --feature-name "001-my-feature" \
  --tasks-path "specs/001-my-feature/tasks.md" \
  --spec-dir "specs/001-my-feature" \
  --max-iterations 20
```

---

## Commands

### Entry Point

| Command | Description |
|---|---|
| `/speckit.pro.go` | Full pipeline: invokes native SpecKit commands in sequence with Pro gates |

### Hook Commands (also callable manually)

| Command | Fires automatically | Description |
|---|---|---|
| `/speckit.pro.contract` | after `/speckit.tasks` | Generate sprint contract — concrete acceptance criteria before coding |
| `/speckit.pro.evaluate` | after `/speckit.implement` | Strict QA evaluation: calibrates against past sprint scores, then drives the live app with **agent-browser** to test every CRITICAL criterion |
| `/speckit.pro.checkpoint` | manual | Commit + session snapshot + progress log entry |

### Loop & Observability

| Command | Description |
|---|---|
| `/speckit.pro.loop` | Single autonomous iteration (invoked by orchestrator script) |
| `/speckit.pro.status` | Rich status dashboard with phase icons and task progress bar |
| `/speckit.pro.resume` | Resume an interrupted run from last session checkpoint |
| `/speckit.pro.compress` | Write `handoff.md` — clean context reset for the next sprint |

### Alias

- `/speckit.pro.run` → same as `/speckit.pro.go`

---

## Configuration

After installation, edit `.specify/extensions/pro/pro-config.yml`:

```yaml
# Human review gates (true = wait for approval, false = auto-proceed)
gates:
  after_specify: true   # Review the spec
  after_plan: true      # Review the plan
  after_clarify: false  # Auto-proceed
  after_tasks: false    # Contract generated automatically via hook
  after_analyze: false

# Quality steps
quality:
  run_clarify: true     # Auto-run /speckit.clarify after specify
  run_analyze: true     # Auto-run /speckit.analyze before implement
  run_checklist: false

# Generator/evaluator split (Anthropic harness pattern)
evaluation:
  enabled: true         # Fire speckit.pro.evaluate after implement
  threshold: 70         # Minimum score (0-100) for PASS
  max_revisions: 2      # Generator revision passes before moving on
  sprint_contracts: true

# Autonomous loop
loop:
  max_iterations: 20
  max_consecutive_failures: 3
  checkpoint_frequency: 3   # Commit every N iterations

# Context resets (not just compression)
context:
  reset_mode: true      # Write handoff.md per sprint for clean context resets
  compression_threshold: 5

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
┌──────────────────────────────────────────────────────────────┐
│  pro-orchestrate.sh starts                                   │
│  load config, resolve agent CLI, init progress.md            │
└────────────────────────────┬─────────────────────────────────┘
                             ▼
               ┌─────────────────────────┐
               │  Any tasks remaining?   │──No──▶ exit 0 ✓
               └──────────┬──────────────┘
                          │ Yes
                          ▼
         ┌────────────────────────────────────┐
         │  Load sprint contract              │
         │  contracts/sprint-N.md             │
         │  (generated by speckit.pro.contract│
         │   via after_tasks hook)            │
         └──────────────┬─────────────────────┘
                        ▼
         ┌──────────────────────────────────────┐
         │  GENERATOR: speckit.pro.loop         │
         │  1. Read AGENT.md (project memory)   │
         │  2. Run init.sh smoke test           │
         │  3. Load handoff.md (context reset)  │
         │  4. Implement ONE work unit          │
         │     against contract criteria        │
         │  5. Update tasks.md + progress.md    │
         │  6. Write next handoff.md            │
         │  7. Update AGENT.md with learnings   │
         │  Outputs: <pro-status>TAG</pro-status>          │
         └──────────────┬───────────────────────┘
                        ▼
         ┌──────────────────────────────────────┐
         │  EVALUATOR: speckit.pro.evaluate     │
         │  Fresh agent — no generator context  │
         │  1. Calibrate vs past sprint scores  │
         │  2. Start app via init.sh            │
         │  3. agent-browser: click every       │
         │     CRITICAL criterion live          │
         │  4. Static code review               │
         │  PASS → continue                     │
         │  NEEDS_REVISION → generator retries  │
         │  FAIL → human review required        │
         └──────────────┬───────────────────────┘
                        ▼
         ┌──────────────────────────────────────┐
         │  Parse generator status tag          │
         │  COMPLETE → exit 0 ✓                 │
         │  CONTINUE → next sprint              │
         │  BLOCKED  → increment counter        │
         │  ERROR    → circuit breaker          │
         └──────────────┬───────────────────────┘
                        │
         ┌──────────────▼──────────────┐
         │  Every N iterations:        │
         │  git add . && git commit    │
         │  (speckit.pro.checkpoint)   │
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

**`contracts/sprint-N.md`** — Sprint contract (auto-generated by `speckit.pro.contract`):
```markdown
# Sprint Contract — Sprint 3

## Acceptance Criteria
| # | Criterion | Severity | How to Verify |
|---|---|---|---|
| 1 | POST /auth/login returns JWT on valid credentials | CRITICAL | curl test |
| 2 | Returns HTTP 401 for invalid password | CRITICAL | curl test |
| 3 | Token expires after configured TTL | MEDIUM | decode payload |
```

**`evaluations/sprint-N.md`** — Evaluator verdict (auto-generated by `speckit.pro.evaluate`):
```markdown
# Evaluation — Sprint 3
Verdict: PASS (score: 82/100)
CRITICAL: 2/2 pass  MEDIUM: 1/2 pass  LOW: 3/3 pass

## Browser Test Results (via agent-browser)
- POST /auth/login → navigated to /dashboard ✓
- Invalid password → 401 page shown ✓
```

**`AGENT.md`** — Project memory written by the loop (auto-generated, auto-updated):
```markdown
# Project Agent Notes

## How to Start the App
npm run dev   # starts on port 3000

## How to Run Tests
npm test -- --testPathPattern=src/auth

## Known Gotchas
- Must seed the DB before running auth tests: npm run db:seed

## Build Learnings
- `npm run build` fails if .env is missing — copy .env.example first
```

**`init.sh`** — Smoke test script (auto-generated by `pro.go`, run by loop before each work unit):
```bash
#!/usr/bin/env bash
set -e
npm install --silent
npm run build -- --check
echo "Smoke test: OK"
```

---

## Context Resets

Rather than compressing a growing context (which still causes "context anxiety" in long runs), Pro uses **clean resets**. At the end of each sprint the generator writes `handoff.md` — a lean, structured artifact the next sprint agent loads instead of accumulated history:

```
/speckit.pro.compress
```

This writes `handoff.md` with only what the next iteration needs:
- Current task state
- Relevant architectural decisions
- Blockers and open questions
- Files changed so far

The loop worker automatically loads `handoff.md` on iteration > 1, giving each sprint a clean slate.

Estimated token savings per sprint: `spec.md (4k) + plan.md (3k) + progress.md (3k)` → `handoff.md (~800 tokens)`

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
├── extension.yml                  # Extension manifest (SpecKit schema v1.0)
├── commands/
│   ├── pro.go.md                  # → /speckit.pro.go  — thin pipeline runner
│   ├── pro.contract.md            # → /speckit.pro.contract  — sprint contracts (after_tasks hook)
│   ├── pro.evaluate.md            # → /speckit.pro.evaluate  — QA evaluator with agent-browser (after_implement hook)
│   ├── pro.loop.md                # → /speckit.pro.loop  — single iteration worker with AGENT.md self-update
│   ├── pro.status.md              # → /speckit.pro.status  — status dashboard
│   ├── pro.resume.md              # → /speckit.pro.resume  — resume from checkpoint
│   ├── pro.checkpoint.md          # → /speckit.pro.checkpoint  — named checkpoint
│   └── pro.compress.md            # → /speckit.pro.compress  — context reset / handoff.md
├── scripts/
│   ├── bash/
│   │   ├── pro-orchestrate.sh     # Gen/eval loop orchestrator (macOS/Linux)
│   │   ├── pro-status.sh          # Status reporter
│   │   └── pro-checkpoint.sh      # Checkpoint helper
│   └── powershell/
│       └── pro-orchestrate.ps1    # Gen/eval loop orchestrator (Windows)
├── agents/
│   └── speckit.pro.loop.agent.md  # Loop worker agent profile
├── templates/
│   ├── session-template.md        # Session state template
│   ├── progress-template.md       # Progress log template
│   ├── contract-template.md       # Sprint contract template
│   └── handoff-template.md        # Context reset handoff template
├── pro-config.template.yml        # Configuration template
├── README.md
├── CHANGELOG.md
└── .extensionignore               # Distribution exclusions

# Generated per-feature (inside .specify/<feature-dir>/)
.specify/<feature>/
├── spec.md / plan.md / tasks.md   # Native SpecKit artifacts
├── init.sh                        # Auto-generated smoke test (run before every work unit)
├── AGENT.md                       # Loop's self-written project memory (grows each iteration)
├── handoff.md                     # Per-sprint context reset artifact
├── progress.md                    # Iteration log
├── session.md                     # Pipeline phase state
├── contracts/sprint-N.md          # Sprint contracts (one per sprint)
└── evaluations/sprint-N.md        # Evaluator verdicts with browser test results
```

---

## Best Practices for Long Autonomous Runs

1. **Always use the constitution first** — `/speckit.constitution` sets project-wide guardrails the agent respects for the entire run.

2. **Gate on plan, not tasks** — Set `gates.after_plan: true`. One bad architectural decision cascades through everything downstream; reviewing the plan is the highest-leverage gate.

3. **Trust the sprint contract** — The contract is generated before coding starts. If the evaluator fails a sprint, read the contract first — often the generator missed a criterion, not an implementation bug.

4. **Start with `max_iterations: 10`** — Increase after your first successful run. Circuit-breaker + `/speckit.pro.resume` make short limits safe.

5. **Each checkpoint is a `git reset` point** — Set `checkpoint_frequency: 3`. Recovery from a bad sprint costs at most 3 iterations of work.

6. **Context resets beat compression** — `handoff.md` gives each sprint a clean slate. Long runs with growing context produce worse code as the agent tries to reconcile accumulated history.

7. **Let `AGENT.md` accumulate — don't reset it** — It's the loop's persistent project memory. After a few sprints it contains hard-won learnings about your specific stack. Treat it like a good `CONTRIBUTING.md`.

8. **The evaluator uses agent-browser — your app must be startable** — `init.sh` is the key. If it exits non-zero, the evaluator marks all UI criteria FAIL. Keep it fast (under 30 seconds).

9. **Monitor with `/speckit.pro.status`** — Run in a separate terminal during autonomous work. Use `--verbose` to see the full evaluator log.

---

## Contributing

SpecKit Pro is built on the [Spec Kit extension system](https://github.com/github/spec-kit/blob/main/extensions/EXTENSION-DEVELOPMENT-GUIDE.md). Contributions welcome — see [CONTRIBUTING.md](CONTRIBUTING.md).

## License

MIT © spec-kit-pro contributors. See [LICENSE](LICENSE).

Built on [GitHub Spec Kit](https://github.com/github/spec-kit) — MIT License.
