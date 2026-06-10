# Changelog

All notable changes to SpecKit Pro will be documented in this file.

## [1.23] — 2026-06-10

Focus: **autonomy & reliability hardening** — fewer manual interventions, fewer silent failure modes, better self-recovery during long runs. Driven by a 45-finding deep audit of the implementation (three parallel reviews; register in the feature's `audit-findings.md`). Five clusters, each with hermetic smoke coverage in the new `scripts/tests/hardening-smoke.sh` (17 checks).

### Added — recoverability (FR-001..003)
- **Artifact-based resume.** New deterministic detector `scripts/bash/pro-resume-detect.sh` (PHASE/NEXT/ITER_LAST/REMAINING/WARNING from artifacts alone); `pro.resume.md` delegates to it — the `session.md`-missing dead end is gone, and resumed loops get `remaining = max_iterations − last-iteration` so budgets are never double-spent.
- **Run-record lifecycle + orphan sweep.** Manifests carry `status: open|finished|interrupted`; `pro-report.sh start` closes abandoned `open` records as `interrupted` (flock CAS, partial data preserved); *finish always wins* — a live concurrent run swept by mistake self-heals when its own `finish` runs. `aggregate` reports interrupted-run counts.

### Added — zero silent skips (FR-004..007)
- **Structured skip/decision events.** `pro-report.sh event skip|decision` (reason classes `disabled-by-config` / `environment-unavailable` / `error`; `.current` fallback; pre-run spool adopted at next start). `pro-local-prep.sh`, `pro-materialize.sh`, `pro-local-review.sh` now classify their degradations (a missing Ollama model is environment, not config). Run reports gain **Capability skips** and **Decisions** sections (explicit "none"); `runs.jsonl` gains `skip_count`/`decision_count`.
- **Placeholder accounting.** `local_count_unknown_markers` counts structured `- UNKNOWN` bullets; materialize prints `N UNKNOWN markers across M packets` + emits a degraded event; `pro.go.md` warns before consuming skeleton packets.
- **Verified, scoped checkpoints.** `checkpoint_commit()` stages with exclude pathspecs (`specs/`, `.knowledge/features/`, `.knowledge/metrics/` per `commit.commit_artifacts`), checks staging/commit exit codes (no more `git add . 2>/dev/null || true`), and emits an error event on failure — success is never reported unverified.

### Fixed — state integrity (FR-008..010)
- **Lock that wrote anyway.** `scan_report.py with_lock` ran the protected write even when the lock was never acquired; it now fails loud (exit 75, holder PID named) without writing.
- **Concurrency-safe state.** flock-guarded manifest read-modify-writes (`phase`/`call`/events), flock'd JSONL appends (`runs.jsonl`, fan-out telemetry), atomic `.current` writes with explicit-run-id preference. `SPECKIT_PRO_METRICS_DIR` override enables hermetic testing.

### Fixed — malformed signals (FR-011..013)
- **Unknown evaluator verdict was treated as PASS.** `pro-orchestrate.sh handle_eval_result`'s fallback returned accepted for any unrecognized verdict — including `ERROR:*`; now `FAIL:evaluator-output-invalid` (hard fail + decision event). `pro.go.md` Phase 7c gets the matching malformed-verdict rule.
- **Worker result envelope.** Parallel `[P]` workers return a defined JSON envelope; a task is marked done **iff** `status=="pass"`; breaker aftermath: serial retry once, then `BLOCKED:<task-id>`. `pro.evaluate.md` distinguishes `test-script-not-found` from failing tests.
- **Config-default drift check.** New `scripts/local/config_defaults_check.py` (stdlib YAML-subset comparator, `--strict`); resolved real drifts: `evaluation.enabled` (template `false` vs runtime-effective `true`), missing `gates.after_implement`/`loop.implement_phases` extension defaults, `run_checklist`→`require_checklist` naming.

### Added — unattended mode (FR-014..016)
- **`gates.unattended` + per-gate `unattended_defaults`** (`run_plan: proceed`, `phase_gate: continue`, `overlap: start-fresh`, `critical_analysis: stop` — conservative, `contract_amendment: auto`); every auto-applied default is recorded as a decision event + session.md line. Interactive behavior unchanged while `false`.
- **Auditable sealed-contract amendment.** `/pro.contract --amend` (sole seal owner): rows tagged `amended-mid-run`, prior seal preserved in `sprint-<N>.sha256.history`, re-seal + commit; the loop auto-invokes it unattended (tampering still hard-stops); `/pro.evaluate` enumerates amended rows and fails `FAIL:rubric-weakened` if any pre-existing criterion was relaxed.
- **Uncertainty digest.** `pro-report.sh finish --progress-file` extracts every `<pro-uncertainty>` block into `<feature>/uncertainties.md` with iteration context; count lands in run-report + `runs.jsonl`.

## [1.22] — 2026-06-08

Focus: **get `/pro.go` into its best shape — measurable, self-improving, and correct on the unattended headless path.** This release first makes every run measurable with a cross-run memory (run reports + improvements ledger + an opt-in parallel implement loop — see *the measurability foundation* at the end of this entry), then makes the *unattended* path the orchestrator drives when `agent_cli=claude` runs out-of-harness **correct, observable, and safe to let improve itself** — the part where a wrong CLI flag silently spends the whole budget on iteration 1, a self-grading loop can mark its own homework, and an unvetted "lesson" can steer the next run. All new behavior is opt-in and inert on the default path (`agent_cli=copilot`, in-harness loop, OTel off, `evaluation.enabled` untouched), so existing **v1.21.x** runs behave byte-for-byte unchanged.

### Added — correct unattended headless Claude-CLI orchestration
- **System-prompt injection fix.** Agent files are injected with `--append-system-prompt "$(cat <agentfile>)"` — the only real mechanism in the verified CLI (v2.1.116). The non-existent `--system-prompt-file` is never used, and `--system-prompt "$(cat …)"` is avoided because it would *replace* (not append to) Claude Code's own tool/safety prompt. Appending preserves the loop agent's `<pro-status>` contract.
- **Permission boundary for unattended editing.** Headless invocations run `--permission-mode acceptEdits` with an explicit `--allowedTools "Read Edit Write Bash(git *) Grep Glob"`. In `-p` there is no TTY, so an out-of-boundary tool is auto-denied (the agent adapts) rather than hanging; `acceptEdits` lets in-task edits proceed. `dangerously_skip_permissions` is an explicit opt-in for fully-trusted repos only; the config documents `dontAsk` as the strictest non-interactive alternative.
- **Structured JSON output with defensive parse.** `--output-format json`; the result is parsed **python3 → text-`<pro-status>`-scrape** (no jq added). The control signal derives from `is_error` plus the `<pro-status>` tag inside `.result`; unparseable/partial JSON becomes an `ERROR:*` that counts toward the circuit breaker — never a silent success.
- **Cumulative per-run budget cap.** `--max-budget-usd` is **per-invocation**, so passing the full cap to each of N iterations would permit ~N× the intended spend. The orchestrator now tracks `RUN_COST_USD` across iterations and passes the *remaining* budget per call, then stops and checkpoints with a `BUDGET_STOP` completion-state when the cumulative total crosses `orchestration.max_budget_usd` (default `10.00`). Satisfies the per-run guarantee of FR-003.
- **Session resume (UUID-safe).** `--session-id` requires a valid UUID and the telemetry `run_id` is not one, so the first call **omits** `--session-id`, captures the CLI-minted `session_id` from JSON, and passes `--resume <session_id>` on later iterations. The `run_id` stays a telemetry correlation key only.
- **CLI capability degradation.** Missing optional capabilities (a probe set, the hashing tool for a seal, the OTel exporter, a budget marker) degrade with a logged warning and never abort the pipeline. No second `.knowledge/` write path is introduced; no native `/speckit.*` command is forked.

### Added — per-run telemetry, regression flag, and opt-in OpenTelemetry
- **Per-run cost / token / turn / per-phase / intervention / rework / circuit-breaker telemetry.** `pro-report.sh` gains `call` and `phase` subcommands that read-modify-write the per-run manifest `.knowledge/metrics/runs/<run_id>.json` (a `calls[]` / `phases[]` accumulator, python3, bash-3.2-safe, no associative arrays); `finish` rolls them into `runs.jsonl` and `run-report.md`. New per-run fields: `total_cost_usd`, `input_tokens` / `output_tokens` / `cache_read_tokens` / `cache_creation_tokens`, `turns`, `session_id` (+ distinct `session_ids`), `per_phase_durations_s`, and `human_interventions` / `rework_count` / `circuit_breaker_trips`. Fields never reported are stored as `null` and rendered "unavailable" (never 0), so a genuine summed-0 stays distinguishable. `pro-report.sh` remains the **single** telemetry writer (no parallel log).
- **Eval-score regression flag.** `pro-report.sh aggregate` now prints an eval-score **trend** (e.g. `72 → 78 → 81 → 65 ⚠ REGRESSION`) and raises a regression recommendation when the latest scored run drops below the trailing mean by `reporting.regression.margin` **or** under `reporting.regression.pass_threshold`; suppressed until `reporting.regression.min_prior_scored` prior scored runs exist (defaults: window 5, margin 10, pass-threshold 70, min-prior 3 — operator-tunable, one `reporting.regression.*` namespace).
- **Opt-in OpenTelemetry GenAI export.** When `reporting.otel.enabled: true`, `finish` invokes `pro-otel-emit.sh`, which POSTs (OTLP/HTTP **JSON**, no protobuf/SDK dependency) one per-run root span + per-phase child spans + per-run metrics using GenAI semantic conventions, carrying `claude.session_id` so it joins Claude Code's own `CLAUDE_CODE_ENABLE_TELEMETRY` stream. Export failures are logged, never fatal. Keys: `reporting.otel.{enabled,endpoint,protocol,headers,service_name,timeout_seconds}`.

### Added — self-improvement safety
- **Sealed sprint contracts.** `/pro.contract` writes a committed `contracts/sprint-<N>.sha256` seal (python3 hashlib → `shasum -a 256` → `sha256sum`, with a literal `UNSEALED` token on a hashing-capability gap, force-added past gitignore). `/pro.evaluate` recomputes the hash pre-grade and emits `FAIL:rubric-mutated` on mismatch, or `FAIL:rubric-unsealed` when no seal exists on an evaluation-enabled run — fail-closed for tampering, fail-open for an honest `UNSEALED` gap. Reinforced by a `pro.loop.md` Scope-of-Autonomy hard rule (the loop may not edit a sealed contract).
- **Generator / evaluator model independence + read-only evaluator.** The evaluator runs with `orchestration.evaluator_allowed_tools` (default `"Read Grep Glob"` — no Edit/Write, so a grader cannot edit the code it grades) and `--model evaluation.evaluator_model`; when that is empty it falls back to the primary model with a forced skeptical preamble and a `SHARED-MODEL` disclosure in both the evaluation and the run report.
- **Proposal-based improvements ledger with curation.** `.knowledge/improvements.md` is restructured into four sections — **Promoted / Proposed / Archived / Pruned**. Phase 0 applies **Promoted only**; Phase 8b **appends** proposals (`status: proposed`, with `Evidence:` and `Promoted-by:` / `Disproven-by:` slots) and **never self-promotes**; Phase 8d curation enforces a ~50-active-line bound (`reporting.improvements.max_entries`, default 50), archiving lowest-value entries and pruning entries a later run disproved. A human promotes. The two prior reporting-era entries seed the **Promoted** section (already-shipped capabilities).
- **Probe-set regression guard with drift alarm.** `pro-improve-guard.sh` runs committed fixtures under `.knowledge/probes/{known-good,known-bad}/<case>/{fixture.md,expected}` through the evaluator at **Phase 7.5**, before any self-apply: **APPLY-OK** iff every known-good ACCEPTs and no known-bad ACCEPTs, else BLOCK; **fail-closed** if probes are missing/empty; `bootstrap` seeds ≥1 known-good (`seed-clean-pass`) + ≥1 known-bad (`seed-stub-implementation`, matching the existing Step-4a stub auto-FAIL). `drift` raises a loud alarm and blocks if a known-bad flips REJECT→ACCEPT versus `probe-drift.json`. Results land in gitignored `.knowledge/metrics/probes/<run_id>.jsonl`; config under `reporting.probes.*`.

### Why
The headless path had three latent failure classes. **Correctness:** a single wrong flag (`--system-prompt-file`, full-cap-per-call budget, run_id-as-session-id) could silently inject the wrong prompt, overspend N×, or have every resume rejected — none of which surface as an error, only as a quietly wrong run. **Observability:** the measurability foundation answered "how long / what / how did it go" but not "what did it cost, how many turns, where did the wall-clock go, how often did a human have to step in" — the signals you need to trust an unattended run. **Self-improvement safety:** a loop that grades itself, can edit its own rubric, and auto-applies its own lessons is a reward-hacking machine; the seal + independent read-only evaluator + proposal-only ledger + probe gate make each of those structurally hard. The default-path byte-for-byte invariant keeps the upgrade frictionless: teams on `copilot` + the in-harness loop see no change until they opt in.

### Added — the measurability foundation (run reporting, cross-run memory, parallel implement)

Make every `/pro.go` run measurable and self-improving — answer "how long did it take, what did it produce, how did it go, where can it improve" after each run and feed those learnings into the next — and wire the existing fan-out engine into the *implement* loop so it can run multiple agents at once. (Developed as the unreleased v1.22 increment; shipped here as part of this release.)

- New engine **`scripts/bash/pro-report.sh`** (deterministic, bash-3.2-safe, python3-assisted; never aborts the pipeline):
  - `start` stamps a run-start marker (epoch + git HEAD + branch) under gitignored `.knowledge/metrics/runs/`.
  - `finish` computes the delta and writes **`specs/<feature>/run-report.md`**: wall-clock duration, files added/modified/deleted/renamed (incl. untracked new files), lines +/-, commits (with log), loop iterations, tasks done/total, parallel-worker counts, local-model calls, eval verdict+score (auto-parsed from the sprint evaluation), and heuristic **where-to-improve** notes. Appends a one-line machine summary to **`.knowledge/metrics/runs.jsonl`**.
  - `aggregate` prints a cross-run dashboard (avg duration/eval/iters, PASS rate, parallel adoption, parallelization factor) + concrete recommendations, including an eval-score trend (first-half vs second-half).
  - `event` is the in-harness loop's telemetry logger (reuses `pro-fanout-common.sh::fanout_telemetry`).
- **`/pro.go` Phase 0 — Run Start**: stamps the run marker and reads **`.knowledge/improvements.md`** (the committed cross-run memory) so the run applies what past runs learned.
- **`/pro.go` Phase 6 — parallel implement loop** (opt-in, off by default): when `parallel.phases.implement: true`, independent **`[P]`** (file-disjoint) tasks in a work-unit fan out across concurrent in-harness sub-agents — the same engine previously only used by `/pro.scan` — instead of running one work-unit at a time. Non-`[P]` work stays serial; failed/timed-out workers leave their task open (never silently dropped); circuit-breaker on consecutive failures.
- **`/pro.go` Phase 8 — Run Report & Self-Improvement**: generates the run report, appends a curated, actionable learning to `.knowledge/improvements.md` (read back at Phase 0 — the closed loop), and prints the trend dashboard. The completion banner now shows duration, files/lines, commits, iterations, parallel mode, and eval verdict.
- Config: new **`reporting:`** block (`enabled`, `run_report`, `runs_log`, `self_improve`, `improvements_file`, `aggregate_on_finish`) and **`parallel.phases.implement`** in `pro-config.template.yml`. `/pro.local-metrics` now points at the run-level logs and `pro-report.sh aggregate`.
- Seeded **`.knowledge/improvements.md`** (committed cross-run memory; explains the read-at-0 / write-at-8 loop and the actionable-learning format).

## [1.21.1] — 2026-06-05

Patch: **`update-all.sh` step 5 now runs unattended.** Reinstalling pro from its GitHub archive triggers spec-kit's "Untrusted Source" confirmation, which `--force` does not suppress — under `set -e` the script aborted before reinstalling pro (caught by a live end-to-end test, not the static review). The pro-install step now auto-confirms the prompt (it is our own published release), so the full upgrade completes headlessly. Verified against a real project: pro 1.19 → 1.21, `pro-config.yml` preserved byte-for-byte across the pro-dir replacement, `git` extension re-registered, `specs/`/`.knowledge/` untouched.

## [1.21] — 2026-06-05

Focus: **one-command full-stack upgrade** — keep the `specify` CLI, base Spec Kit templates, agent integrations, and pro itself current in a single pass.

- New helper **`scripts/bash/update-all.sh`**: runs `specify self upgrade` → `specify init . --force` (latest templates/scripts) → re-installs agents + catalog extensions that the registry rebuild drops → reinstalls pro from `latest` (or a pinned `--pin <tag>`). Supports multiple agents (`update-all.sh claude copilot gemini`; first = default integration), `--no-base` to skip the template refresh, and refuses to run inside the pro source repo.
- Snapshots and restores the only non-regenerable, gitignored artifacts under `.specify/` (an authored `constitution.md` and `pro-config*.yml`); `specs/` and `.knowledge/` are never touched. Empirically verified that `specify init . --force` regenerates `.specify/extensions/.registry` and drops extensions it does not itself reinstall — so the script re-registers them and reports any it could not restore (non-zero exit).
- **`README.md`** — "Installation & updates" now documents in-place `--force` updates (no separate `remove` needed) and the full-stack `update-all.sh`.

## [1.20] — 2026-06-05

Focus: **adaptive parallel deep-analysis engine** — split deep code analysis into dependency-clustered portions and run them across concurrent workers, merged (with a tie-breaker) into one report.

- New command **`/speckit.pro.scan`**: partitions the repo (dependency clustering, size-bucket fallback, oversized pre-split), fans portions out across concurrent workers, merges into `.knowledge/scan/latest.md` (+ timestamped archive) with a mandatory Coverage Ledger (no silent gaps). Offers durable findings to `.knowledge/` via the additive/proposal path only.
- **Adaptive substrate**: in-harness sub-agent workers when run as a skill; headless agent-CLI worker processes from a terminal (`scripts/bash/pro-scan.sh`); sequential fallback. Auto-detected, overridable, pluggable for a future remote backend. Never aborts solely for lack of parallelism.
- Engine internals: `scripts/local/partition.py` (deterministic partitioner), `scripts/bash/lib/pro-fanout-common.sh` (bounded worker pool + manual timeout + circuit breaker + JSONL telemetry), `scripts/local/scan_report.py` (atomic, lock-guarded report writer), `scripts/local/validate_schemas.py`.
- **Phase retrofit (opt-in, off by default)**: `parallel.phases.analyze` runs a fan-out pre-pass that feeds native `/speckit.analyze` (the native command is never forked). `local_prep`/`deepen`/`prime` reuse the same seam.
- Config: new `parallel:` block (`pro-config.template.yml` + `extension.yml` defaults). Telemetry aggregated by `/pro.local-metrics` (worker latency p50/p95, failure rate).

## [1.19] — 2026-05-28

Focus: **`knowledge-sync` wired through `/pro.go` and sibling processes** — prime/sync are mandatory pipeline steps when `knowledge.enabled: true`, not hook-only side effects.

**Install / update:** use the moving tag **`latest`** (always points at the newest release):
`specify extension add pro --from https://github.com/gen-by-ai/speckit-pro/archive/refs/tags/latest.zip`
Pin a version with `v1.19.0.zip` if you need reproducibility. Maintainers: `./scripts/bash/release-tag.sh vX.Y.Z` then push version tag + `git push origin refs/tags/latest --force`.

### Added
- **`pro.go.md` Phase 7** — post-implement chain: reconcile → local-review → evaluate → knowledge-sync (sync only on PASS).
- **`knowledge.prime_before_contract`** — prime after `/speckit.tasks`, before `/pro.contract`.

### Changed
- **`pro.go.md`** — knowledge integration table; Phase 6 step 0 primes each loop iteration; run-plan banner lists all prime/sync touchpoints.
- **`pro.pickup.md`**, **`pro.resume.md`**, **`pro.loop.md`** — document Phase 7 and pickup post-loop sync.
- **`pro-orchestrate.sh`** — prints Phase 7 reminder after implement-complete.
- **`README.md`** — pipeline diagram shows knowledge-sync inside `/pro.go`.

## [1.18] — 2026-05-28

### Changed
- **`local_models.enabled`** defaults to **`true`** in `pro-config.template.yml` and `extension.yml`. Local prep/review is the established pattern; commands self-skip in ~3s when Ollama is unreachable — pipeline never aborts. Set `false` only to disable local offload entirely.

## [1.17] — 2026-05-28

Focus: **automated knowledge layout migration** — one command for agents to move legacy paths and update project config.

### Added
- **`/speckit.pro.knowledge-migrate`** (`commands/pro.knowledge-migrate.md`, `scripts/bash/pro-knowledge-migrate.sh`) — dry-run + apply migration from `.repo-knowledge/` and `.ai-knowledge/` to `.knowledge/`; updates `.gitignore`; bootstraps missing `INDEX.md`; writes `.knowledge/MIGRATION-REPORT.md`. Agent checklist includes `pro-config.yml` patches and a suggested git commit scope.
- Registered in **`extension.yml`** (v1.17).

## [1.16] — 2026-05-28

Focus: **unify `.repo-knowledge/` and `.ai-knowledge/` into a single `.knowledge/` tree** — one mental model, two git visibility zones.

### Changed
- **Single root `.knowledge/`** — shared team docs at root (commit); per-feature workspace at **`features/<slug>/`** (gitignore); telemetry at **`metrics/local-metrics.jsonl`**.
- **CLI arg** `ai-knowledge-dir` → **`knowledge-feature-dir`**; env paths **`FEATURE_KNOWLEDGE_DIR`** = `.knowledge/features/<feature>`.
- **Bootstrap templates** moved to `templates/knowledge/` (legacy `templates/repo-knowledge/` still accepted).
- **Legacy resolution** — commands still read `.repo-knowledge/` and `.ai-knowledge/<feature>/` if the unified paths are not migrated yet.
- **`README.md`** — merged knowledge sections; best-practices #14–15 collapsed into one item.

### Migration
```bash
mkdir -p .knowledge/features .knowledge/metrics
[ -d .repo-knowledge ] && mv .repo-knowledge/* .knowledge/ 2>/dev/null; rmdir .repo-knowledge 2>/dev/null
[ -d .ai-knowledge ] && mv .ai-knowledge/* .knowledge/features/ 2>/dev/null; rmdir .ai-knowledge 2>/dev/null
```

## [1.15] — 2026-05-28

Focus: **make `.repo-knowledge/` a first-class participant in the pipeline** — not an opt-in sidecar teams forget to enable.

### Added
- **`--mode bootstrap`** on **`/speckit.pro.knowledge-sync`** — seeds `.repo-knowledge/` from `templates/repo-knowledge/` (never overwrites existing files).
- **`knowledge.auto_bootstrap`** (default `true`) — creates the starter tree on first prime when the directory is missing.
- **`knowledge.prime_before_implement`**, **`knowledge.prime_each_loop_iteration`** — additional prime touchpoints.
- **Hook wiring** (`.specify/extensions.yml`) — `before_plan` and `before_implement` fire knowledge prime.
- **Starter templates** — `templates/repo-knowledge/` (+ mirror under `.specify/extensions/pro/templates/`).
- **Command integration** — `/pro.loop`, `/pro.contract`, `/pro.evaluate`, `/pro.reconcile`, and `/pro.pickup` now explicitly load or enforce `.repo-knowledge/` (invariants, glossary, architecture, ADRs).

### Changed
- **`knowledge.enabled`** defaults to **`true`** in `pro-config.template.yml` and `extension.yml`.
- **`knowledge.prime_before_plan`** defaults to **`true`**; `/pro.go` adds Phase 2.5 (prime before plan) and Phase 5a (prime before implement).
- **Prime retrieval** always includes `domain/invariants.md` and `domain/glossary.md` when present.
- **`README.md`** — adoption path and hook table updated for active knowledge usage.

## [1.14] — 2026-05-28

Focus: **remove optional `repo-ai` embedding index** — the vendored CLI added maintenance surface (Node deps, model download, index rebuilds) without enough adoption to justify keeping it in the extension bundle.

### Removed
- **`repo-ai/`** package (local MiniLM embeddings CLI, `vectordb/`, `embeddings.jsonl`).
- **`.agents/skills/repo-ai-cli/SKILL.md`** — agent skill for the CLI.
- **`--refresh-repo-ai`** flag and optional retrieval steps from **`/speckit.pro.reconcile`** and **`/speckit.pro.knowledge-sync`**.

### Changed
- **`/speckit.pro.knowledge-sync --mode prime`** — retrieval is **grep + INDEX.md link follow** only (same deterministic path that was previously the fallback).
- **`/speckit.pro.deepen`** Tier A sources — `.repo-knowledge/` and codebase use **grep** only.
- **`README.md`** — dropped “Local knowledge index” section; `.repo-knowledge/` docs updated accordingly.
- **`extension.yml`** — version **1.14**.

## [1.13] — 2026-05-26

Focus: **token offload via local Ollama sidecar + layer-1 measurement framework**. The Claude extension is great for interactive work, but as Pro usage grows the Claude-as-control-plane pattern starts costing real tokens for mostly-deterministic Markdown work: repo maps, context packs, risk registers, test strategies, task packets, first-pass review screens. v1.13 moves that work to local Ollama models and reframes Claude as a premium worker. From `.dev-work/dev.md`: "Claude should become a premium worker, not the whole factory." Local artifacts come with a provenance banner; Claude verifies before anything ships. MDASH-inspired evidence-pack discipline (`.dev-work/learning.md`) keeps the first-pass review signal-to-noise high. Layer-1 telemetry (JSONL + `/pro.local-metrics`) makes "is the local stack worth keeping" measurable instead of vibes.

### Added — sidecar (token offload)
- **`/speckit.pro.local-prep`** (`commands/pro.local-prep.md`, `scripts/bash/pro-local-prep.sh`, `scripts/local/ollama-md.py`) — runs local Ollama workers to produce the prep-phase Markdown that the Claude loop would otherwise generate inline. Writes `repo-map.md`, `risk-register.md`, `test-strategy.md`, `open-questions.md`, `context-pack.md` under `<SPEC_DIR>/`. Generates `repo-map.md` first (other artifacts read it), then risk register / test strategy / open questions, then `context-pack.md` last (compiled from everything above + `.repo-knowledge/INDEX.md` if present). Driver self-skips and exits 0 if `local_models.enabled: false` or Ollama isn't reachable — never aborts the parent pipeline.
- **`/speckit.pro.local-review`** (`commands/pro.local-review.md`, `scripts/bash/pro-local-review.sh`) — first-pass implementation / test-gap / security review by local Ollama models. Writes `implementation-review.md`, `test-gap-review.md`, `security-review.md` under `<SPEC_DIR>/local-reviews/`. Each finding requires a full evidence pack (file, lines, severity, category, what, evidence quote, why-it-matters, suggested patch, confidence, disproof, AC #) — a finding without a file and a line range is dropped. MDASH lesson 12 baked into the prompts: low false-positive rate is the first-class design goal.
- **`/speckit.pro.materialize`** (`commands/pro.materialize.md`, `scripts/bash/pro-materialize.sh`) — splits `tasks.md` into per-task packets at `<SPEC_DIR>/task-packets/TASK-NNN-<slug>.md`. Local-model refined when Ollama is available; deterministic skeleton (same shape, `UNKNOWN` placeholders) when not. The implement loop can then load `task-packets/TASK-<current>-<slug>.md` instead of re-reading spec+plan+tasks for every work unit.
- **`scripts/local/ollama-md.py`** — thin HTTP client for Ollama `/api/chat`. Handles unreachable / model-not-pulled / timeout with distinct exit codes (2 / 3 / 4) so the bash drivers can give precise warnings. Prepends a provenance banner ("Generated by local model `<name>`. Claims require verification before implementation.") to every output. Banner is intentional: it stops downstream agents (and humans in PR review) from treating local output as ground truth.
- **`scripts/bash/lib/pro-local-common.sh`** — shared bash library: project-root + spec-dir resolution, shallow YAML reader for `local_models.*`, per-task model routing, reachability check, `local_run_task` wrapper, `local_emit_skip` for telemetry. No yq dependency; uses Python's stdlib.
- **8 prompt templates under `templates/local/`** — `repo-map`, `context-pack`, `task-packet`, `test-strategy`, `risk-register`, `open-questions`, `implementation-review`, `test-gap-review`, `security-review`. Each template has tight output contracts ("output begins at H1 X with no preamble", "if a fact is not in CONTEXT, write UNKNOWN", explicit section list). Local 7B models need tight contracts; the templates enforce them.
- **`local_models:` config block** (`pro-config.template.yml`, `extension.yml` defaults) — master switch (off by default), per-task model routing (default / fast / code / review / security), base URL (defaults to `http://localhost:11434`, honors `OLLAMA_BASE_URL`), timeout / num_ctx / temperature, per-task on/off switches, and `auto_run` toggles for `after_tasks` and `before_evaluate`.
- **Phase 4b — Local Prep** in `pro.go.md` — automatically runs `/pro.local-prep` then `/pro.materialize` after `/speckit.tasks` when `local_models.enabled: true` and `local_models.auto_run.after_tasks: true`. Skips silently otherwise.
- **Phase 6b — Local Review** in `pro.go.md` — automatically runs `/pro.local-review` after the implement loop and before `/pro.evaluate` when `local_models.enabled: true` and `local_models.auto_run.before_evaluate: true`.
- **Implement-loop context-load priority updated** (`pro.go.md` Phase 6 step 1) — context-pack.md (when present) is now preferred over spec+plan+tasks as the lean substitute, and the matching `task-packets/TASK-<id>-<slug>.md` is loaded alongside the work-unit context.

### Added — measurement (layer-1 telemetry)
- **JSONL telemetry in `ollama-md.py`** — every Ollama invocation, success or failure, appends one record to a configurable JSONL file. Schema: `{type:"call", ts, feature, task, model, num_ctx, temperature, timeout_s, prompt_bytes, output_bytes, wall_ms, exit_code, error}`. Failures emit `output_bytes:0` + the captured error string, so degenerate cases (model not pulled, timeout, unreachable) are visible in the dashboard. New flags: `--task <name>`, `--feature <slug>`, `--metrics-file <path>` (also reads `$SPECKIT_PRO_METRICS_FILE`). `--feature` is inferred from the out-file path when omitted (matches `…/specs/<slug>/…`). Telemetry writes are best-effort: any I/O error is swallowed silently so a flaky disk never breaks a user-facing run.
- **Refactored `ollama-md.py` exit handling** — `OllamaError(code, msg)` replaces inline `sys.exit()` calls so every exit path (success, error, timeout, I/O) routes through one metrics-emit point. Previously failures bypassed any future telemetry hook.
- **Bash driver wiring for telemetry** (`scripts/bash/lib/pro-local-common.sh`) — `local_load_config` resolves `local_models.metrics_file` (relative paths against project root) and `local_models.telemetry` (default `true`), exports `SPECKIT_PRO_METRICS_FILE`, and `local_run_task` passes `--task` + `--feature` + `--metrics-file` to `ollama-md.py`. Drivers set `LOCAL_FEATURE` from the spec dir's basename so multi-feature workspaces aggregate correctly. `pro-materialize.sh` (which calls `ollama-md.py` directly for task packets) also passes the same flags.
- **Step 4c in `commands/pro.evaluate.md` — Local-Review Verdict Capture** — when `<FEATURE_DIR>/local-reviews/` exists, the evaluator now writes one `{type:"verdict"}` JSONL line per local finding into the same metrics file. Four verdicts: `agreed`, `kept` (real but severity differs — `severity_delta` captures), `dropped` (false positive), `unverifiable` (insufficient evidence). Crucially, the step also requires logging `missed` events for findings the evaluator caught fresh that the local model didn't surface — recall is undefined without these. The step is telemetry-only: verdict counts do not change PASS/NEEDS_REVISION/FAIL (the hard gates already decided severity).
- **`/speckit.pro.local-metrics`** (`commands/pro.local-metrics.md`, `scripts/bash/pro-local-metrics.sh`) — read-only dashboard that aggregates the JSONL file and prints: per-task call count, p50/p95 wall-time, failure rate, models used, byte totals; per-review-type precision = `(agreed+kept) / (agreed+kept+dropped)` and recall = `(agreed+kept) / (agreed+kept+missed)`; top dropped finding signatures (false-positive prone shapes). Filters: `--since 30d|7d|24h|all`, `--feature <slug>`, `--task <name>`. `--json` mode emits machine-readable output for piping into charts. Pure Python — no Claude calls, no Ollama calls, no state mutation.
- **`local_models.telemetry`** + **`local_models.metrics_file`** config keys (`pro-config.template.yml`, `extension.yml` defaults) — default `true` and `.ai-knowledge/local-metrics.jsonl` respectively. The default location is under `.ai-knowledge/` (workspace-only, gitignored).
- **Skip-event emission** (`scripts/bash/lib/pro-local-common.sh` `local_emit_skip`) — when a driver (`pro-local-prep.sh`, `pro-local-review.sh`, `pro-materialize.sh`) self-skips because Ollama is unreachable, it now writes one `{type:"skip", driver, reason:"ollama-unreachable", base_url}` JSONL line. This makes "how often did we want the local stack but couldn't reach it" a first-class signal in the dashboard's AVAILABILITY section. One event per driver run (not per task) — avoids flooding the file when the daemon is down. Disabled-by-config skips are NOT logged (user intent, not a problem to track).

### Changed
- `extension.yml` — version bumped to **1.13**, description updated to mention the Ollama sidecar; four new commands registered (`pro.local-prep`, `pro.local-review`, `pro.materialize`, `pro.local-metrics`); defaults block extended with `local_models.*` including `telemetry: true` and `metrics_file`; hook comments updated to document the new chain order (`after_tasks` → contract → local-prep → materialize; `after_implement` → reconcile → local-review → evaluate → knowledge-sync).
- `commands/pro.go.md` — run-plan banner updated to show Phase 4b and Phase 6b; Phase 6 context-load step rewritten to prefer the local-prep artifacts when present.
- `README.md` — new **Quick Guide** section (day-to-day commands, recommended flow, setup checklist, command cheat sheet, three patterns that catch most cases); new **Local Ollama sidecar** section covering setup, what gets written in Phase 4b vs 6b, evidence-pack discipline, graceful degradation, order of adoption, telemetry subsection with dashboard preview, "how to read the signal" symptom→cause→action table, and roadmap; two new Best Practices items for incrementally turning on the sidecar and reading metrics weekly while tuning. Two new rows in the Why comparison table for the sidecar and metrics.

### Roadmap (deliberately not in this release)
- **Layer 2 — Golden bench (`benchmarks/local/`)**: 2–3 fixed spec/plan/tasks bundles re-run on every prompt-template change to detect template regressions. Maps to MDASH lesson 4 (private ground-truth corpora). Worth building once layer-1 data shows which prompts are unstable.
- **Layer 3 — A/B model routing**: two models compete per task; metrics decide the winner. Worth building once layer 2 is stable and we have an actual model-choice question to answer with data.

Layer 1 needs real usage before we know which signals matter, so layers 2 and 3 are intentionally out of scope for this release. The `/pro.local-metrics` doc lists them as a roadmap so future-us has a starting point.

### Why
Two observations from running SpecKit Pro at scale:

1. **The control plane was the cost.** Every prep artifact Claude generates inline costs tokens that compound across every feature and every iteration. Most of that work (file listing → relevance summary, task line → packet skeleton, diff → finding shape) is mostly-deterministic Markdown, exactly the kind of work a local 7B-class model does well. Moving it to Ollama cuts the per-feature token bill without losing the artifacts.
2. **First-pass review is the right place to use a cheaper model.** A local model that produces "here are 4 candidate findings with evidence packs, evaluator please verify" is more useful than no review at all, and dramatically cheaper than asking Claude to read the whole diff cold. The MDASH lesson (`.dev-work/learning.md`) applies: one agent finding something is weak; that finding surviving an independent verifier is stronger. The evidence-pack contract makes the local model's drafts auditable rather than hand-wavy.

The release intentionally has **no breaking changes and no new defaults that fire without configuration**. Everything is opt-in via `local_models.enabled: true`. If Ollama isn't installed or running, the new commands self-skip with a one-line note and the existing pipeline behaves exactly as it did in v1.12.

## [1.12.0] — 2026-05-22

Focus: **execution-time full implementation**. The earlier releases attacked the upstream cause (thin specs → thin tasks) and the orchestration cause (loop hygiene, evaluator independence, drift reconcile). v1.12 closes the remaining gap: a sprint can still ship a happy-path-only implementation that breaks the moment a real user lands on it in an unexpected state. The release was prompted by a real incident — a 4-line `if (invalid) return;` guard was added to a payment hook without firing the consumer's `onFailure()` callback, leaving the consumer's reducer stuck on `loading: true` forever. Happy path worked. Edge case rendered a blank UI in production for 4 days. v1.12 makes that class of bug structurally unshippable.

### Added
- **Edge Cases & Failure States** — required 12th section in the `/speckit.pro.deepen` depth checklist (`commands/pro.deepen.md`). For every primary user flow the spec must enumerate cells from a six-axis matrix: Inputs (empty, invalid, boundary), Authorization (logged out, expired, insufficient role, cross-tenant), Network (offline, slow, 4xx, 5xx, timeout), Concurrency (stale data, optimistic collision, double-submit), Re-entry (back button, refresh, deep link, suspend), State hydration (undefined Redux slice, empty cache, missing cookie). Each cell needs an explicit expected-behavior statement an evaluator can verify by clicking the live app. `N/A — <reason>` is acceptable; silent skip is not. Edge-case gaps move to the top of the human-question prioritization list.
- **Sprint-contract schema overhaul** (`commands/pro.contract.md`, `templates/contract-template.md`) — Acceptance Criteria table gains four new columns: **User Flow**, **State**, **Failure Mode** (`silent` | `loud`), and **Browser Test** (path of the agent-browser script that asserts the row). Every user-facing flow must have one happy-path row + ≥3 edge-case rows drawn from distinct matrix axes. Every new branch in the diff (guard, short-circuit, early return) must add a row asserting that branch's behavior — the structural fix for the MP-1435 class of bug. `silent` failure-mode rows are auto-promoted to CRITICAL regardless of typed severity, because silent regressions are the worst class (no monitoring catches them).
- **`browser-tests/` as a durable artifact** (`templates/browser-test-template.sh`) — every CRITICAL contract row gets a replayable shell script under `<spec-dir>/browser-tests/<flow>/<NN>-<state>.sh`. The loop writes them, the evaluator runs them, every future sprint re-runs them for regression carry-forward. Scripts are hermetic (clear `localStorage`/`sessionStorage`/cookies on entry), time-boxed (max 10s waits), single-assertion (one row per script — multi-assert is forbidden because it hides which row regressed), and re-runnable (a re-run on a clean build must produce the same verdict).
- **TDD-first implementation protocol** (`commands/pro.loop.md`) — for each contract row, the loop must write the Browser Test script and the Verified By unit/integration test **before** the implementation, confirm both fail, implement, confirm both pass. A task cannot be marked `[x]` until its Browser Test script exists and passes. Marking a task done with no script is a contract violation and produces NEEDS_REVISION.
- **Branching control-flow rule** (`commands/pro.loop.md`) — when a diff introduces a new branch into an existing function, the loop pauses and emits `<pro-uncertainty>` if the contract has no row asserting the new branch's behavior. The loop then appends rows to the contract before continuing. Exact structural protection against MP-1435.
- **Stub & no-op self-check** (`commands/pro.loop.md`) — the loop scans its own diff for `TODO`/`FIXME`/`XXX`/`HACK`, `throw new Error('not implemented')`, empty function bodies, empty JSX renders (`<></>`, `null` returns), and silent `catch` blocks before signaling `CONTINUE`. Matches in non-test files block the signal.
- **Mandatory script-suite browser pass** in evaluator (`commands/pro.evaluate.md` Step 3) — replaces the previous ad-hoc walkthrough. The evaluator runs every script the sprint's contract references, not its own improvised probes. The contract is the source of truth; the evaluator executes it.
- **Regression Carry-Forward** in evaluator (`commands/pro.evaluate.md` Step 3b) — every sprint runs **all prior sprints'** browser-test scripts, not just its own. A sprint that re-breaks an earlier sprint's behavior triggers `NEEDS_REVISION:regression-carryforward-failed` regardless of how good its own work is. Closes the loop on regressions like MP-1435 where a later change silently broke a prior contract.
- **Step 4a — Stub & No-op Detection auto-FAIL** (`commands/pro.evaluate.md`) — automated greps for stubs, placeholder returns, silent catches, empty function bodies, and empty JSX renders in non-test files. Any match is an automatic `FAIL:stub-detected:<file>:<line>` — no scoring discretion. Test files exempt.
- **Step 4b — Dangling File Detection** (`commands/pro.evaluate.md`) — new files (excluding routes/pages, tests, templates) must have at least one inbound `import` / `require` / `from`. Files with zero inbound references are stubs in disguise and trigger `NEEDS_REVISION:dangling-file:<path>`.
- **Branch-symmetry static review** (`commands/pro.evaluate.md` Step 4) — every new branch in the diff must have a contract row covering it. Missing row triggers `NEEDS_REVISION:unrostered-branch:<file>:<line>`.
- **Hard-gate matrix** (`commands/pro.evaluate.md`) — six gates that bypass scoring entirely when they fail: app-not-startable, critical-browser-test-failed, regression-carryforward-failed, stub-detected, dangling-file, unrostered-branch. Scoring only applies to sprints that cleared all hard gates.
- **Evaluation criteria weights rebalanced** (`commands/pro.evaluate.md`) — Browser-Test Coverage promoted to 35% (was 0%). Contract Completeness 25% (was 40%). Correctness 20% (was 30%). Code Quality 10% (was 20%, plus stub detection moved to hard gate). Spec Alignment 5%. Revisability 5%. Reflects that *demonstrated* coverage of edge cases is worth more than *claimed* completeness.

### Changed
- `extension.yml` — version bumped to **1.12.0**, description updated to surface the new execution-quality features.
- `commands/pro.contract.md` — Step 5b added (scaffold `browser-tests/<flow>/` directories before the loop starts writing scripts; copy `templates/browser-test-template.sh` into the spec dir for reference).
- `templates/contract-template.md` — table schema rewritten to match the new row format with all eight columns, severity guide expanded with failure-mode definitions, Definition of Done expanded with regression-carryforward + stub-free invariants, new Edge-Case Waivers section.

### Why
Three observations from running SpecKit Pro in production this quarter:

1. **Edge cases die at the spec layer.** `/speckit.specify` produces a thin spec; `/pro.deepen` (v1.11) audits the spec but its checklist did not require explicit edge-case enumeration. So the loop implemented what the spec named and shipped the rest as silent gaps. Adding an Edge Cases & Failure States section to the depth checklist forces the spec to name them; everything downstream then has something concrete to verify.
2. **Sprint contracts graded the wrong thing.** The previous contract schema asked "does the criterion pass?" without requiring a runnable assertion. An evaluator who "tested it" via reading code could pass a sprint that would fail when a user actually visited the page with an empty Redux store. Moving every CRITICAL row to a runnable agent-browser script collapses "the evaluator's judgement" to "did this script return exit 0," which is both faster and harder to fake.
3. **Regression carry-forward was the missing structural piece.** Each sprint's browser-test scripts were ephemeral — the evaluator clicked through, signed off, the test evaporated. A future sprint could silently re-break a behavior the earlier sprint had asserted. Persisting the scripts under `browser-tests/` and re-running the full suite every evaluator pass is what makes MP-1435 unshippable in v1.12: the script that fails for the empty-Redux-store state would have flagged the missing `onFailure()` call before the PR could merge.

The release intentionally has **no new commands and no new hooks** — the lever is tightening the artifacts the existing commands are required to produce. That keeps the surface area small and the upgrade path frictionless: existing features without `browser-tests/` directories just won't have any to run; the regression net activates as new sprints populate it.

## [1.11.0] — 2026-05-14

Focus: **spec depth at generation time**. The earlier releases added sophistication to the *execution* side (loop, evaluator, contracts, drift reconciliation, knowledge sync). But thin specs produce thin tasks, and thin tasks produce an implement loop that quietly drops helpers, validation, error paths, audit logging, and small code parts nobody wrote down. v1.11 attacks the upstream cause: the spec template asks for user stories + a handful of FRs and nothing else, so the agent fills exactly that and stops. The new `/speckit.pro.deepen` interrogates the draft spec against a depth checklist *before* it reaches clarify, investigates each gap autonomously from any source it can reach, and asks the operator only what no source can answer.

### Added
- **`/speckit.pro.deepen`** (`commands/pro.deepen.md`) — adversarial spec auditor with **capability-based source discovery** (no organization or vendor names hardcoded anywhere — the command describes the *kind* of source it needs and matches available tools at run time). Three modes:
  - **Investigate** (default) — read `spec.md` against a depth checklist with eleven required sections (data model, invariants, failure modes, side effects, authorization, idempotency, audit, integration boundaries, domain glossary, performance, out-of-scope). Classify each as COMPLETE / PARTIAL / MISSING, generate specific questions for each gap.
  - **`--apply`** — read the now-answered `spec-questions.md` plus the cited `spec-patches.md`, merge into `spec.md` as a single staged git diff (never auto-commit). Blocks if any question is unanswered or any medium-confidence patch lacks APPROVED/REJECTED annotation.
  - **`--quick`** — local sources only, skip external capability lookups.
- **Two-tier source model** with the **cite-or-escalate** principle:
  - **Tier A (always)**: `.repo-knowledge/`, codebase (via `repo-ai`+grep), sibling `specs/*/`, last 90 days of git history on related paths.
  - **Tier B (capability-discovered, opt-in)**: any tool whose name matches issue-tracker / docs / discussion / external-code-search patterns. The capability table is the *only* place tool names are referenced; the rest of the command operates on capability handles, so the same command works for any team's stack without modification.
  - **Refuses to invent.** Every proposed patch must cite ≥1 source (`code:file:line`, `issue:<id>`, `docs:<title>`, …). No source → it's a question for the human, never invented prose.
- **Per-feature output files** (mirrors `pro-drift.md` and `pro-knowledge.md` patterns):
  - `<FEATURE_DIR>/spec-patches.md` — cited proposals with high/medium confidence tagging
  - `<FEATURE_DIR>/spec-questions.md` — ≤10 sharp human-input questions, multiple-choice where possible
- **Hard time budget** — 300s total, 30s per source, configurable per-run. Investigation is not a research project; it is a sharp tool.
- **Phase 1c — Deepen** (`pro.go.md`) — new optional phase between `/speckit.specify` and `/speckit.clarify`. Pauses the pipeline for human input (the whole point is to challenge the spec before downstream phases consume it). Skipped silently when `deepen.enabled: false` (default). Run-plan banner updated.
- **Hook wiring** (`extension.yml`, `.specify/extensions.yml`) — new `after_specify` entry firing `speckit.pro.deepen` before the auto-commit and before `/speckit.clarify`.
- **`deepen:` config block** (`pro-config.template.yml`, `extension.yml` defaults) — toggles for `enabled` (off by default), `run_after_specify`, `time_budget_seconds`, `per_source_budget_seconds`, `max_questions`, and a `sources.*` map with per-category opt-in (`true`/`false` for local sources, `auto`/`off` for capability-discovered external sources).
- **README**:
  - New comparison-table row (thin specs → adversarial deepen).
  - New Hook Commands table entry.
  - Phase list under Option A updated to surface Phase 1c.
  - Extension Structure tree registers `pro.deepen.md`, `spec-patches.md`, `spec-questions.md`.
  - New Best Practices bullet (#13: use `/pro.deepen` on any non-trivial feature).
- **`extension.yml`** — version bumped to **1.11.0**; `speckit.pro.deepen` registered; description updated.

### Why
Three observations from running SpecKit Pro in production drove this release:

1. **Generated specs are shallow because the template is shallow.** Native SpecKit's `spec-template.md` requires user stories, ~5 example FRs, and two example "Key Entities" — and that's it. No required sections for data model, invariants, failure modes, side effects, glossary, authorization, or audit. The agent fills what's asked and stops. No amount of downstream orchestration (loop sophistication, evaluators, contracts, drift reconcile) compensates for the spec never having captured the thinking in the first place.
2. **"Small code parts being missed" is a thin-spec symptom, not a loop bug.** The implement loop ticks off the work units it can see in `tasks.md`. If the spec never mentioned the audit log, the validation helper, the idempotency key, the retry envelope, or the error class — `tasks.md` won't have them, and the loop won't implement them. Fixing this at the loop level is whack-a-mole; fixing it at the spec level is the lever.
3. **AI is bad at substituting for the deep thinking phase, but good at scaffolding it.** `/speckit.clarify` asks "are there any clarifying questions?" and gets a couple of generic ones. Asking the agent "investigate each section against this depth checklist, look up what you can from sources, and ask the human only what no source can answer" produces a structured interrogation that genuinely deepens the spec — and respects the human's time by escalating only undecidable questions, with multiple-choice options when possible.

The pattern intentionally **opts in** (`deepen.enabled: false` by default). It adds 5–10 minutes of operator time per feature upfront in exchange for a spec that survives contact with implementation. Prototyping workflows can keep it off; serious features should turn it on.

The pattern also lands more value as `.repo-knowledge/` matures (v1.10's contribution) — the deepener's first stop is the curated knowledge base, so the more bounded contexts and invariants are documented there, the fewer questions the operator gets asked.

## [1.10.0] — 2026-05-14

Focus: **repo-level knowledge**. v1.9 closed the spec-vs-code drift gap; v1.10 closes the layer above — *what the business means*, *which bounded contexts own what*, *which invariants must never break* — the context that doesn't live in any single feature spec and that the loop otherwise has to rediscover every iteration.

### Added
- **`/speckit.pro.knowledge-sync`** (`commands/pro.knowledge-sync.md`) — two-mode command for maintaining a versioned, curated `.repo-knowledge/` knowledge base:
  - **`--mode prime`** (read) — fires from `before_specify` (and at the top of `/pro.go` / `/pro.pickup`). Retrieves the top-k chunks from `.repo-knowledge/` relevant to the new feature via `repo-ai search`, surfaces them as a `<pro-knowledge-prime>` block so the agent doesn't reinvent terms, violate invariants, or duplicate a bounded context in the spec it's about to write. Falls back to INDEX.md grep when `repo-ai` is unavailable.
  - **`--mode sync`** (write) — fires from `after_implement`, **last in the chain after `pro.evaluate`**. Self-skips unless the evaluator returned `PASS` (so docs are never updated against unverified code). Diffs the sprint vs `.repo-knowledge/` claims and writes `<FEATURE_DIR>/pro-knowledge.md` with three-tier proposals: **additive** (new endpoints, glossary terms — eligible for auto-apply per policy), **clarifying** (existing descriptions now imprecise — always review-only), and **breaking** (invariant or ADR conflicts — always review-only, blocks merge). Never auto-edits `decisions/`, `invariants.md`, or `domain/*`.
  - **Cost short-circuits** — exits early when only tests/fixtures changed, when `.repo-knowledge/` doesn't exist, or when no `.repo-knowledge/` file references the changed paths. Most sprints don't move the knowledge needle.
  - **ADR scaffolding** — when a `breaking` proposal exists, drafts `<FEATURE_DIR>/pro-knowledge-adr-draft.md` so the cost of recording a decision is lower than the cost of ignoring it.
- **Hook wiring** (`extension.yml`, `.specify/extensions.yml`):
  - `before_specify` — new entry firing `speckit.pro.knowledge-sync --mode prime`.
  - `after_implement` — chain extended: `git.commit → pro.reconcile → pro.evaluate → pro.knowledge-sync`.
- **Phase 0 — Knowledge Prime** (`pro.go.md`) — new optional first step in `/pro.go`'s pipeline. Skipped silently when `knowledge.enabled: false` (default) or `.repo-knowledge/` is missing. Updated run-plan banner and completion footer to surface the new phase and post-loop sync step.
- **`knowledge:` config block** (`pro-config.template.yml`, `extension.yml` defaults) — seven toggles: `enabled` (master switch, default off), `prime_before_specify`, `prime_before_plan` (off — re-prime only when plan widens scope), `sync_after_evaluate`, `auto_apply_tier` (`none` | `additive` — never destructive), `sync_writes_to`, `root_dir` (default `.repo-knowledge`).
- **`.repo-knowledge/` directory convention** — versioned in git, distinct from `.ai-knowledge/` (workspace-only). Layout: `INDEX.md` (decision tree), `architecture.md`, `domain/` (glossary + bounded contexts + invariants), `decisions/` (ADRs), `runbooks/`.
- **README**:
  - New "Repo-level knowledge base" section documenting the layout, hook positions, and design rules.
  - New comparison-table row, new Hook Commands entry, new Best Practices bullet (#13: seed before enabling).
  - Loop diagram updated with the KNOWLEDGE box between EVALUATOR and the status-tag parse.
  - Extension Structure tree updated to register `pro.knowledge-sync.md`, `pro-knowledge.md`, and the `.repo-knowledge/` tree.
- **`extension.yml`** — version bumped to **1.10.0**; `speckit.pro.knowledge-sync` registered.

### Why
v1.8 fixed the *entry-point* problem (features stuck at `/tasks` never starting the loop). v1.9 fixed the *spec drift* problem (specs silently lying about code). v1.10 fixes the layer above both: the loop has no repo-wide memory of business meaning. Every new feature rediscovers domain terms, sometimes inventing new ones, sometimes violating invariants that exist in code but not in any document the agent loads. `.repo-knowledge/` is the human-curated ground truth; `pro.knowledge-sync` keeps it from rotting by proposing — never silently committing — updates after each verified sprint.

The pattern intentionally **opts in**. Disabled by default: an empty knowledge base produces empty primes (harmless but pointless), and an auto-generated one full of unreviewed slop is worse than nothing — the loop will trust its own guesses. The expected adoption path is hand-write `INDEX.md` + one `domain/<context>.md`, run for one feature, review the first `pro-knowledge.md`, then enable.

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
