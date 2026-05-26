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

> **New in v1.13** — optional **local Ollama sidecar** that takes over the token-heavy prep + first-pass review surfaces (repo maps, context packs, task packets, risk registers, test strategies, implementation/test-gap/security reviews) so Claude becomes a premium worker, not the whole factory. Plus **`/speckit.pro.local-metrics`** — a read-only dashboard of per-task latency, failure rate, and per-review-type **precision/recall** measured against the evaluator's verdicts. See **[Local Ollama sidecar](#local-ollama-sidecar-token-offload-optional)** below.

## Why SpecKit Pro?

Standard SpecKit gives you powerful individual commands. SpecKit Pro wires them together for **hands-free, resumable, self-healing autonomous runs**:

| Standard SpecKit | SpecKit Pro |
|---|---|
| Each phase requires a manual command | Full pipeline in one command: `/speckit.pro.go` |
| Manual human gates between all phases | Configurable: gate per phase or fully autonomous |
| `/speckit.implement` runs one pass | Self-healing loop with circuit breaker and retry |
| No quality gate between tasks and implement | Sprint contracts auto-generated via `after_tasks` hook |
| No independent QA — agent grades its own work | Separate evaluator agent via `after_implement` hook |
| Static specs drift from code unnoticed | Optional **`/speckit.pro.reconcile`** writes **`pro-drift.md`** before evaluate |
| No repo-level memory of domain or architecture | **`/speckit.pro.knowledge-sync`** primes new specs from **`.repo-knowledge/`** (`before_specify`) and proposes updates after evaluator PASS (`after_implement`) |
| Specs go to implementation thin — data model, invariants, failure modes, side effects unspecified | **`/speckit.pro.deepen`** audits the draft spec against a depth checklist, investigates gaps from local + capability-matched external sources, writes cited patches + a focused human-input file (≤10 questions) before clarify runs |
| Evaluator reads code statically | Evaluator uses **agent-browser** to click through the live running app |
| Edge cases die silently — sprint passes on happy path only | **Edge Cases & Failure States** required in spec (six-axis matrix); contract has Browser Test column per row; every CRITICAL row needs a replayable agent-browser script |
| Browser tests are ephemeral — evaluator clicks once, no replay | `<spec-dir>/browser-tests/<flow>/<NN>-<state>.sh` — durable, hermetic scripts. **Regression carry-forward**: every future sprint re-runs *all* prior scripts. A later sprint cannot silently re-break an earlier sprint's behavior |
| New branch added without test coverage — happy path masks regression | **Branch-symmetry enforcement**: every new `if`/short-circuit/early-return in the diff must have a contract row asserting that branch's behavior — evaluator triggers `unrostered-branch` NEEDS_REVISION otherwise |
| Stubs and no-ops slip through | **Stub & no-op auto-FAIL gate** — auto-greps for `TODO`, `throw new Error('not implemented')`, empty function bodies, empty JSX renders, silent `catch` blocks in non-test files; any match auto-fails the sprint, no scoring discretion |
| Silent failures (blank UI, stuck spinner) scored same as loud ones | **`silent` failure-mode tag** on every contract row; silent rows are auto-promoted to CRITICAL regardless of typed severity (silent regressions are the worst class — no monitoring catches them) |
| Context grows unbounded over many iterations | Per-sprint `handoff.md` resets context cleanly |
| No project memory across context windows | `AGENT.md` — loop writes its own learnings each iteration |
| No pre-flight sanity check | `init.sh` smoke-tests the app before each new work unit |
| Agent grades its own work — self-praise bias | Separate evaluator with explicit **anti-sycophancy** rules |
| Loop silently guesses at ambiguous requirements | **Uncertainty signalling** — `<pro-uncertainty>` logged for operator |
| No hard limits on irreversible actions | **Scope of Autonomy** — hard rules on what loop may never do alone |
| No session state — can't resume | Full session persistence → `/speckit.pro.resume` |
| No visibility into autonomous progress | Rich status dashboard → `/speckit.pro.status` |
| Heavy prep + review work runs on Claude tokens | Optional **local Ollama sidecar** writes `repo-map.md`, `context-pack.md`, `task-packets/`, `risk-register.md`, `test-strategy.md`, and a first-pass `local-reviews/` of implementation / test-gap / security. Provenance banner enforces "drafts, not truth"; Claude verifies. Self-skips if Ollama is unreachable. |
| No way to measure if local-model offload is worth keeping | **`/speckit.pro.local-metrics`** — per-task p50/p95 latency + failure rate, per-review-type **precision** (kept ÷ produced) and **recall** (agreed ÷ (agreed + missed)) measured against the evaluator's verdicts, top false-positive signatures, Ollama availability over time |

---

## Quick Guide

The day-to-day commands and flow most users actually need. Read this section first; the rest of the README is reference.

### Most-used commands, in order of frequency

| When | Command | What it does |
|---|---|---|
| Starting a new feature | `/speckit.pro.go <description>` | Full pipeline: spec → clarify → plan → tasks → implement → reconcile → evaluate. Pre-flight scans `specs/` for ticket-ID and title overlap so you don't double-plan an in-flight feature. |
| Half-planned feature is stuck | `/speckit.pro.pickup <feature>` | Detects which phase stalled (most common: spec exists, never ran the loop) and runs only the missing prerequisites before starting. |
| "What's in flight?" | `/speckit.pro.status` (no args) | Workspace overview: every feature under `specs/` + its detected phase + the suggested pickup command. |
| "How's feature X going?" | `/speckit.pro.status <feature>` | Single-feature dashboard: progress bar, recent activity, health signals. |
| Loop crashed, continue | `/speckit.pro.resume` | Picks up from the last session checkpoint with the right model/agent CLI flags. |
| Spec feels thin | `/speckit.pro.deepen` → answer questions → `/speckit.pro.deepen --apply` | Adversarial spec auditor with capability-based source discovery. Investigates gaps, writes ≤10 sharp human questions, merges your answers + cited patches into `spec.md`. Use on any non-trivial feature. |
| Is the local model worth keeping? | `/speckit.pro.local-metrics` | Per-task latency + per-review precision/recall. Read-only; never calls Claude or Ollama. |

