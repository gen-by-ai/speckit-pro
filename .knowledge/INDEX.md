# Repo knowledge — decision tree

> Seeded by SpecKit Pro. Replace placeholders with real routing rules.
> Format: **if you are touching X, read Y, then Z**

## By area

- If you are touching **authentication or sessions**, read [domain/glossary.md](domain/glossary.md), then [architecture.md](architecture.md#authentication).
- If you are touching **API contracts or HTTP handlers**, read [architecture.md](architecture.md), then [domain/invariants.md](domain/invariants.md).
- If you are touching **persistence or migrations**, read [architecture.md](architecture.md#data), then [domain/invariants.md](domain/invariants.md).
- If you are changing **cross-cutting behavior** (logging, errors, idempotency), read [domain/invariants.md](domain/invariants.md) before editing code.
- If you are adding **parallel/concurrent analysis** or touching `scripts/bash/pro-fanout*` / `scripts/local/partition.py` / `/pro.scan`, read [architecture.md](architecture.md#parallel-deep-analysis-fan-out-engine), then respect: no second `.knowledge/` write path; clamp concurrency to `min(16, cores−2)` (in-harness) / `cores−2` (cli); never fork a native `/speckit.*` command; the Coverage Ledger must cover every portion.
- If you are touching **run telemetry events, resume/recovery, checkpoints, or unattended gates** (`pro-report.sh` events/lifecycle, `pro-resume-detect.sh`, `config_defaults_check.py`, `gates.unattended`, contract `--amend`), read [architecture.md](architecture.md#autonomy--reliability-hardening-feature-003), then respect: all events through the single writer (`pro-report.sh`); locks fail loud, never write unlocked; never blanket-stage checkpoints; invalid evaluator verdicts hard-fail; run `bash scripts/tests/hardening-smoke.sh` before shipping changes here.
- If you are touching **headless agent-CLI orchestration, run telemetry, or the self-improvement loop** (`scripts/bash/pro-orchestrate.sh` / `pro-report.sh` / `pro-otel-emit.sh` / `pro-improve-guard.sh`, the `orchestration:`/`reporting:` config, contract seals, or `improvements.md`), read [architecture.md](architecture.md#self-improving-headless-orchestration--observability-feature-002), then respect: inject agent files via `--append-system-prompt "$(cat …)"` (NO `--system-prompt-file` in claude 2.1.116); python3→text JSON parsing (no jq); one telemetry writer (`pro-report.sh`); the evaluator is read-only + never resumes the generator session; rubric seals are immutable to the generator; self-applied changes are probe-gated (fail-closed); default behavior stays byte-for-byte unchanged.
- If you are touching **the orchestrator state machine** (`pro-orchestrate.sh`/`.ps1` — status parsing, circuit breaker, no-progress watchdog, timeouts, lockfile, `loop-state.json`, resume budget, status-file contract, notifications), run `bash scripts/tests/orchestrator-smoke.sh` before shipping (17 hermetic fake-agent-CLI checks, zero tokens) — every terminal path it covers was once a silent-failure bug; under `set -euo pipefail`, guard every `var=$(… | grep …)` with `|| var=""`. Cross-run failure/cost/health views: `pro-analytics.sh` / `/speckit.pro.analytics`.

## By artifact

- New **business term** or enum → update [domain/glossary.md](domain/glossary.md) after merge (see `pro-knowledge.md` from `/pro.knowledge-sync`).
- New **endpoint or module** → update [architecture.md](architecture.md) after merge.
- **Irreversible design choice** → add a draft under `decisions/` (see `pro-knowledge-adr-draft.md`).
