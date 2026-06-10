---
description: "Adaptive parallel deep-code-analysis. Partitions the repo into dependency-clustered portions, fans them out across concurrent workers (in-harness sub-agents, or headless agent-CLI processes from a terminal), merges with a tie-breaker into one report (architecture map, dependency overview, risk hotspots) under .knowledge/scan/, and offers findings to .knowledge/. Self-degrades to sequential; never aborts."
---

# SpecKit Pro — Parallel Deep-Analysis (`pro.scan`)

Splits deep code analysis into dependency-clustered **portions** and runs them
across concurrent **workers**, then merges the partial results into one coherent
report. One engine, two backends, chosen automatically:

- **in-harness** (this command, running as a skill): dispatch concurrent
  **sub-agent** workers — each gets its own context window.
- **cli** (from a terminal): `scripts/bash/pro-scan.sh` spawns headless
  agent-CLI worker processes.

This command is the in-harness orchestrator. It **never aborts** the caller: if it
cannot parallelize it degrades to a single sequential worker and says so.

## Arguments

```text
$ARGUMENTS
```

Optional: `[path]` scope (default repo root) · `--workers N` · `--substrate in-harness|cli|sequential` · `--strategy dependency-cluster|size-bucket` · `--dry-run` · `--no-knowledge`.

## Config (pro-config.yml → `parallel:`)

Load `parallel.*` (master `enabled`, `substrate`, `workers`, `strategy`,
`worker_timeout_seconds`, `max_consecutive_failures`, `tiebreak`, `oversized`,
`report`, `telemetry`, `metrics_file`). If `parallel.enabled: false`, print one
line and exit — do not scan.

## Steps

### 0. Resolve run context
- `PROJECT_ROOT=$(git rev-parse --show-toplevel)`; `RUN_ID="scan-<UTC-YYYYMMDD-HHMMSS>-<short>"`.
- `WORK="$PROJECT_ROOT/.knowledge/scan/.work/$RUN_ID"`; `mkdir -p "$WORK/results"`.
- Substrate: honor `--substrate`; else `parallel.substrate` (`auto` → in-harness here, since this command runs in the agent harness). The terminal/cli path is `pro-scan.sh`, not this command.
- Workers: `--workers` else `parallel.workers.in_harness` else `min(16, cores-2)`. Clamp to that ceiling.

### 1. Partition
```bash
python3 scripts/local/partition.py --root "<scope>" --workers <N> \
  --strategy <strategy> --max-tokens <budget> --out "$WORK/portions.json"
```
Read `$WORK/portions.json`. If only one portion (small repo), run a single worker — no fan-out overhead (FR fast-path).

### 2. Dispatch workers (concurrent sub-agents)
For each portion in `portions.json`, dispatch a **sub-agent** (agent type
`speckit.pro.scan-worker`) **in parallel** — bounded by the worker count. Give each:
- the worker prompt `templates/scan/worker.prompt.md`,
- its `PORTION_ID` and `FILES` list.
Each worker writes its Partial Result JSON to `$WORK/results/<portion_id>.json`
(schema ships at `.specify/extensions/pro/templates/schemas/partial-result.schema.json`; in the pro source repo: `templates/schemas/`).

Record a telemetry line per worker (dispatch/complete/fail/timeout) to
`parallel.metrics_file` — reuse `scripts/bash/lib/pro-fanout-common.sh::fanout_telemetry`
(`source` it and call, or append an equivalent JSONL line). A worker that fails or
exceeds `worker_timeout_seconds` does **not** abort the run — its portion is simply
missing a result file, which the Coverage Ledger records as `failed` (FR-009/FR-010).
If `max_consecutive_failures` workers fail in a row, stop dispatching (circuit breaker).

### 3. Validate partial results
```bash
python3 scripts/local/validate_schemas.py partial-result "$WORK"/results/*.json
```
Drop (and ledger-note) any result that fails validation.

### 4. Merge (+ tie-break)
- Run one merge step using `templates/scan/merge.prompt.md` over all Partial
  Results → a findings Markdown body (Architecture / Dependency / Risk / Unknowns)
  written to `$WORK/findings.md`. The merge surfaces conflicts; it does **not** resolve them.
- For each conflict, and only if `parallel.tiebreak: true`, dispatch a tie-breaker
  sub-agent with `templates/scan/tiebreak.prompt.md` (verdict + dissent). Fold the
  verdict+dissent into the Conflicts section of `findings.md`.

### 5. Assemble the report (deterministic)
```bash
python3 scripts/local/scan_report.py \
  --portions "$WORK/portions.json" --results-dir "$WORK/results" \
  --out-dir "$PROJECT_ROOT/.knowledge/scan" --run-id "$RUN_ID" \
  --substrate in-harness --workers-eff <N> --workers-req <req> \
  --repo "$(basename "$PROJECT_ROOT")" --findings-md "$WORK/findings.md" \
  --wall-ms <elapsed> [--baseline-ms <serial-estimate>] [--capped "<note>"]
```
This writes `.knowledge/scan/latest.md` (atomic) + a timestamped archive, with a
Coverage Ledger covering **every** portion (no silent gaps). `--dry-run` stops
after step 1 and prints the partition plan instead.

### 6. Feed `.knowledge/` (unless `--no-knowledge` or `parallel.report.feed_knowledge: false`)
Offer the report's durable architecture/glossary findings to `.knowledge/` through
the **existing** knowledge-sync additive/proposal path — never a second write path,
never a silent destructive overwrite (FR-011). In practice: surface them as proposals
the operator approves (same discipline as `/pro.knowledge-sync`).

### 7. Report
Print: run_id, substrate, portions, workers, wall-clock vs serial estimate, coverage
gaps (if any), and the path to `.knowledge/scan/latest.md`.

## Degradation & safety
- No substrate / can't fan out → single sequential worker; warn "concurrency unavailable"; still complete (FR-014).
- All run state lives under gitignored `.knowledge/scan/.work/<run-id>/` — PR-safe, and per-run namespacing + the `scan_report.py` lock prevent concurrent scans from clobbering `latest.md` (SC-005).
- This command analyzes; it never edits source files.
