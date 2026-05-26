#!/usr/bin/env bash
# =============================================================================
# pro-local-metrics.sh — Aggregate the local-model telemetry JSONL into a
# human-readable dashboard. Reads .ai-knowledge/local-metrics.jsonl and prints:
#   • per-task call counts, latency p50/p95, failure rate
#   • per-review-type precision (kept ÷ produced) and recall
#     (agreed ÷ (agreed + missed))
#   • top dropped finding refs (false-positive prone signatures)
#   • token-byte totals (proxy for cost on remote-Ollama setups)
#
# Usage:
#   pro-local-metrics.sh [--since 30d|7d|24h|all]
#                        [--feature <slug>]
#                        [--task <name>]
#                        [--metrics-file <path>]
#                        [--json]
# =============================================================================

set -u

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
# shellcheck source=lib/pro-local-common.sh
source "$SCRIPT_DIR/lib/pro-local-common.sh"

SINCE="30d"
FILTER_FEATURE=""
FILTER_TASK=""
METRICS_FILE=""
AS_JSON=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --since)         SINCE="$2"; shift 2 ;;
    --feature)       FILTER_FEATURE="$2"; shift 2 ;;
    --task)          FILTER_TASK="$2"; shift 2 ;;
    --metrics-file)  METRICS_FILE="$2"; shift 2 ;;
    --json)          AS_JSON=true; shift ;;
    -h|--help)       sed -n '2,20p' "$0"; exit 0 ;;
    *)               local_err "unknown arg: $1"; exit 1 ;;
  esac
done

PROJECT_ROOT="$(local_project_root)"
local_load_config "$PROJECT_ROOT"

[[ -z "$METRICS_FILE" ]] && METRICS_FILE="${LOCAL_METRICS_FILE:-$PROJECT_ROOT/.ai-knowledge/local-metrics.jsonl}"

if [[ ! -f "$METRICS_FILE" ]]; then
  local_warn "no metrics file at $METRICS_FILE"
  local_warn "(it appears after the first /pro.local-prep, /pro.local-review, or /pro.materialize run)"
  exit 0
fi

# Everything else lives in Python — bash is the wrong tool for percentiles.
SPECKIT_PRO_METRICS_FILE="$METRICS_FILE" \
SPECKIT_PRO_SINCE="$SINCE" \
SPECKIT_PRO_FILTER_FEATURE="$FILTER_FEATURE" \
SPECKIT_PRO_FILTER_TASK="$FILTER_TASK" \
SPECKIT_PRO_AS_JSON="$AS_JSON" \
python3 <<'PY'
import json, os, sys, math, datetime as dt
from collections import defaultdict

path = os.environ["SPECKIT_PRO_METRICS_FILE"]
since_arg = os.environ.get("SPECKIT_PRO_SINCE", "30d").strip().lower()
flt_feature = os.environ.get("SPECKIT_PRO_FILTER_FEATURE", "").strip()
flt_task    = os.environ.get("SPECKIT_PRO_FILTER_TASK", "").strip()
as_json     = os.environ.get("SPECKIT_PRO_AS_JSON", "false").lower() == "true"

# ── Parse --since ────────────────────────────────────────────────────────────
def parse_since(s):
    if s in ("all", "0", ""):
        return None
    unit = s[-1]
    try:
        n = int(s[:-1])
    except ValueError:
        return None
    if unit == "d": return dt.timedelta(days=n)
    if unit == "h": return dt.timedelta(hours=n)
    if unit == "m": return dt.timedelta(minutes=n)
    return None

window = parse_since(since_arg)
cutoff = (dt.datetime.now(dt.timezone.utc) - window) if window else None

def parse_ts(s):
    if not s: return None
    try:
        if s.endswith("Z"): s = s[:-1] + "+00:00"
        return dt.datetime.fromisoformat(s)
    except Exception:
        return None

