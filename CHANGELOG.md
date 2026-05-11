# Changelog

All notable changes to SpecKit Pro will be documented in this file.

## [1.9.0] — 2026-05-11

Focus: **spec drift** — bridging the gap between static Markdown specs and platform-style “living” specs without silent auto-mutation.

### Added
- **`/speckit.pro.reconcile`** (`commands/pro.reconcile.md`) — post-implement drift review. Compares `spec.md` / `plan.md` / `tasks.md` (and optional **`repo-ai search`** hints) to actual changes; writes **`<FEATURE_DIR>/pro-drift.md`** with ALIGNED / DRIFT / UNKNOWN rows and follow-up hints.
- **`after_implement` hook** (`.specify/extensions.yml`) — optional **`speckit.pro.reconcile`** runs **after** git commit and **before** **`speckit.pro.evaluate`** so the evaluator can weigh documented drift.
- **`.github/agents/speckit.pro.reconcile.agent.md`** — thin GitHub Copilot agent stub pointing at `commands/pro.reconcile.md`.
- **`extension.yml`** — version **1.9.0**; registered **`speckit.pro.reconcile`**.
- **`README.md`** — hook pipeline, loop diagram, extension structure, and comparison table updated for reconcile.

## [1.8.0] — 2026-05-07

Focus: **adoption** and **PR safety**. Real-world usage data showed that 9 out of 10 features got planned but never entered the implement loop — and when they did, SpecKit artifacts kept landing in PR branches and had to be force-pushed away. v1.8 addresses both.

### Added
- **`/speckit.pro.pickup`** (`commands/pro.pickup.md`) — explicit entry point for features that have spec/plan/tasks but never started the implement loop. Auto-detects the stuck phase (`spec-only`, `plan-only`, `tasks-only`, `contracts-ready`, `contracts-missing`, `no-initializer`, `mid-loop`, `complete`) and runs only the missing prerequisites before starting the loop. Most common use case for resumed work.
- **Pre-Flight existing-feature scan** (`pro.go.md`) — extracts ticket IDs (`[A-Z]+-[0-9]+`) and title nouns from `$ARGUMENTS`, scans `specs/*/spec.md` and `plan.md` for matches, classifies each match's phase, and offers to resume via `/pro.pickup` instead of duplicating planning.
- **Branch convention check** (`pro.go.md` Phase 1b) — after `/speckit.specify` creates `NNN-feature-name`, scans `.claude/rules/`, `.cursor/rules/`, `CONTRIBUTING.md`, and the last 30 branches via `git for-each-ref` for a team naming convention. Prompts to rename if a non-default pattern is detected.
- **Phase 5b stack-aware initializer** (`pro.go.md`) — `init.sh` is now generated from real stack detection (`package.json`/`go.mod`/`pyproject.toml`/`Cargo.toml`/`Gemfile`) with runnable commands, not commented-out placeholders. For large monorepos, smoke tests are scoped to feature-touched paths.
- **Phase 5b AGENT.md prepopulation** (`pro.go.md`) — seeds AGENT.md from `package.json` scripts, `Makefile` targets, `.github/workflows/*.yml` (canonical CI commands), `.claude/rules/`, `.cursor/rules/`, `CLAUDE.md`/`AGENTS.md`, and project memory entries. Prevents iteration 1 from rediscovering "tests need Docker"-class facts that were already known.
- **`.gitignore` auto-management** (`pro.go.md` Phase 5b.2) — appends `.ai-knowledge/` to `.gitignore` (always) and `specs/` (when `commit_artifacts: false`) so workspace state never accidentally lands in feature commits.
- **Workspace Overview Mode** (`pro.status.md`) — `/pro.status` with no feature now shows every feature in `specs/` with its detected phase and the suggested pickup command. Replaces the previous "no active feature found" dead-end.
- **PR-safe checkpoint scope** (`pro.loop.md`, `pro.checkpoint.md`) — checkpoints stage paths explicitly, never `.ai-knowledge/`, and conditionally exclude `specs/` based on `commit_artifacts`. Includes a sanity-check `git diff --cached` grep that refuses to commit if workspace paths leaked into the staged set.
- **Legacy `context-summary.md` fallback** (`pro.loop.md`) — pre-v1.5 features with `context-summary.md` instead of `handoff.md` now load cleanly; the loop writes a fresh `handoff.md` at iteration end so subsequent iterations use the new schema.
- **`commit.commit_artifacts`** (`pro-config.template.yml`) — controls whether `specs/` is included in checkpoint commits. Default `false` (PR-safe). `.ai-knowledge/` is always excluded regardless.
- **`commit.auto_gitignore`** — toggle the Phase 5b `.gitignore` append.
- **`pickup.ticket_match`, `pickup.title_match`, `pickup.branch_rename_prompt`** — toggle the new pre-flight behaviors individually.

