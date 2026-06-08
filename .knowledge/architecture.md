# Architecture map

> Living document. SpecKit Pro proposes updates in `<feature>/pro-knowledge.md` after evaluator PASS.

## Systems overview

| Area | Entry points | Notes |
|------|----------------|-------|
| Parallel deep-analysis (fan-out) | `/pro.scan` · `scripts/bash/pro-scan.sh` | Splits the repo into dependency-clustered portions, fans out across concurrent workers, merges → `.knowledge/scan/`. See [#parallel-deep-analysis-fan-out-engine](#parallel-deep-analysis-fan-out-engine). |

## Self-improving headless orchestration & observability (feature 002)

Makes the **terminal/headless substrate** correctly drive an external agent CLI for unattended runs, makes every run measurable, and hardens the self-improvement loop against in-context reward hacking. All by extending existing mechanisms — no parallel write path, no native `/speckit.*` fork.

| Component | Path | Role |
|---|---|---|
| Headless orchestrator | `scripts/bash/pro-orchestrate.sh` | Capability profile (`cli_capabilities`/`cli_has_cap`), `build_claude_flags` (literal `--append-system-prompt`, gated permissions, **cumulative** `--max-budget-usd`, session `--resume`), `parse_agent_result` (python3→text, no jq), per-call/phase telemetry hand-off, rubric-tamper hard-fail. Copilot/gemini/generic branches unchanged. |
| Run reporter | `scripts/bash/pro-report.sh` | `phase`/`call` subcommands → per-run manifest `calls[]`/`phases[]`; `finish` rolls up cost/tokens/turns/per-phase-wall-clock/intervention/rework/cb (null-not-0); `aggregate` eval-score trend + regression flag. |
| OTel emitter | `scripts/bash/pro-otel-emit.sh` | **Opt-in** OTLP/HTTP JSON export (GenAI conventions), per-run root + per-phase child spans + metrics, `claude.session_id` join key. Off by default; self-skips; log-not-fatal. |
| Probe guard | `scripts/bash/pro-improve-guard.sh` | `check`/`drift`/`bootstrap`. Gates every self-applied change on committed `.knowledge/probes/{known-good,known-bad}/` fixtures; **fail-closed**; drift alarm on REJECT→ACCEPT. |
| Rubric seal | `commands/pro.contract.md` (write) · `commands/pro.evaluate.md` (verify) | Per-sprint `contracts/*.sha256` committed seal; verify pre-grade → `FAIL:rubric-mutated`. Evaluator runs read-only + distinct-model-capable. |
| Improvements ledger | `.knowledge/improvements.md` | 4 sections (Promoted/Proposed/Archived/Pruned); Phase 0 applies **Promoted only**; Phase 8 appends Proposals + curates (size-bounded). |

**Config**: the `orchestration:` block + extended `evaluation:`/`reporting:` (`regression`/`otel`/`probes`/`improvements`) in `pro-config` + `extension.yml` defaults. **Committed surfaces** under `.knowledge/`: `improvements.md`, `probes/` fixtures, `contracts/*.sha256` seals — everything else under `.knowledge/metrics/` is gitignored telemetry. **Invariants respected**: degrade-not-abort (capability profile + fail-closed gate); single telemetry writer (`pro-report.sh`); default behavior byte-for-byte unchanged (only the opt-in headless-claude path changes).

## Authentication

_(routes, middleware, token lifecycle — link to code paths)_

## Data

_(stores, schemas, migration policy)_

## External integrations

_(webhooks, queues, third-party APIs)_

## Parallel deep-analysis (fan-out engine)

Shared engine that splits deep code analysis into portions and runs them across concurrent workers, merging into one report. Two surfaces, one engine; adaptive substrate.

| Component | Path | Role |
|---|---|---|
| `/pro.scan` command | `commands/pro.scan.md` | In-harness orchestrator — dispatches concurrent **sub-agent** workers. |
| Terminal entrypoint | `scripts/bash/pro-scan.sh` → `scripts/bash/pro-fanout.sh` | **cli** substrate — spawns headless agent-CLI worker processes. |
| Engine lib | `scripts/bash/lib/pro-fanout-common.sh` | Bounded worker pool (bash-3.2-safe), manual per-worker timeout, circuit breaker, JSONL telemetry, substrate detection. |
| Partitioner | `scripts/local/partition.py` | Deterministic dependency-cluster partition (size-bucket fallback, oversized pre-split) → `portions.json`. |
| Report assembler | `scripts/local/scan_report.py` | Coverage Ledger (no silent gaps) + atomic, lock-guarded `latest.md` + timestamped archive. |
| Worker / merge prompts | `templates/scan/{worker,merge,tiebreak}.prompt.md` | Per-portion analysis → Partial Result JSON; merge + conflict tie-break. |
| Worker sub-agent | `agents/speckit.pro.scan-worker.agent.md` | Isolated-context analysis worker. |
| Schema validation | `scripts/local/validate_schemas.py` | Validates Partial Result + telemetry against `specs/*/contracts/*.schema.json`. |

**Substrate** is a pluggable interface (`in-harness` | `cli` | `sequential`; future `remote`). Concurrency clamps to `min(16, cores−2)` in-harness / `cores−2` cli.

**Output**: `.knowledge/scan/latest.md` (+ timestamped archive); telemetry → `.knowledge/metrics/fanout-metrics.jsonl` (aggregated by `/pro.local-metrics`).

**Config**: the `parallel:` block (`pro-config.yml` + `extension.yml` defaults). Per-phase retrofit via `parallel.phases.*` (analyze first, opt-in) — the fan-out pre-pass *feeds* native `/speckit.analyze`; the native command is **never forked**.

**Invariants to respect** (see [domain/invariants.md](domain/invariants.md)): no second write path into `.knowledge/` (use the knowledge-sync additive/proposal path); never fork a native `/speckit.*` command; the Coverage Ledger must list every portion (no silent gaps); degrade to sequential, never abort solely for lack of parallelism.