# ── Read ─────────────────────────────────────────────────────────────────────
calls = []     # type=call records
verdicts = []  # type=verdict records
skips = []     # type=skip records (driver self-skipped before any call)
with open(path, encoding="utf-8") as f:
    for ln in f:
        ln = ln.strip()
        if not ln: continue
        try:
            r = json.loads(ln)
        except Exception:
            continue
        ts = parse_ts(r.get("ts"))
        if cutoff and ts and ts < cutoff:
            continue
        if flt_feature and r.get("feature","") != flt_feature:
            continue
        if r.get("type") == "call":
            if flt_task and r.get("task","") != flt_task:
                continue
            calls.append(r)
        elif r.get("type") == "verdict":
            verdicts.append(r)
        elif r.get("type") == "skip":
            skips.append(r)

# ── Aggregate calls per task ─────────────────────────────────────────────────
by_task = defaultdict(list)
for r in calls:
    by_task[r.get("task","?")].append(r)

def percentile(xs, p):
    if not xs: return 0
    xs = sorted(xs)
    k = (len(xs)-1) * p
    f, c = math.floor(k), math.ceil(k)
    if f == c: return xs[int(k)]
    return xs[f] + (xs[c] - xs[f]) * (k - f)

task_stats = {}
total_calls = 0
total_failures = 0
total_wall_ms = 0
total_prompt_bytes = 0
total_output_bytes = 0
for task, rows in sorted(by_task.items()):
    walls = [r.get("wall_ms",0) for r in rows]
    fails = sum(1 for r in rows if r.get("exit_code",0) != 0)
    task_stats[task] = {
        "calls": len(rows),
        "failures": fails,
        "fail_pct": (fails/len(rows)*100) if rows else 0,
        "p50_ms": percentile(walls, 0.50),
        "p95_ms": percentile(walls, 0.95),
        "total_prompt_bytes": sum(r.get("prompt_bytes",0) for r in rows),
        "total_output_bytes": sum(r.get("output_bytes",0) for r in rows),
        "models": sorted({r.get("model","?") for r in rows}),
    }
    total_calls += len(rows)
    total_failures += fails
    total_wall_ms += sum(walls)
    total_prompt_bytes += task_stats[task]["total_prompt_bytes"]
    total_output_bytes += task_stats[task]["total_output_bytes"]

# ── Aggregate verdicts per review_type ───────────────────────────────────────
by_review = defaultdict(lambda: defaultdict(int))
dropped_signatures = defaultdict(int)
for v in verdicts:
    rt = v.get("review_type","?")
    verdict = v.get("verdict","?")
    by_review[rt][verdict] += 1
    by_review[rt]["total_excluding_missed"] += 0 if verdict == "missed" else 1
    if verdict == "dropped":
        sig = f"{rt}/{v.get('finding_ref','?')}"
        dropped_signatures[sig] += 1

review_stats = {}
for rt, counts in by_review.items():
    agreed       = counts.get("agreed", 0)
    kept         = counts.get("kept", 0)
    dropped      = counts.get("dropped", 0)
    unverifiable = counts.get("unverifiable", 0)
    missed       = counts.get("missed", 0)
    produced     = agreed + kept + dropped + unverifiable
    true_positive_set = agreed + kept
    review_stats[rt] = {
        "produced": produced,
        "agreed": agreed,
        "kept": kept,
        "dropped": dropped,
        "unverifiable": unverifiable,
        "missed": missed,
        # precision = TP / (TP + FP); we treat dropped as FP, unverifiable excluded
        "precision_pct": (true_positive_set / (true_positive_set + dropped) * 100)
                          if (true_positive_set + dropped) else None,
        # recall = TP / (TP + missed)
        "recall_pct":    (true_positive_set / (true_positive_set + missed) * 100)
                          if (true_positive_set + missed) else None,
    }

# ── Output ───────────────────────────────────────────────────────────────────
# Aggregate skips by reason
skip_by_reason = defaultdict(int)
skip_by_driver = defaultdict(int)
for s in skips:
    skip_by_reason[s.get("reason","unknown")] += 1
    skip_by_driver[s.get("driver","unknown")] += 1

