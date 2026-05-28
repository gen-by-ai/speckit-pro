---
description: "Dashboard of local-model performance + first-pass review quality. Aggregates the JSONL telemetry written by ollama-md.py and the verdict events written by /pro.evaluate."
---

# SpecKit Pro — Local Metrics (`pro.local-metrics`)

Reads `.knowledge/metrics/local-metrics.jsonl` and prints a compact dashboard of:

- **Performance** — per-task call count, p50/p95 wall-clock latency, failure rate, models used. Bytes in/out (proxy for token usage; multiply by your model's tokenizer ratio for token estimates).
- **Review quality** — per review type (`implementation-review`, `test-gap-review`, `security-review`):
  - **Precision** = `(agreed + kept) ÷ (agreed + kept + dropped)` — what fraction of local findings survived evaluator verification?
  - **Recall** = `(agreed + kept) ÷ (agreed + kept + missed)` — what fraction of real findings did local catch? (Requires the evaluator to log `missed` events for findings local didn't surface.)
- **Top dropped** — which review-type/finding-ref combinations keep getting dropped as false positives. Signature for "this prompt template needs tuning".
- **Availability** — how often a driver wanted to use the local stack but Ollama was unreachable. High counts mean either the daemon is flaky or `base_url` is misconfigured.

## When this runs

Manual only — `/speckit.pro.local-metrics`. It's a read-only dashboard; no hooks, no automatic invocation.

## Data sources

Three event types in the same JSONL file:

| Event       | Written by                            | When                                                       |
|-------------|---------------------------------------|------------------------------------------------------------|
| `call`      | `scripts/local/ollama-md.py`          | Every Ollama invocation (success and failure)              |
| `verdict`   | `/pro.evaluate` Step 4c               | Once per finding in `<SPEC_DIR>/local-reviews/*.md`        |
| `skip`      | `pro-local-prep.sh` / `pro-local-review.sh` / `pro-materialize.sh` | When the driver self-skips because Ollama is unreachable (one event per run, not per task) |

File location resolution order:
1. `--metrics-file <path>` flag
2. `$SPECKIT_PRO_METRICS_FILE` env
3. `local_models.metrics_file` in `pro-config.yml` (relative paths resolve against project root)
4. Default: `<PROJECT_ROOT>/.knowledge/metrics/local-metrics.jsonl`

The default lives under `.knowledge/features/` which is gitignored — metrics are workspace state, not artifacts to commit.

## User Input

```text
$ARGUMENTS
```

Optional flags:
- `--since 30d` — time window. Accepts `Nd`, `Nh`, `Nm`, or `all`. Default `30d`.
- `--feature <slug>` — only events for this feature directory name.
- `--task <name>` — only `call` events for this task name (e.g. `repo-map`, `security-review`).
- `--metrics-file <path>` — override file location.
- `--json` — emit a single JSON object instead of the human dashboard. Useful for scripting / chart generation.

## Steps

1. Resolve the metrics file. If it does not exist (no local-prep / local-review / materialize has ever run), print a friendly note and exit 0.
2. Read JSONL line-by-line, parse, filter by window / feature / task.
3. Aggregate:
   - Per-task call stats (count, p50/p95 wall_ms, failure rate, models used, byte totals).
   - Per-review-type verdict counts (agreed, kept, dropped, unverifiable, missed), then derive precision and recall.
   - Top dropped signatures.
4. Print the dashboard (or JSON with `--json`).

## Example output

```
  SpecKit Pro — local-model metrics (30d window)
  File: /Users/me/code/app/.knowledge/metrics/local-metrics.jsonl
────────────────────────────────────────────────────────────────────────
  Calls: 142   Failures: 3 (2.1%)   Wall: 51.4 min   Output: 412 KiB
────────────────────────────────────────────────────────────────────────
  TASK                       CALLS       p50       p95    FAIL  MODELS
  task-packet                   48     11.0s     17.4s    0 (  0%)  qwen2.5-coder:7b
  repo-map                      24     14.2s     22.1s    0 (  0%)  qwen2.5-coder:7b
  context-pack                  24     18.5s     31.0s    1 (  4%)  qwen2.5-coder:7b
  test-strategy                 22     15.6s     24.0s    0 (  0%)  qwen2.5-coder:7b
  risk-register                 22     12.3s     19.0s    2 (  9%)  qwen2.5-coder:7b
  open-questions                 2      8.2s      8.2s    0 (  0%)  qwen2.5-coder:7b
────────────────────────────────────────────────────────────────────────
  REVIEW QUALITY (vs evaluator verdicts)
  TYPE                       PROD   AGR  KEPT  DROP   UV  MISS    PREC  RECALL
  implementation-review        18    11     2     5    0     6     72%     68%
  test-gap-review              12     7     3     2    0     4     83%     71%
  security-review               8     5     2     1    0     5     88%     58%
────────────────────────────────────────────────────────────────────────
  Top dropped (false-positive prone):
    security-review/S3                   dropped 3x
    implementation-review/F2             dropped 2x
────────────────────────────────────────────────────────────────────────
```

## How to use the signal

- **Latency p95 climbing** for a task → consider a smaller model in `local_models.<task>_model`, or bump `timeout_seconds`.
- **High failure rate** on a single task → likely model not pulled, or the prompt's `num_ctx` exceeds the model's capacity. Check `failures` column + run with a verbose driver to see the exit code.
- **Precision below 60 %** on a review type → the prompt template is over-eager. Tighten the evidence-pack requirements or move that review type to a stronger model.
- **Recall below 50 %** on a review type → the prompt is too narrow OR the model isn't strong enough for that surface. Worth pushing security-review to a 13B+ model, or to Claude when budget allows.
- **One signature dominating "top dropped"** → that's a specific systematic false positive worth adding to the prompt as an explicit anti-pattern.

## What this command does NOT do

- It does not modify the metrics file or any other state.
- It does not call Claude. Pure local Python.
- It does not call Ollama. The dashboard is read-only.

## Config

```yaml
local_models:
  enabled: true
  telemetry: true                                     # default true; set false to disable JSONL emission
  metrics_file: ".knowledge/metrics/local-metrics.jsonl"  # relative paths resolve against project root
```

## Roadmap (Layer 2 + 3, opt-in later)

- **Layer 2 — Golden bench (`benchmarks/local/`)**: 2–3 fixed spec/plan/tasks bundles with known-good outputs, re-run on every prompt-template change to catch regressions. Maps to MDASH lesson 4 (private ground-truth corpora).
- **Layer 3 — A/B model routing**: two models compete per task; the metrics file decides the winner over N runs. Requires `local_models.routes.<task>` to accept a list. Worth building once layer 1 + 2 are stable.

This file documents what exists today. Layers 2 and 3 are deliberately not implemented yet — layer 1 needs real usage before we know which signals matter.