### Recommended flow for a new feature

```
1. /speckit.pro.go "Build payment retry with exponential backoff"
       ├─ Phase 1   /speckit.specify         (review the spec when it pauses)
       ├─ Phase 1c  /pro.deepen              (optional, recommended for non-trivial work)
       ├─ Phase 2   /speckit.clarify         (auto)
       ├─ Phase 3   /speckit.plan            (review the plan when it pauses)
       ├─ Phase 4   /speckit.tasks → /pro.contract
       ├─ Phase 4b  /pro.local-prep + /pro.materialize   (optional, Ollama sidecar)
       ├─ Phase 5   /speckit.analyze         (auto)
       ├─ Phase 6   implement loop           (sprint-by-sprint)
       ├─ Phase 6b  /pro.local-review        (optional, Ollama sidecar)
       └─ Phase 7   /pro.reconcile → /pro.evaluate → /pro.knowledge-sync (on PASS)

2. Review the PR. If something's off, run /speckit.pro.status <feature> to see what.
3. If the loop stopped early: /speckit.pro.resume
4. (Periodic) /speckit.pro.local-metrics — is the local stack pulling its weight?
```

The two human gates are **spec** and **plan**. Everything else is auto-continue by default. One bad architectural decision cascades — review the plan carefully.

### Day-zero setup checklist

