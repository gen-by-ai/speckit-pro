---
description: "Cross-run analytics dashboard — per-feature rollups, failure taxonomy, cost analytics, and a composite health grade computed from runs.jsonl + notifications.jsonl. Plus the cross-REPO insights loop: `export` one portable JSON bundle (analytics + failures + improvements-ledger learnings), `import` bundles from other repos into a rollup and optionally feed their learnings into this repo's ledger as proposals. Pure Python; never calls a model; writes only under .knowledge/."
---

# SpecKit Pro — Analytics (`pro.analytics`)

Turns the raw telemetry SpecKit Pro already captures into the views that drive improvement over time. Where `pro-report.sh aggregate` answers *"are scores trending?"*, this command answers *"**why** do runs fail, **what** does each feature cost, and is the system **healthier** than last week?"*

## When this runs

Manual only — `/speckit.pro.analytics`. Read-only dashboard; no hooks, no automatic invocation. (For automation, the underlying script's `health --gate N` mode is cron-able — see below.)

## Data sources

| File | Written by | Holds |
|---|---|---|
| `.knowledge/metrics/runs.jsonl` | `pro-report.sh finish` | One line per finished run: verdict, score, iterations, tasks, duration, cost |
| `.knowledge/metrics/runs/<run_id>.json` | `pro-report.sh phase/call` | Per-run manifests: phases, calls, cb-trips, interrupted status |
| `.knowledge/metrics/notifications.jsonl` | `pro-orchestrate.sh notify_event` | Every notable orchestrator event: circuit_breaker, watchdog_no_progress, eval_hard_fail, budget_stop, wall_clock_stop, terminated, run_complete |

All optional — the dashboard degrades gracefully when a source is missing. `SPECKIT_PRO_METRICS_DIR` overrides the metrics dir (hermetic tests).

## User Input

```text
$ARGUMENTS
```

Supported (all optional): `summary` (default) | `failures` | `health` | `export` | `import <bundle.json...>`, plus `--last N` (window, default 50), `--feature <name>` (filter), `--json` (machine output), `--write` (persist to `.knowledge/metrics/analytics-report.md`, or `insights-imported.md` for import), `--gate N` (health mode: exit 1 below N), `--out FILE`/`--stdout`/`--anonymize` (export), `--to-ledger` (import).

## Execution

1. Resolve the script: `.specify/extensions/pro/scripts/bash/pro-analytics.sh` (extension dev repo: `scripts/bash/pro-analytics.sh`).
2. Run it with the user's arguments verbatim:

   ```bash
   bash <script-path> $ARGUMENTS
   ```

3. Print the output as-is (it is already formatted). Do not re-summarize the numbers; add at most 2-3 sentences of interpretation **only if** the output contains a regression flag, a failing health gate, or a non-empty failure taxonomy — point at the most actionable recommendation.

## Views

- **`summary`** — per-feature rollup (runs, pass rate, avg score, avg iterations, tasks, cost), failure taxonomy (counted by class: circuit_breaker, watchdog_no_progress, eval_hard_fail, budget_stop, wall_clock_stop, terminated, interrupted, eval_verdict_not_pass), cost analytics (total / per-run / per-completed-task), composite health, and rule-based recommendations.
- **`failures`** — the chronological failure ledger: every failure event with timestamp, feature, iteration and detail, plus where to find the matching iteration transcript (`.knowledge/features/<feature>/logs/iter-N.log`).
- **`health`** — one composite 0-100 score with letter grade: eval pass rate (40), task completion (20), failure-free run rate (20), score trend (20). With `--gate N` the script exits 1 below N — wire it into cron/CI to alarm on degradation:

  ```bash
  # nightly: alert when system health degrades below 70
  bash .specify/extensions/pro/scripts/bash/pro-analytics.sh health --gate 70 \
    || curl -X POST -d '{"text":"SpecKit Pro health below 70"}' "$SPECKIT_PRO_WEBHOOK_URL"
  ```

- **`export`** — one portable, self-contained JSON insights bundle: source identity (repo, branch, installed Pro version), the full analytics summary, the recent failure ledger, and the improvements-ledger learnings (`.knowledge/improvements.md` Promoted + Proposed, raw text). `--out FILE` (default `.knowledge/metrics/insights-<repo>-<date>.json`), `--stdout` to pipe, `--anonymize` to mask repo/branch/feature identity and strip failure details (learnings text still ships verbatim — review before sharing). Works even with zero telemetry if the ledger exists.
- **`import <bundle.json...>`** — cross-repo rollup of one or more bundles: per-source table (version, runs, health, pass rate, cost), merged failure taxonomy (total + how many repos are affected), recurring recommendations ranked by how many repos repeat them, and every collected learning with provenance. Invalid files are skipped with a warning; exit 1 only when nothing valid remains. `--json` for machine output; `--write` persists to `.knowledge/metrics/insights-imported.md`.
- **`import --to-ledger`** — additionally appends the collected learnings to this repo's `.knowledge/improvements.md` under `## Proposed`, newest-first, deduped by bold lesson title against the whole ledger, each stamped with an `Imported-from: <repo> (bundle <date>).` line. Source-promoted entries arrive as `status: proposed` — **promotion never crosses repo boundaries un-reviewed**; a human still curates and promotes, exactly as the ledger contract requires.

## Improvement loop

Feed durable findings into the knowledge pipeline: a recurring failure class or a downward-trending feature belongs in `.knowledge/improvements.md` (as a Proposed entry) so the next `/pro.go` Phase 0 reads it. This command observes; `/speckit.pro.knowledge-sync` persists.

## Sharing insights across repos

Pro runs in many consumer repos; the extension (and the team's shared operating wisdom) improves in one place. The bundle closes that loop:

```bash
# in each consumer repo — produce a shareable bundle
bash .specify/extensions/pro/scripts/bash/pro-analytics.sh export
#   → .knowledge/metrics/insights-<repo>-<date>.json   (add --anonymize for external sharing)

# in the improvement repo — roll up everything and feed the ledger
bash scripts/bash/pro-analytics.sh import ~/Downloads/insights-*.json --write --to-ledger
```

Imported learnings land as `status: proposed`; review and promote the ones worth applying (run the probe gate first), and the next `/pro.go` Phase 0 picks them up everywhere the ledger is shared.
