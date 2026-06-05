# Architecture map

> Living document. SpecKit Pro proposes updates in `<feature>/pro-knowledge.md` after evaluator PASS.

## Systems overview

| Area | Entry points | Notes |
|------|----------------|-------|
| Parallel deep-analysis (fan-out) | `/pro.scan` · `scripts/bash/pro-scan.sh` | Splits the repo into dependency-clustered portions, fans out across concurrent workers, merges → `.knowledge/scan/`. See [#parallel-deep-analysis-fan-out-engine](#parallel-deep-analysis-fan-out-engine). |

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