if as_json:
    out = {
        "metrics_file": path,
        "window": since_arg,
        "filters": {"feature": flt_feature or None, "task": flt_task or None},
        "totals": {
            "calls": total_calls,
            "failures": total_failures,
            "fail_pct": (total_failures/total_calls*100) if total_calls else 0,
            "wall_seconds": total_wall_ms/1000.0,
            "prompt_bytes": total_prompt_bytes,
            "output_bytes": total_output_bytes,
            "skips": len(skips),
        },
        "per_task": task_stats,
        "per_review": review_stats,
        "top_dropped": sorted(dropped_signatures.items(), key=lambda kv: -kv[1])[:10],
        "skips_by_reason": dict(skip_by_reason),
        "skips_by_driver": dict(skip_by_driver),
    }
    print(json.dumps(out, indent=2))
    sys.exit(0)

# Human dashboard
def hr():
    print("─" * 72)

print()
print(f"  SpecKit Pro — local-model metrics ({since_arg} window)")
print(f"  File: {path}")
filters = []
if flt_feature: filters.append(f"feature={flt_feature}")
if flt_task:    filters.append(f"task={flt_task}")
if filters:     print(f"  Filters: {', '.join(filters)}")
hr()

if total_calls == 0 and not skips:
    print("  No events in window.")
    sys.exit(0)

if total_calls == 0:
    print(f"  No call events in window — but {len(skips)} driver skip(s) recorded.")
    print(f"  Skips by reason: " + ", ".join(f"{r}×{n}" for r,n in skip_by_reason.items()))
    sys.exit(0)

print(f"  Calls: {total_calls}   "
      f"Failures: {total_failures} ({total_failures/total_calls*100:.1f}%)   "
      f"Wall: {total_wall_ms/60000:.1f} min   "
      f"Output: {total_output_bytes/1024:.0f} KiB")
hr()
print(f"  {'TASK':<24}  {'CALLS':>6}  {'p50':>8}  {'p95':>8}  {'FAIL':>6}  MODELS")
for task, s in sorted(task_stats.items(), key=lambda kv: -kv[1]["calls"]):
    print(f"  {task:<24}  {s['calls']:>6}  "
          f"{s['p50_ms']/1000:>6.1f}s  {s['p95_ms']/1000:>6.1f}s  "
          f"{s['failures']:>3} ({s['fail_pct']:>3.0f}%)  "
          f"{', '.join(s['models'])}")
hr()

if review_stats:
    print(f"  REVIEW QUALITY (vs evaluator verdicts)")
    print(f"  {'TYPE':<24}  {'PROD':>4}  {'AGR':>4}  {'KEPT':>4}  {'DROP':>4}  {'UV':>3}  {'MISS':>4}  {'PREC':>6}  {'RECALL':>7}")
    for rt, s in sorted(review_stats.items()):
        prec = f"{s['precision_pct']:.0f}%" if s['precision_pct'] is not None else "  —"
        rec  = f"{s['recall_pct']:.0f}%"    if s['recall_pct']    is not None else "  —"
        print(f"  {rt:<24}  "
              f"{s['produced']:>4}  {s['agreed']:>4}  {s['kept']:>4}  "
              f"{s['dropped']:>4}  {s['unverifiable']:>3}  {s['missed']:>4}  "
              f"{prec:>6}  {rec:>7}")
    hr()
    if dropped_signatures:
        print("  Top dropped (false-positive prone):")
        for sig, n in sorted(dropped_signatures.items(), key=lambda kv: -kv[1])[:5]:
            print(f"    {sig:<40}  dropped {n}x")
        hr()
else:
    print("  No verdict events yet — run /pro.evaluate to start populating review quality.")
    hr()

if skips:
    print(f"  AVAILABILITY  (driver self-skipped before any Ollama call)")
    print(f"  Total skips: {len(skips)}")
    for reason, n in sorted(skip_by_reason.items(), key=lambda kv: -kv[1]):
        print(f"    {reason:<28}  {n}x")
    hr()
PY