1. **Install the extension** — `specify extension add pro --from <release-url>` (see [Installation](#installation)).
2. **Copy the config template** — `cp .specify/extensions/pro/pro-config.template.yml .specify/extensions/pro/pro-config.yml` and skim it.
3. **(Optional) Local Ollama sidecar** — if you want to cut Claude tokens:
   ```bash
   brew install ollama && ollama serve &
   ollama pull qwen2.5-coder:7b
   ```
   Then in `pro-config.yml`: `local_models.enabled: true`. See [Local Ollama sidecar](#local-ollama-sidecar-token-offload-optional).
4. **(Optional) `.repo-knowledge/`** — hand-curate `INDEX.md` and at least one `domain/<bounded-context>.md`. Then `knowledge.enabled: true`. See [Repo-level knowledge base](#repo-level-knowledge-base-repo-knowledge).
5. **Verify** — `specify extension list` should show ✓ SpecKit Pro (v1.13).

### When to use which command — cheat sheet

- "I have an idea, build the feature" → **`/speckit.pro.go`**
- "I have a spec/plan/tasks but never built it" → **`/speckit.pro.pickup`**
- "Show me everything in flight" → **`/speckit.pro.status`** (no args)
- "How's feature X going?" → **`/speckit.pro.status <feature>`**
- "Loop crashed, continue" → **`/speckit.pro.resume`**
- "Spec is too thin, find the gaps" → **`/speckit.pro.deepen`** then **`/speckit.pro.deepen --apply`**
- "Generate per-task packets so the loop loads less context per iteration" → **`/speckit.pro.materialize`**
- "Do a first-pass code review before the evaluator" → **`/speckit.pro.local-review`** (requires Ollama)
- "Generate prep artifacts (repo-map, context-pack, ...)" → **`/speckit.pro.local-prep`** (requires Ollama)
- "Is the local model worth keeping?" → **`/speckit.pro.local-metrics`**
- "Compare the spec/plan to what we actually built" → **`/speckit.pro.reconcile`**
- "Run a strict QA on the current sprint" → **`/speckit.pro.evaluate`** (fires automatically after implement)
- "Update `.repo-knowledge/` from the merged code" → **`/speckit.pro.knowledge-sync`** (runs automatically on evaluator PASS)
- "Compress context for the next sprint" → **`/speckit.pro.compress`**
- "Commit + snapshot session right now" → **`/speckit.pro.checkpoint`**

### Three patterns that catch most real-world cases

1. **"New feature, full pipeline"** → `/speckit.pro.go <description>`. Default.
2. **"Existing feature stalled before the loop"** → `/speckit.pro.status` (find it) → `/speckit.pro.pickup <feature>`. The #1 reason features stall is "spec exists, never ran the implement loop"; pickup auto-detects the phase and resumes.
3. **"Long autonomous run finished"** → `/speckit.pro.status <feature>` (verify) → review evaluator verdict in `.ai-knowledge/<feature>/evaluations/sprint-N.md` → if `/pro.local-review` ran, also skim `<SPEC_DIR>/local-reviews/` for the local findings + the evaluator's verdicts on them.

---

## Installation

### From GitHub (recommended)

```bash
specify extension add pro --from https://github.com/gen-by-ai/speckit-pro/archive/refs/tags/v1.13.zip
```

### From source (local dev)

```bash
git clone https://github.com/gen-by-ai/speckit-pro
cd my-project
specify extension add --dev /path/to/speckit-pro
```

### Verify

```bash
specify extension list
# ✓ SpecKit Pro (v1.13)
#   Autonomous long-run orchestration
#   Commands: 8 | Hooks: 2 | Status: Enabled
```

### Updating

To update to a newer release, remove the existing extension and re-add it:

```bash
specify extension remove pro
specify extension add pro --from https://github.com/gen-by-ai/speckit-pro/archive/refs/tags/v1.13.zip
```

Replace `v1.13` with the latest tag from [github.com/gen-by-ai/speckit-pro/releases](https://github.com/gen-by-ai/speckit-pro/releases).

> **Note:** Updating replaces the extension files in `.specify/extensions/pro/` but does **not** touch your feature spec directories or `.ai-knowledge/` — all your `AGENT.md`, `contracts/`, `evaluations/`, and `progress.md` are untouched.

---

## Quick Start

### Option A: Full Autonomous Pipeline

Run the complete SDD cycle from description to implementation:

```
/speckit.pro.go Build a REST API for managing todo items with user authentication, PostgreSQL backend, and JWT tokens
```

SpecKit Pro will:
0. Run `/speckit.pro.knowledge-sync --mode prime` (skipped unless `.repo-knowledge/` exists and `knowledge.enabled: true`) — surfaces relevant domain/architecture/invariants/ADRs before the spec is written
1. Run `/speckit.specify` (gate: review spec)
1c. Run `/speckit.pro.deepen` (skipped unless `deepen.enabled: true`) — audits the spec against a depth checklist, investigates gaps, writes cited patches + human questions; pauses for the operator to answer
2. Run `/speckit.clarify` (auto)
3. Run `/speckit.plan` (gate: review plan)
4. Run `/speckit.tasks` → `after_tasks` hook auto-generates sprint contract
4b. (optional) Run **`/speckit.pro.local-prep`** + **`/speckit.pro.materialize`** — local Ollama writes `repo-map.md`, `context-pack.md`, `risk-register.md`, `test-strategy.md`, `open-questions.md`, and per-task packets under `task-packets/`. Self-skips if `local_models.enabled: false` or Ollama is unreachable.
5. Run `/speckit.analyze` (auto)
6. Run the implement loop → 6b. (optional) Run **`/speckit.pro.local-review`** — local Ollama writes first-pass `implementation-review.md`, `test-gap-review.md`, `security-review.md` under `local-reviews/` with full evidence packs. Same self-skip rules as Phase 4b.
7. `after_implement` hooks: optional **`speckit.pro.reconcile`** (writes **`pro-drift.md`**) → **`speckit.pro.evaluate`** (reads local-reviews if present; verifies before deciding PASS/NEEDS_REVISION/FAIL; writes one verdict event per local finding for `/pro.local-metrics`) → optional **`speckit.pro.knowledge-sync`** (writes **`pro-knowledge.md`**, only on evaluator PASS)

### Option B: Native Commands + Pro Hooks

Run native SpecKit commands as normal — Pro hooks fire automatically:

```
/speckit.tasks          # generates tasks.md
                        # → speckit.pro.contract fires automatically

/speckit.implement      # implements the feature
                        # → speckit.pro.reconcile (optional; drift vs spec/plan)
                        # → speckit.pro.evaluate fires automatically
                        # → speckit.pro.knowledge-sync (optional; only on evaluator PASS)
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

### Entry Points

| Command | Description |
|---|---|
| `/speckit.pro.go <description>` | Full pipeline from a fresh idea: specify → clarify → plan → tasks → implement. Pre-flight scans `specs/` for tickets/title nouns already in flight and offers to resume those instead of duplicating planning. |
| `/speckit.pro.pickup <feature>` | Pick up an existing feature that has spec/plan/tasks but never started the loop. Auto-detects the stuck phase and runs only the missing prerequisites before starting. The most common entry point in real projects — most features stall after `/speckit.tasks`. |

### Hook Commands (also callable manually)

| Command | Fires automatically | Description |
|---|---|---|
| `/speckit.pro.deepen` | after `/speckit.specify` (before clarify) | Adversarial spec auditor: investigates gaps from `.repo-knowledge/`, code, sibling specs, git history, and any capability-matched external sources (issue tracker, docs). Writes **`spec-patches.md`** (cited proposals) + **`spec-questions.md`** (≤10 questions, multiple-choice). `--apply` merges as a diff. Disabled by default. |
| `/speckit.pro.contract` | after `/speckit.tasks` | Generate sprint contract — concrete acceptance criteria before coding |
| `/speckit.pro.reconcile` | after `/speckit.implement` (before evaluate) | Spec drift review — writes **`pro-drift.md`** so specs stay honest vs code |
| `/speckit.pro.evaluate` | after `/speckit.implement` | Strict QA evaluation: calibrates against past sprint scores, reads **`pro-drift.md`** if present, then drives the live app with **agent-browser** to test every CRITICAL criterion |
| `/speckit.pro.knowledge-sync` | `before_specify` (prime) + after `/speckit.pro.evaluate` (sync, on PASS only) | Repo-level knowledge base: primes new specs from **`.repo-knowledge/`** before they're written; after evaluator PASS, diffs the sprint vs knowledge claims and writes **`pro-knowledge.md`** proposals. Never silently mutates the knowledge base. |
| `/speckit.pro.local-prep` | Phase 4b (after `/speckit.tasks`) when `local_models.enabled` | Local Ollama writes the prep-phase Markdown — **`repo-map.md`**, **`context-pack.md`**, **`risk-register.md`**, **`test-strategy.md`**, **`open-questions.md`** — so the loop reads tight artifacts instead of regenerating them. Self-skips if disabled or Ollama is unreachable. |
| `/speckit.pro.materialize` | Phase 4b (chained after `/pro.local-prep`) | Splits `tasks.md` into per-task packets under **`task-packets/TASK-NNN-<slug>.md`**. Local-model refined when Ollama is up; deterministic skeletons otherwise. The loop can load one packet per work unit instead of re-reading the whole spec set. |
| `/speckit.pro.local-review` | Phase 6b (after the implement loop, before `/pro.evaluate`) | Local Ollama writes first-pass **`implementation-review.md`**, **`test-gap-review.md`**, **`security-review.md`** with mandatory evidence packs (file, lines, severity, evidence quote, suggested patch, confidence, disproof). The stronger evaluator verifies — local model never has the final say. |
| `/speckit.pro.checkpoint` | manual | Commit + session snapshot + progress log entry |

### Loop & Observability

| Command | Description |
|---|---|
| `/speckit.pro.loop` | Single autonomous iteration (invoked by orchestrator script) |
| `/speckit.pro.status` | Rich status dashboard. With no feature arg, falls through to **Workspace Overview Mode** — lists every feature in `specs/` with its detected phase (`spec-only` / `plan-only` / `tasks-only` / `contracts-ready` / `in-loop` / `complete`) and the suggested pickup command. |
| `/speckit.pro.resume` | Resume an interrupted run from last session checkpoint |
| `/speckit.pro.compress` | Write `handoff.md` — clean context reset for the next sprint |
| `/speckit.pro.local-metrics` | Read-only dashboard of local-model telemetry — per-task p50/p95 latency + failure rate, per-review-type precision/recall (vs evaluator), top dropped finding signatures, Ollama availability. Filters: `--since 30d|7d|24h|all`, `--feature <slug>`, `--task <name>`. `--json` for piping into charts. Pure Python; never calls Claude or Ollama. |

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

# Local Ollama sidecar (token offload — optional, off by default)
local_models:
  enabled: false                       # set true once `ollama serve` is running and a model is pulled
  base_url: "http://localhost:11434"   # or http://workstation.local:11434 for remote Ollama
  default_model:  "qwen2.5-coder:7b"
  fast_model:     "llama3.2:3b"        # summaries / Markdown cleanup
  code_model:     "qwen2.5-coder:7b"   # task packets, first-pass implementation review
  review_model:   "qwen2.5-coder:7b"   # test-gap review
  security_model: "qwen2.5-coder:7b"   # first-pass security screen (consider a larger model)
  timeout_seconds: 180
  num_ctx: 8192
  temperature: 0.2
  auto_run:
    after_tasks:       true   # Phase 4b: /pro.local-prep + /pro.materialize
    before_evaluate:   true   # Phase 6b: /pro.local-review
  telemetry: true                                     # /pro.local-metrics reads this
  metrics_file: ".ai-knowledge/local-metrics.jsonl"   # gitignored by default
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
         │     (Scope of Autonomy hard rules)   │
         │  5. Signal uncertainty if ambiguous  │
         │  6. Update tasks.md + progress.md    │
         │  7. Write next handoff.md            │
         │  8. Update AGENT.md with learnings   │
         │  Outputs: <pro-status>TAG</pro-status>          │
         └──────────────┬───────────────────────┘
                        ▼
         ┌──────────────────────────────────────┐
         │  DRIFT: speckit.pro.reconcile        │
         │  Compare spec/plan/tasks to code     │
         │  Output: <FEATURE_DIR>/pro-drift.md  │
         │  (optional hook — skip if abort)     │
         └──────────────┬───────────────────────┘
                        ▼
         ┌──────────────────────────────────────┐
         │  EVALUATOR: speckit.pro.evaluate     │
         │  Fresh agent — no generator context  │
         │  0. Read pro-drift.md if present     │
         │  1. Calibrate vs past sprint scores  │
         │  2. Start app via init.sh            │
         │  3. agent-browser: click every       │
         │     CRITICAL criterion live          │
         │  4. Static code + revisability check │
         │  5. Anti-sycophancy: score criteria  │
         │     only, no "great work" inflation  │
         │  PASS → continue                     │
         │  NEEDS_REVISION → generator retries  │
         │  FAIL → human review required        │
         └──────────────┬───────────────────────┘
                        ▼
         ┌──────────────────────────────────────┐
         │  KNOWLEDGE: speckit.pro.knowledge-sync │
         │  Runs ONLY on evaluator PASS         │
         │  Skips if .repo-knowledge/ absent    │
         │  Skips if only tests/fixtures changed│
         │  1. Diff vs .repo-knowledge/ claims  │
         │  2. Classify: additive/clarifying/   │
         │     breaking                         │
         │  3. Write pro-knowledge.md           │
         │     (review file, mirrors drift)    │
         │  4. Auto-apply additive only (opt)   │
         │  5. Scaffold ADR draft on breaking   │
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

**`.ai-knowledge/<feature>/`** — Persistent knowledge that survives extension updates and accumulates across the project lifetime:

```
.ai-knowledge/
└── 001-my-feature/
    ├── AGENT.md          # loop's self-written project memory
    ├── init.sh           # smoke test / app startup script
    ├── progress.md       # full iteration audit trail
    ├── contracts/        # sprint contracts (one per sprint)
    └── evaluations/      # evaluator verdicts with browser test results
```

This directory lives at your **project root**, not inside `.specify/`. Updating or reinstalling the extension never touches it.

**`contracts/sprint-N.md`** — Sprint contract (auto-generated by `speckit.pro.contract`, stored in `.ai-knowledge/<feature>/contracts/`):
```markdown
# Sprint Contract — Sprint 3

## Acceptance Criteria
| # | Criterion | Severity | How to Verify |
|---|---|---|---|
| 1 | POST /auth/login returns JWT on valid credentials | CRITICAL | curl test |
| 2 | Returns HTTP 401 for invalid password | CRITICAL | curl test |
| 3 | Token expires after configured TTL | MEDIUM | decode payload |
```

**`evaluations/sprint-N.md`** — Evaluator verdict (auto-generated by `speckit.pro.evaluate`, stored in `.ai-knowledge/<feature>/evaluations/`):
```markdown
# Evaluation — Sprint 3
Verdict: PASS (score: 82/100)
CRITICAL: 2/2 pass  MEDIUM: 1/2 pass  LOW: 3/3 pass

## Browser Test Results (via agent-browser)
- POST /auth/login → navigated to /dashboard ✓
- Invalid password → 401 page shown ✓
```

**`AGENT.md`** — Project memory written by the loop (stored in `.ai-knowledge/<feature>/`, auto-updated each iteration):
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

**`init.sh`** — Smoke test script (stored in `.ai-knowledge/<feature>/`, auto-generated by `pro.go`, run by loop before each work unit):
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

## Local knowledge index (`repo-ai`)

**SpecKit Pro does not install or run this automatically.** It is an optional Node CLI that builds a **local** embedding index over repo markdown (skills, rules, `.specify`, etc.) so agents can run **`repo-ai search`** for semantic retrieval. Nothing is sent to a remote API.

### Kickoff (first time)

From the repository root:

```bash
cd repo-ai && npm install
npm run build-index    # creates repo-ai/embeddings.jsonl + repo-ai/vectordb/index.json (first run downloads the model)
npm run search -- "your question"
```

Or install the binary once and use it from any checkout:

```bash
npm install -g ./repo-ai
repo-ai build
repo-ai search "your question"
```

Generated **`repo-ai/embeddings.jsonl`** and **`repo-ai/vectordb/`** are gitignored by default; rebuild when docs change.

### Docs for agents

Cursor agents load **`.agents/skills/repo-ai-cli/SKILL.md`** when attached — same commands and **`REPO_AI_ROOT`** / **`--root`** behavior.

### Used by Pro commands?

**`/speckit.pro.reconcile`** may call **`repo-ai search`** as optional navigation hints if an index already exists; it does **not** run **`npm install`** or **`build`** for you.

**`/speckit.pro.knowledge-sync`** uses **`repo-ai search`** in `prime` mode to retrieve the top-k chunks from **`.repo-knowledge/`** before a new spec is written. With no index, it falls back to grep over **`INDEX.md`**.

---

## Repo-level knowledge base (`.repo-knowledge/`)

Specs describe **one feature**. `AGENT.md` describes **how to run the project**. Neither captures the layer above: *what does the business mean by "policy", which bounded contexts own writes to `customer`, what invariants must never break*. Without that layer, every new feature rediscovers the domain from code — slowly, and often wrong.

**`.repo-knowledge/`** is that layer. Unlike `.ai-knowledge/` (workspace-only, gitignored), this directory is **versioned in git** — it's the team's living documentation, curated by humans, indexed by `repo-ai`, and consulted by the loop at both ends of the pipeline.

### Suggested layout

```
.repo-knowledge/
├── INDEX.md                    # decision tree: "if touching X, read Y, then Z"
├── architecture.md             # systems map + entry points per area
├── domain/
│   ├── glossary.md             # business terms, not code terms
│   ├── <bounded-context>.md    # one per business capability (billing, auth, …)
│   └── invariants.md           # rules that must never break
├── decisions/
│   └── ADR-NNNN-*.md           # accepted decisions, append-only history
└── runbooks/
    └── <flow>.md               # end-to-end traces (request → DB → side effects)
```

### How SpecKit Pro uses it

| Phase | Hook | What happens |
|---|---|---|
| **Before specify** | `before_specify` → `/pro.knowledge-sync --mode prime` | Retrieves top-k chunks relevant to the feature description and surfaces them to the agent before it writes `spec.md`. Prevents reinventing terms, violating invariants, or duplicating a bounded context. |
| **After evaluate PASS** | `after_implement` (last step) → `/pro.knowledge-sync` (default `sync`) | Diffs the sprint's code against claims in `.repo-knowledge/`. Writes `<FEATURE_DIR>/pro-knowledge.md` with **additive** / **clarifying** / **breaking** proposals. Auto-applies additive only (configurable); never auto-edits `decisions/`, `invariants.md`, or `domain/*`. |

### Design rules

1. **Disabled by default.** Turn `knowledge.enabled: true` on in `pro-config.yml` only after seeding at least `INDEX.md` and one domain file. An auto-generated knowledge base that nobody reviews is worse than no knowledge base.
2. **Sync only runs on evaluator PASS.** Updating docs against not-yet-verified code corrupts the knowledge base. Drift on failure is normal; drift on PASS is the only kind worth recording.
3. **Sync short-circuits cheaply.** If the diff touches only tests/fixtures, or none of `.repo-knowledge/` references the changed paths, the command exits in ~1s without an agent call.
4. **Proposals go to a review file first.** `pro-knowledge.md` mirrors the `pro-drift.md` pattern — operator decides what graduates into `.repo-knowledge/`.
5. **INDEX.md is a decision tree, not a TOC.** Each entry should read **"if you are touching X, read Y, then Z"**. The loop traverses it like a router during `prime`.

---

## Local Ollama sidecar (token offload, optional)

The Claude extension is great for interactive work, but as Pro usage grows, the Claude-as-control-plane pattern starts costing real tokens for mostly-deterministic Markdown work. **Local Ollama models** can take over the prep + first-pass review surfaces: repo maps, context packs, task packets, risk registers, test strategies, and three flavors of review. Claude stays as the **premium worker** that verifies before anything ships.

> From [`.dev-work/dev.md`](.dev-work/dev.md): "Claude should become a premium worker, not the whole factory." The sidecar is the structural answer to that.

### Setup

Off by default. To enable:

```bash
# 1. Install Ollama (macOS shown; Linux/Windows similar)
brew install ollama
ollama serve &

# 2. Pull a code-capable 7B model
ollama pull qwen2.5-coder:7b

# 3. Turn it on in pro-config.yml
#    .specify/extensions/pro/pro-config.yml
```

```yaml
local_models:
  enabled: true
  base_url: "http://localhost:11434"
```

For Pi-class hardware, point at a workstation instead:

```yaml
local_models:
  base_url: "http://workstation.local:11434"
```

or export `OLLAMA_BASE_URL` — the driver uses whichever resolves first.

### What it writes — Phase 4b (after `/speckit.tasks`)

`/speckit.pro.local-prep` then `/speckit.pro.materialize`:

| File | Purpose | Reader |
|---|---|---|
| `<SPEC_DIR>/repo-map.md` | Relevant files, patterns, test commands, risks | Implementer |
| `<SPEC_DIR>/risk-register.md` | Concrete risks with triggers, severity, mitigation, verifier | Implementer + evaluator |
| `<SPEC_DIR>/test-strategy.md` | Commands + test-case ideas grounded in the project's CI | Implementer |
| `<SPEC_DIR>/open-questions.md` | ≤ 10 sharp questions, multiple-choice when possible | Operator |
| `<SPEC_DIR>/context-pack.md` | Compiled ≤ 1500-word bundle the loop reads instead of spec + plan + tasks | Implementer + evaluator |
| `<SPEC_DIR>/task-packets/TASK-NNN-<slug>.md` | One self-contained packet per task | Implementer (per iteration) |

The loop's context-load rule becomes:

```
1. handoff.md (always)
2. context-pack.md (if present, replaces spec+plan+tasks)
3. task-packets/TASK-<current>-<slug>.md (for the current work unit)
```

Typical token savings per iteration: **60–80 %**.

### What it writes — Phase 6b (after the implement loop, before `/pro.evaluate`)

`/speckit.pro.local-review`:

| File | Reviewer focus | Model (default) |
|---|---|---|
| `<SPEC_DIR>/local-reviews/implementation-review.md` | Correctness, regression risk, contract violations | `code_model` |
| `<SPEC_DIR>/local-reviews/test-gap-review.md` | Acceptance criteria not exercised by tests | `review_model` |
| `<SPEC_DIR>/local-reviews/security-review.md` | Injection, authz, crypto, secrets, unsafe defaults | `security_model` |

### Evidence-pack discipline (MDASH-inspired)

Every local-review finding must include all eleven fields below. A finding without a file and a line range is **dropped**:

- File · Lines · Severity · Category · What · **Evidence (quote)** · Why-it-matters · Suggested patch · Confidence · **Disproof** · Maps-to-AC

From the security prompt: _"Prefer 3 high-confidence findings to 20 maybe-findings."_ Low false-positive rate is the first-class design goal — a noisy reviewer that the evaluator stops trusting is worse than no reviewer.

### Drafts, not truth

Every local artifact starts with a provenance banner:

> _Generated by local model `qwen2.5-coder:7b` via `ollama-md.py`. Claims require verification before implementation._

That banner is intentional — it stops downstream agents (and humans in PR review) from treating local output as ground truth. The stronger evaluator (`/pro.evaluate`) reads the drafts and verifies; it is **not bound by** what the local model said or missed.

### Graceful degradation

If Ollama is not running, the driver self-skips with a one-line note and exits 0. The pipeline continues with v1.12 behavior — no aborts, ever. To opt out entirely, set `local_models.enabled: false`.

### Order of adoption — don't make Ollama the implementer first

From `.dev-work/dev.md`, in order of token savings × judgment safety:

1. Repo maps + summaries
2. Task packets
3. Test strategies
4. First-pass review

Steps 1–4 are where the savings live. Implementation by local 7B models is risky and **not recommended** without much stronger guarantees.

### Telemetry & quality metrics — `/speckit.pro.local-metrics`

The sidecar emits three event types into `.ai-knowledge/local-metrics.jsonl` (gitignored, workspace state):

| Event | Written by | When |
|---|---|---|
| `call` | `scripts/local/ollama-md.py` | Every Ollama invocation — success and failure |
| `verdict` | `/pro.evaluate` Step 4c | Once per finding in `local-reviews/*.md` — `agreed`, `kept`, `dropped`, `unverifiable`, or `missed` |
| `skip` | `pro-local-prep.sh` / `pro-local-review.sh` / `pro-materialize.sh` | When the driver self-skips because Ollama is unreachable (one event per run) |

`/speckit.pro.local-metrics` reads the file and prints:

```
  SpecKit Pro — local-model metrics (30d window)
────────────────────────────────────────────────────────────────────────
  Calls: 142   Failures: 3 (2.1%)   Wall: 51.4 min   Output: 412 KiB
────────────────────────────────────────────────────────────────────────
  TASK                       CALLS       p50       p95    FAIL  MODELS
  task-packet                   48     11.0s     17.4s    0 (  0%)  qwen2.5-coder:7b
  repo-map                      24     14.2s     22.1s    0 (  0%)  qwen2.5-coder:7b
  ...
────────────────────────────────────────────────────────────────────────
  REVIEW QUALITY (vs evaluator verdicts)
  TYPE                      PROD   AGR  KEPT  DROP   UV  MISS    PREC   RECALL
  implementation-review        18    11     2     5    0     6      72%     68%
  test-gap-review              12     7     3     2    0     4      83%     71%
  security-review               8     5     2     1    0     5      88%     58%
────────────────────────────────────────────────────────────────────────
  AVAILABILITY  (driver self-skipped before any Ollama call)
  Total skips: 4
    ollama-unreachable            4x
────────────────────────────────────────────────────────────────────────
```

**Precision** = `(agreed + kept) ÷ (agreed + kept + dropped)` — what fraction of local findings survived evaluator verification.
**Recall** = `(agreed + kept) ÷ (agreed + kept + missed)` — what fraction of real findings local actually caught.

Filters: `--since 30d|7d|24h|all`, `--feature <slug>`, `--task <name>`. `--json` for piping into charts.

### How to read the signal

| Symptom | Likely cause | Action |
|---|---|---|
| p95 latency creeping up for one task | `num_ctx` too large for the model | Try smaller model or `num_ctx: 4096` |
| One task failing often | Model not pulled, or context exceeds capacity | `ollama pull <name>`; check the `error` field in the JSONL |
| Review precision < 60 % | Prompt is over-eager | Tighten evidence-pack requirements, add anti-patterns |
| Review recall < 50 % | Model too weak for the surface | Move that review type to a 13B+ model, or back to Claude |
| One signature dominates "top dropped" | Systematic false positive | Add explicit anti-pattern to the prompt template |
| Many `ollama-unreachable` skips | Daemon flaky or `base_url` misconfigured | Verify `ollama serve` and the URL |

### Roadmap (deliberately not in v1.13)

- **Layer 2 — Golden bench (`benchmarks/local/`)**: 2–3 fixed spec/plan/tasks bundles re-run on every prompt-template change. Maps to the MDASH "private ground-truth corpora" lesson. Worth building once layer 1 data shows which prompts are unstable.
- **Layer 3 — A/B model routing**: two models compete per task; metrics decide the winner. Worth building once we have an actual model-choice question to answer with data.

Layer 1 needs real usage before we know which signals matter, so layers 2 and 3 are intentionally out-of-scope for this release.

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
speckit-pro/
├── extension.yml                  # Extension manifest (SpecKit schema v1.0)
├── repo-ai/                       # Optional local semantic index CLI (see “Local knowledge index” above)
├── commands/
│   ├── pro.go.md                  # → /speckit.pro.go  — pipeline runner with overlap-aware pre-flight + branch convention check
│   ├── pro.pickup.md              # → /speckit.pro.pickup  — entry point for stuck-but-planned features
│   ├── pro.contract.md            # → /speckit.pro.contract  — sprint contracts (after_tasks hook)
│   ├── pro.reconcile.md           # → /speckit.pro.reconcile  — spec drift vs code (after_implement hook, before evaluate)
│   ├── pro.evaluate.md            # → /speckit.pro.evaluate  — QA evaluator with agent-browser (after_implement hook)
│   ├── pro.knowledge-sync.md      # → /speckit.pro.knowledge-sync  — repo-level knowledge base prime/sync (before_specify + after_implement hooks)
│   ├── pro.deepen.md              # → /speckit.pro.deepen  — adversarial spec auditor with capability-based source discovery (after_specify hook)
│   ├── pro.loop.md                # → /speckit.pro.loop  — single iteration worker with AGENT.md self-update + PR-safe checkpoints
│   ├── pro.status.md              # → /speckit.pro.status  — single-feature dashboard + workspace overview mode
│   ├── pro.resume.md              # → /speckit.pro.resume  — resume from checkpoint
│   ├── pro.checkpoint.md          # → /speckit.pro.checkpoint  — named checkpoint with PR-safe staging
│   ├── pro.compress.md            # → /speckit.pro.compress  — context reset / handoff.md
│   ├── pro.local-prep.md          # → /speckit.pro.local-prep  — Ollama writes repo-map/context-pack/risk/test/open-Qs (Phase 4b)
│   ├── pro.local-review.md        # → /speckit.pro.local-review  — Ollama writes first-pass impl/test-gap/security review (Phase 6b)
│   ├── pro.materialize.md         # → /speckit.pro.materialize  — splits tasks.md into per-task packets (Phase 4b)
│   └── pro.local-metrics.md       # → /speckit.pro.local-metrics  — telemetry dashboard (latency, FP rate, precision/recall)
├── scripts/
│   ├── bash/
│   │   ├── pro-orchestrate.sh     # Gen/eval loop orchestrator (macOS/Linux)
│   │   ├── pro-status.sh          # Status reporter
│   │   ├── pro-checkpoint.sh      # Checkpoint helper
│   │   ├── pro-local-prep.sh      # Driver — orchestrates Ollama workers for prep artifacts
│   │   ├── pro-local-review.sh    # Driver — orchestrates Ollama workers for first-pass reviews
│   │   ├── pro-materialize.sh     # Driver — task-packet materializer (deterministic + Ollama-refined)
│   │   ├── pro-local-metrics.sh   # Driver — reads .ai-knowledge/local-metrics.jsonl, prints dashboard
│   │   └── lib/
│   │       └── pro-local-common.sh # Shared bash lib: config reader, model routing, telemetry helpers
│   ├── local/
│   │   └── ollama-md.py           # HTTP client for Ollama /api/chat — emits JSONL telemetry per call
│   └── powershell/
│       └── pro-orchestrate.ps1    # Gen/eval loop orchestrator (Windows)
├── agents/
│   └── speckit.pro.loop.agent.md  # Loop worker agent profile
├── templates/
│   ├── session-template.md        # Session state template
│   ├── progress-template.md       # Progress log template
│   ├── contract-template.md       # Sprint contract template (eight-column schema with State + Browser Test rows)
│   ├── handoff-template.md        # Context reset handoff template
│   ├── browser-test-template.sh   # Canonical hermetic agent-browser test shape (one row per script)
│   └── local/                     # Prompt templates for the local Ollama sidecar
│       ├── repo-map.prompt.md
│       ├── context-pack.prompt.md
│       ├── task-packet.prompt.md
│       ├── test-strategy.prompt.md
│       ├── risk-register.prompt.md
│       ├── open-questions.prompt.md
│       ├── implementation-review.prompt.md
│       ├── test-gap-review.prompt.md
│       └── security-review.prompt.md
├── pro-config.template.yml        # Configuration template
├── README.md
├── CHANGELOG.md
└── .extensionignore               # Distribution exclusions

# Generated per-feature (inside specs/<feature-dir>/) — transient state only
specs/<feature>/
├── spec.md / plan.md / tasks.md   # Native SpecKit artifacts
├── handoff.md                     # Per-sprint context reset artifact (transient)
├── pro-drift.md                   # Spec-vs-code drift findings (from /pro.reconcile)
├── pro-knowledge.md               # Knowledge-base sync proposals (from /pro.knowledge-sync)
├── spec-patches.md                # Cited spec proposals (from /pro.deepen)
├── spec-questions.md              # Human-input file for unresolved gaps (from /pro.deepen)
├── repo-map.md                    # Files/patterns/tests/risks (from /pro.local-prep — Ollama sidecar)
├── context-pack.md                # Compiled ≤1500-word loop substrate (from /pro.local-prep)
├── risk-register.md               # Concrete risks with triggers (from /pro.local-prep)
├── test-strategy.md               # Commands + case ideas (from /pro.local-prep)
├── open-questions.md              # ≤10 focused human questions (from /pro.local-prep)
├── task-packets/                  # Per-task self-contained packets (from /pro.materialize)
│   └── TASK-NNN-<slug>.md
├── local-reviews/                 # First-pass review with evidence packs (from /pro.local-review)
│   ├── implementation-review.md
│   ├── test-gap-review.md
│   └── security-review.md
├── browser-tests/                 # Durable agent-browser test scripts — one per CRITICAL contract row
│   ├── _template.sh               #   Reference copy of templates/browser-test-template.sh
│   └── <flow>/<NN>-<state>.sh     #   Hermetic, single-assertion, time-boxed; run by evaluator every sprint (regression carry-forward)
└── session.md                     # Pipeline phase state (transient)

# Repo-level knowledge base — versioned, curated by the team
.repo-knowledge/
├── INDEX.md                       # Decision-tree entry points
├── architecture.md                # Systems map + entry points
├── domain/                        # Bounded contexts, glossary, invariants
├── decisions/                     # ADRs (append-only history)
└── runbooks/                      # End-to-end flow traces

# Persistent knowledge — survives extension updates
.ai-knowledge/
├── local-metrics.jsonl            # JSONL telemetry — call/verdict/skip events (workspace-wide)
└── <feature>/
    ├── AGENT.md                   # Loop's self-written project memory (grows each iteration)
    ├── init.sh                    # Auto-generated smoke test (run before every work unit)
    ├── progress.md                # Iteration audit trail
    ├── contracts/sprint-N.md      # Sprint contracts (one per sprint)
    └── evaluations/sprint-N.md    # Evaluator verdicts with browser test results
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

9. **Watch for `<pro-uncertainty>` entries in `progress.md`** — These are places where the loop encountered ambiguous requirements and made a conservative guess. Review them after each sprint and clarify the spec if the guess was wrong.

10. **The Scope of Autonomy hard rules protect you** — The loop will never delete files, push to remote, or run destructive DB operations on its own. If a task genuinely requires one of these, the loop will emit `BLOCKED` and wait for you.

11. **Monitor with `/speckit.pro.status`** — Run in a separate terminal during autonomous work. Use `--verbose` to see the full evaluator log. Without args, it shows a workspace overview of every planned-but-unimplemented feature with pickup hints.

12. **Pick up before you plan again** — Before starting a new feature, run `/speckit.pro.status` (workspace mode) to see what's already partially planned. `/pro.go`'s pre-flight scan catches ticket-ID and title overlap automatically, but a quick visual scan is faster. The most common stall pattern is "spec exists, never ran" — `/pro.pickup <feature>` is the fix.

13. **Use `/pro.deepen` on any non-trivial feature** — the native spec template is shallow by design (user stories + a handful of FRs). Real features need a data model, invariants, failure modes, side effects, and a domain glossary the implement loop can lean on. `/pro.deepen` audits the draft against a depth checklist, investigates each gap from whatever sources are available (`.repo-knowledge/`, code, sibling specs, git history, and any capability-matched external integrations), and writes you ≤10 sharp multiple-choice questions for the rest. Front-loading 10 minutes here saves an hour of the implement loop missing helpers, validation, and error paths nobody specified.

14. **Seed `.repo-knowledge/` before you turn on `knowledge.enabled`** — a knowledge base full of auto-generated guesses is worse than none. Hand-curate `INDEX.md` and at least one `domain/<bounded-context>.md` first; then flip the switch and let `/pro.knowledge-sync` propose updates against curated ground truth. Treat `pro-knowledge.md` like a PR review queue — most proposals are right, but the breaking-tier ones earn their name.

15. **Keep `.ai-knowledge/` workspace-only** — `commit.commit_artifacts: false` (the default) means checkpoints never stage `specs/` or `.ai-knowledge/`. This avoids the common pain of force-pushing to remove SpecKit artifacts before opening a PR. If your team versions specs intentionally, set `commit_artifacts: true` — `.ai-knowledge/` is still excluded regardless.

16. **Turn on the local Ollama sidecar once Pro usage grows past hobby scale** — the offload is the structural fix for "Claude is the control plane" cost. Order of adoption: enable `local_models.enabled: true` first with **only** `auto_run.after_tasks: true` so you get the prep artifacts (cheap wins, low risk). Watch `/pro.local-metrics` for a few features. Once latency p95 is comfortable and failure rate is <5%, also enable `auto_run.before_evaluate: true` for the first-pass review screens. Never make the local model the implementer — that's a different cost/quality trade-off than offloading prep.

17. **Read `/pro.local-metrics` weekly while you're tuning** — the numbers tell you which prompts and which models earn their keep. **Precision <60% on a review type** = the prompt is over-eager (tighten evidence requirements). **Recall <50%** = the model is undersized for the surface (move to a 13B+ model or back to Claude for that review type). **One signature dominating "top dropped"** = systematic false positive worth adding as an explicit anti-pattern in the prompt template. **Many `ollama-unreachable` skips** = Ollama daemon or `base_url` is flaky and needs investigation, not just a config tweak.

---

## Contributing

SpecKit Pro is built on the [Spec Kit extension system](https://github.com/github/spec-kit/blob/main/extensions/EXTENSION-DEVELOPMENT-GUIDE.md). Contributions welcome — see [CONTRIBUTING.md](CONTRIBUTING.md).

## License

MIT © [gen-by-ai/speckit-pro](https://github.com/gen-by-ai/speckit-pro) contributors. See [LICENSE](LICENSE).

Built on [GitHub Spec Kit](https://github.com/github/spec-kit) — MIT License.