### Changed
- **`extension.yml`** — version bumped to 1.8.0; new `commit` and `pickup` defaults blocks; `speckit.pro.pickup` registered.
- **Scope of Autonomy** (`pro.loop.md`) — added explicit hard rule: "Stage `.ai-knowledge/` paths in any commit" is now a `BLOCKED` action.

### Why
Real-world adoption data (10 features observed): only 1 ran the loop end-to-end. Two features stalled at `/speckit.tasks`. Six features had complete spec/plan/tasks/contracts but no `.ai-knowledge/` was ever created — there was no clean entry point that said "implement this, don't plan it again." `/pro.pickup` is that entry point. The pre-flight scan steers users toward it before they accidentally start a duplicate spec.

PR-safe checkpoints address the second-most-reported pain: SpecKit Pro state files (`AGENT.md`, `progress.md`, sprint contracts) silently landed in feature branches and had to be force-pushed away before opening a PR. v1.8 keeps them workspace-only by default.

## [1.7.0] — 2026-05-05

### Added
- **Context Efficiency Guidelines** (`pro.loop.md`) — expanded from 4 bullets to a full section:
  - Four failure mode table (Poisoning, Distraction, Confusion, Clash) with counters
  - 80/20 rule: stop complex multi-file work at ~80% context fill; emit `<!-- Context: HIGH -->` at >75%
  - Proactive backup doctrine: `handoff.md` resets beat lossy auto-compaction
  - Iteration orientation guidance for high-count runs (iteration > 5)
  - Task chunking: complete one work unit fully before integrating
- **`context.autocompact_pct_override`** (`pro-config.template.yml`) — expose `CLAUDE_AUTOCOMPACT_PCT_OVERRIDE` with documented range (1–100), default (~83.5%), and guidance on when to prefer it vs `reset_mode`
- **Task Complexity Routing** (`pro.loop.md`) — 5-tier routing table (trivial → direct; simple → single sub-agent; moderate → parallel sub-agents; complex → sequential; unclear → gather context first) with parallel vs sequential dispatch rules
- **Sub-Agent Invocation Quality** (`pro.loop.md`) — 4-component invocation template (task, scope, acceptance, format) with bad/good comparison table
- **System Evolution check** (`pro.loop.md`) — end-of-iteration friction → system gap analysis; appends `### System Improvements` to `progress.md` for operator review
- **Effort level tiers** (`pro-config.template.yml`) — per-phase effort config (`planning`, `execution`, `verification`, `exploratory`) with env overrides (`SPECKIT_EFFORT_*`)
- **`subagent_model`** (`pro-config.template.yml`) — split orchestrator vs sub-agent model; exports `CLAUDE_CODE_SUBAGENT_MODEL`

### Changed
- **`pro-orchestrate.sh`** — `--subagent-model`, `--effort-planning/execution/verification/exploratory` CLI args; env exports; banner shows sub-agent model and effort tiers
- **`pro-orchestrate.ps1`** — Windows parity: same params (`-SubagentModel`, `-EffortPlanning`, etc.), env exports, updated banner

## [1.0.0] — 2026-05-04

### Added
- `speckit.pro.run` — full autonomous SDD pipeline (specify → clarify → plan → tasks → analyze → implement) with configurable human gates
- `speckit.pro.loop` — autonomous implementation loop worker with progress tracking, circuit breaker, and status signals
- `speckit.pro.status` — rich status dashboard with pipeline phase icons, task progress bar, health signals, and recent activity
- `speckit.pro.resume` — resume interrupted runs from session state
- `speckit.pro.checkpoint` — named checkpoint with git commit and session/progress logging
- `speckit.pro.compress` — context compression to reduce token usage during long autonomous runs
- Bash orchestration scripts: `pro-orchestrate.sh`, `pro-status.sh`, `pro-checkpoint.sh`
- PowerShell orchestration script: `pro-orchestrate.ps1`
- Session state template (`session-template.md`) and progress template (`progress-template.md`)
- Full configuration via `pro-config.yml` with 20+ settings covering gates, quality, loop, context, and model settings
- Support for multiple agent CLIs: copilot, claude, gemini, codex (auto-detection fallback)
- Circuit breaker pattern (3 consecutive failures triggers halt)
- `.extensionignore` for clean distribution
