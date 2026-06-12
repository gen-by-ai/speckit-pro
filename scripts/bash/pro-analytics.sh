#!/usr/bin/env bash
# =============================================================================
# SpecKit Pro — Cross-Run Analytics Engine
# pro-analytics.sh
#
# The system is data-rich but was analysis-poor: pro-report.sh captures per-run
# telemetry (runs.jsonl, runs/<id>.json manifests) and pro-orchestrate.sh logs
# notable events (notifications.jsonl), but nothing rolled it up. This script
# turns the raw telemetry into the three views that drive improvement over time:
#
#   summary   per-feature rollups (pass rate, score, iterations, cost,
#             tasks/iteration efficiency), failure taxonomy, cost analytics,
#             and rule-based recommendations.
#   failures  chronological failure ledger — every breaker trip, watchdog stop,
#             eval fail, budget/wall-clock stop and termination, classified.
#   health    one composite 0-100 score + letter grade; `--gate N` exits 1
#             below N so cron/CI can alarm on degradation.
#
# Two more views close the cross-REPO loop — Pro runs in many consumer repos,
# and their insights should be able to travel back to wherever the extension
# (or the team's shared operating wisdom) is improved:
#
#   export    one portable, self-contained JSON insights bundle: the analytics
#             summary, the failure ledger, health, AND the improvements-ledger
#             learnings (.knowledge/improvements.md Promoted+Proposed).
#   import    ingest one or more bundles (from any repos), render a cross-repo
#             rollup (per-source health/cost, merged failure taxonomy, recurring
#             recommendations, collected learnings); `--to-ledger` appends the
#             collected learnings to this repo's improvements ledger as
#             status:proposed entries (additive, deduped — promotion stays
#             human-gated, matching the ledger contract).
#
# Usage:
#   pro-analytics.sh [summary] [--last N] [--feature X] [--json] [--write]
#   pro-analytics.sh failures  [--last N] [--json]
#   pro-analytics.sh health    [--json] [--gate N]
#   pro-analytics.sh export    [--last N] [--feature X] [--out FILE | --stdout] [--anonymize]
#   pro-analytics.sh import    <bundle.json...> [--json] [--write] [--to-ledger]
#
# Data sources (all optional — degrade gracefully):
#   $METRICS_DIR/runs.jsonl              one line per finished run (pro-report.sh)
#   $METRICS_DIR/runs/<run_id>.json      per-run manifests (phases/calls/events)
#   $METRICS_DIR/notifications.jsonl     orchestrator event audit trail
#
# Env: SPECKIT_PRO_METRICS_DIR overrides the metrics dir (hermetic tests).
# bash 3.2 compatible; python3 required (matches pro-report.sh aggregate).
# =============================================================================
set -uo pipefail

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
METRICS_DIR="${SPECKIT_PRO_METRICS_DIR:-$ROOT/.knowledge/metrics}"
RUNS_LOG="$METRICS_DIR/runs.jsonl"
RUNS_DIR="$METRICS_DIR/runs"
NOTIFY_LOG="$METRICS_DIR/notifications.jsonl"
REPORT_OUT="$METRICS_DIR/analytics-report.md"

err()  { echo "[pro-analytics] ✗ $*" >&2; }
warn() { echo "[pro-analytics] ⚠ $*" >&2; }

have_py() { command -v python3 >/dev/null 2>&1; }

# ─── Arg parsing ──────────────────────────────────────────────────────────────
CMD="summary"
case "${1:-}" in
  summary|failures|health|export|import) CMD="$1"; shift ;;
esac

LAST=50
FEATURE=""
AS_JSON=0
WRITE=0
GATE=""
OUT=""
TO_STDOUT=0
ANON=0
TO_LEDGER=0
IMPORT_FILES=""   # newline-separated (bash 3.2: avoid empty-array expansion under set -u)
# Value-taking flags validate eagerly: a bare `shift 2` with one argument left
# is a non-consuming no-op (no -e here), which would spin this loop forever —
# fatal for the cron-able `health --gate N`. Non-numeric --last/--gate must
# error loudly too: a typo'd gate that silently exits 0 is a dead alarm.
while [[ $# -gt 0 ]]; do
  case "$1" in
    --last)
      [[ "${2:-}" =~ ^[0-9]+$ ]] || { err "--last requires a positive integer (got '${2:-}')"; exit 1; }
      LAST="$2"; shift 2 ;;
    --feature)
      [[ -n "${2:-}" ]] || { err "--feature requires a value"; exit 1; }
      FEATURE="$2"; shift 2 ;;
    --json)      AS_JSON=1; shift ;;
    --write)     WRITE=1; shift ;;
    --gate)
      [[ "${2:-}" =~ ^[0-9]+(\.[0-9]+)?$ ]] || { err "--gate requires a numeric threshold (got '${2:-}')"; exit 1; }
      GATE="$2"; shift 2 ;;
    --out)
      [[ -n "${2:-}" ]] || { err "--out requires a path"; exit 1; }
      OUT="$2"; shift 2 ;;
    --stdout)    TO_STDOUT=1; shift ;;
    --anonymize) ANON=1; shift ;;
    --to-ledger) TO_LEDGER=1; shift ;;
    *)
      if [[ "$CMD" == "import" && -f "$1" ]]; then
        IMPORT_FILES="${IMPORT_FILES}${1}"$'\n'
      else
        warn "unknown argument: $1"
      fi
      shift ;;
  esac
done

if ! have_py; then
  err "python3 required for analytics"
  exit 1
fi

IMPROVE_FILE="$ROOT/.knowledge/improvements.md"

if [[ "$CMD" == "import" ]]; then
  if [[ -z "$IMPORT_FILES" ]]; then
    err "import requires at least one bundle file: pro-analytics.sh import <bundle.json> [...]"
    exit 1
  fi
elif [[ ! -f "$RUNS_LOG" && ! -f "$NOTIFY_LOG" ]]; then
  if [[ "$CMD" == "export" && -f "$IMPROVE_FILE" ]]; then
    warn "no telemetry yet — export bundle will contain learnings only."
  else
    warn "no telemetry yet ($RUNS_LOG, $NOTIFY_LOG) — finish at least one run first."
    exit 0
  fi
fi

# ── Source identity for export bundles ────────────────────────────────────────
repo_identity() {
  local url
  url="$(git -C "$ROOT" remote get-url origin 2>/dev/null || true)"
  if [[ -n "$url" ]]; then basename "${url%.git}"; else basename "$ROOT"; fi
}
pro_version() {
  local f
  for f in "$ROOT/.specify/extensions/pro/extension.yml" "$ROOT/extension.yml"; do
    [[ -f "$f" ]] || continue
    grep -q 'id:[[:space:]]*"pro"' "$f" 2>/dev/null || continue
    sed -n 's/^[[:space:]]*version:[[:space:]]*"\{0,1\}\([0-9][^"]*\)"\{0,1\}.*/\1/p' "$f" | head -1
    return 0
  done
  return 0
}
REPO_NAME="$(repo_identity)"
BRANCH="$(git -C "$ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
PRO_VERSION="$(pro_version)"
GENERATED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

CMD="$CMD" LAST="$LAST" FEATURE="$FEATURE" AS_JSON="$AS_JSON" WRITE="$WRITE" \
GATE="$GATE" RUNS_LOG="$RUNS_LOG" RUNS_DIR="$RUNS_DIR" NOTIFY_LOG="$NOTIFY_LOG" \
REPORT_OUT="$REPORT_OUT" METRICS_DIR="$METRICS_DIR" IMPROVE_FILE="$IMPROVE_FILE" \
OUT="$OUT" TO_STDOUT="$TO_STDOUT" ANON="$ANON" TO_LEDGER="$TO_LEDGER" \
IMPORT_FILES="$IMPORT_FILES" REPO_NAME="$REPO_NAME" BRANCH="$BRANCH" \
PRO_VERSION="$PRO_VERSION" GENERATED_AT="$GENERATED_AT" python3 <<'PY'
import glob, json, os, re, sys

CMD       = os.environ["CMD"]
LAST      = int(os.environ.get("LAST") or 50)
FEATURE   = os.environ.get("FEATURE") or None
AS_JSON   = os.environ.get("AS_JSON") == "1"
WRITE     = os.environ.get("WRITE") == "1"
GATE      = os.environ.get("GATE") or ""
TO_STDOUT = os.environ.get("TO_STDOUT") == "1"
ANON      = os.environ.get("ANON") == "1"
TO_LEDGER = os.environ.get("TO_LEDGER") == "1"
OUT       = os.environ.get("OUT") or ""
IMPROVE_FILE = os.environ.get("IMPROVE_FILE") or ""
METRICS_DIR  = os.environ.get("METRICS_DIR") or "."

def read_jsonl(path):
    rows = []
    try:
        with open(path, encoding="utf-8") as fh:
            for ln in fh:
                ln = ln.strip()
                if not ln:
                    continue
                try:
                    rows.append(json.loads(ln))
                except Exception:
                    pass
    except OSError:
        pass
    return rows

# ── Improvements-ledger access (export bundles + import --to-ledger) ─────────
# Entries are free-form markdown blocks: a `- [date] …` head line plus indented
# continuation lines. Parsed as raw text so nothing is lost in translation.
def parse_ledger(path):
    promoted, proposed = [], []
    try:
        with open(path, encoding="utf-8") as fh:
            text = fh.read()
    except OSError:
        return promoted, proposed
    section, cur = None, None
    for ln in text.splitlines():
        if ln.startswith("## "):
            h = ln[3:].strip().lower()
            section = "promoted" if h.startswith("promoted") else \
                      "proposed" if h.startswith("proposed") else None
            cur = None
            continue
        if section is None or ln.lstrip().startswith("<!--"):
            continue
        if ln.startswith("- ["):
            cur = [ln]
            (promoted if section == "promoted" else proposed).append(cur)
        elif cur is not None and ln.startswith("  ") and ln.strip():
            cur.append(ln)
    return ["\n".join(e) for e in promoted], ["\n".join(e) for e in proposed]

def entry_title(entry):
    m = re.search(r"\*\*(.+?)\*\*", entry)
    return m.group(1) if m else (entry.splitlines()[0].strip() if entry else "")

def append_to_ledger(path, items):
    """Append imported learnings under ## Proposed (newest-first), deduped by
    bold lesson title against the WHOLE ledger. status:promoted entries arrive
    as status:proposed — promotion never crosses repo boundaries un-reviewed."""
    try:
        with open(path, encoding="utf-8") as fh:
            text = fh.read()
    except OSError:
        text = ("# SpecKit Pro — Improvements Ledger\n\n"
                "## Promoted (applied at Phase 0)\n\n"
                "## Proposed (awaiting human promotion)\n\n")
    # Dedupe keys: bold lesson titles AND raw entry head lines — entry_title
    # falls back to the head line for bold-less entries, so both must be here
    # or repeated imports of a bold-less learning would re-append forever.
    existing = set(re.findall(r"\*\*(.+?)\*\*", text))
    existing |= {ln.strip() for ln in text.splitlines() if ln.startswith("- [")}
    blocks, added, skipped = [], [], 0
    for it in items:
        title = entry_title(it["entry"])
        if not title or title in existing:
            skipped += 1
            continue
        existing.add(title)
        lns = it["entry"].splitlines()
        lns[0] = lns[0].replace("status: promoted", "status: proposed")
        lns.append("  Imported-from: %s (bundle %s)." % (it["source"], it["generated_at"]))
        blocks.append("\n".join(lns))
        added.append(title)
    if blocks:
        lines_all = text.splitlines()
        idx = None
        for i, ln in enumerate(lines_all):
            if ln.startswith("## Proposed"):
                idx = i + 1
                while idx < len(lines_all) and (not lines_all[idx].strip()
                                                or lines_all[idx].lstrip().startswith("<!--")):
                    idx += 1
                break
        if idx is None:
            lines_all += ["", "## Proposed (awaiting human promotion)", ""]
            idx = len(lines_all)
        ins = []
        for b in blocks:
            ins += [b, ""]
        lines_all[idx:idx] = ins
        with open(path, "w", encoding="utf-8") as fh:
            fh.write("\n".join(lines_all) + "\n")
    return added, skipped

runs   = read_jsonl(os.environ["RUNS_LOG"])
events = read_jsonl(os.environ["NOTIFY_LOG"])

manifests = []
for p in glob.glob(os.path.join(os.environ.get("RUNS_DIR", ""), "*.json")):
    try:
        with open(p, encoding="utf-8") as fh:
            manifests.append(json.load(fh))
    except Exception:
        pass
man_by_id = {m.get("run_id"): m for m in manifests if isinstance(m, dict)}

runs = runs[-LAST:]
if FEATURE:
    runs   = [r for r in runs if r.get("feature") == FEATURE]
    events = [e for e in events if e.get("feature") == FEATURE]
events = events[-(LAST * 10):]  # events are finer-grained than runs

def avg(xs):
    xs = [x for x in xs if isinstance(x, (int, float))]
    return sum(xs) / len(xs) if xs else None

def fmt(v, spec="%.1f"):
    return spec % v if isinstance(v, (int, float)) else "n/a"

def fmtusd(v):
    return "$%.2f" % v if isinstance(v, (int, float)) else "n/a"

# ── Failure taxonomy ──────────────────────────────────────────────────────────
# Two complementary sources: orchestrator events (precise classes) and run
# rows (verdicts + interrupted manifests). The taxonomy answers "WHY do runs
# fail" — the missing layer over aggregate's "DO they fail".
FAILURE_EVENTS = (
    "circuit_breaker", "watchdog_no_progress", "eval_hard_fail",
    "budget_stop", "wall_clock_stop", "terminated", "max_iterations",
)
taxonomy = {}
for e in events:
    ev = e.get("event")
    if ev in FAILURE_EVENTS:
        taxonomy[ev] = taxonomy.get(ev, 0) + 1
interrupted = sum(
    1 for m in manifests
    if m.get("status") == "interrupted" and (not FEATURE or m.get("feature") == FEATURE)
)
if interrupted:
    taxonomy["interrupted"] = interrupted
verdict_fails = sum(1 for r in runs if r.get("eval_verdict") in ("FAIL", "NEEDS_REVISION"))
if verdict_fails:
    taxonomy["eval_verdict_not_pass"] = verdict_fails

# ── Per-feature rollups ───────────────────────────────────────────────────────
features = {}
for r in runs:
    f = r.get("feature") or "(unknown)"
    d = features.setdefault(f, {
        "runs": 0, "passes": 0, "scored": 0, "scores": [], "iters": [],
        "durs": [], "costs": [], "tasks_done": 0, "tasks_total": 0,
    })
    d["runs"] += 1
    if r.get("eval_verdict") == "PASS":
        d["passes"] += 1
    if r.get("eval_score") is not None:
        d["scored"] += 1
        d["scores"].append(r["eval_score"])
    if isinstance(r.get("iterations"), int):
        d["iters"].append(r["iterations"])
    if r.get("duration_s") is not None:
        d["durs"].append(r["duration_s"])
    if isinstance(r.get("total_cost_usd"), (int, float)):
        d["costs"].append(r["total_cost_usd"])
    if isinstance(r.get("tasks_done"), int):
        d["tasks_done"] += r["tasks_done"]
    if isinstance(r.get("tasks_total"), int):
        d["tasks_total"] += r["tasks_total"]

# ── Cost analytics ────────────────────────────────────────────────────────────
all_costs   = [r.get("total_cost_usd") for r in runs if isinstance(r.get("total_cost_usd"), (int, float))]
total_cost  = sum(all_costs) if all_costs else None
total_done  = sum(r.get("tasks_done") or 0 for r in runs)
cost_per_task = (total_cost / total_done) if (total_cost is not None and total_done) else None

# ── Efficiency ────────────────────────────────────────────────────────────────
eff = []  # tasks completed per iteration, chronological
for r in runs:
    it = r.get("iterations")
    td = r.get("tasks_done")
    if isinstance(it, int) and it > 0 and isinstance(td, int):
        eff.append(td / it)

# ── Health score ──────────────────────────────────────────────────────────────
# 0-100 composite. Components are deliberately simple and explainable:
#   40 pts  eval pass rate            (quality gate outcome)
#   20 pts  task completion rate      (did runs finish their tasks.md)
#   20 pts  failure-free run rate     (no breaker/watchdog/interrupt classes)
#   20 pts  score trend               (recent half vs older half; 10 = flat)
def health():
    comp = {}
    verd = [r for r in runs if r.get("eval_verdict") in ("PASS", "FAIL", "NEEDS_REVISION")]
    comp["pass_rate"] = (sum(1 for r in verd if r["eval_verdict"] == "PASS") / len(verd) * 40) if verd else 20.0
    done  = sum(r.get("tasks_done") or 0 for r in runs)
    total = sum(r.get("tasks_total") or 0 for r in runs)
    comp["completion"] = (done / total * 20) if total else 10.0
    hard_fail_classes = {"circuit_breaker", "watchdog_no_progress", "eval_hard_fail", "terminated", "interrupted"}
    n_hard = sum(v for k, v in taxonomy.items() if k in hard_fail_classes)
    comp["failure_free"] = max(0.0, (1 - (n_hard / len(runs))) * 20) if runs else 10.0
    scores = [r["eval_score"] for r in runs if isinstance(r.get("eval_score"), (int, float))]
    if len(scores) >= 4:
        h = len(scores) // 2
        a, b = avg(scores[:h]), avg(scores[h:])
        delta = (b - a)  # points of score movement
        comp["trend"] = max(0.0, min(20.0, 10.0 + delta))
    else:
        comp["trend"] = 10.0
    score = sum(comp.values())
    grade = "A" if score >= 85 else "B" if score >= 70 else "C" if score >= 55 else "D" if score >= 40 else "F"
    return round(score, 1), grade, {k: round(v, 1) for k, v in comp.items()}

# ── Recommendations (rule-based, complementary to aggregate's) ───────────────
def recommendations():
    recs = []
    if taxonomy.get("circuit_breaker"):
        recs.append("Circuit breaker tripped %d time(s) — read the matching .knowledge/features/<feature>/logs/iter-*.log transcripts; recurring ERROR classes usually mean auth, rate-limit, or a broken init.sh." % taxonomy["circuit_breaker"])
    if taxonomy.get("watchdog_no_progress"):
        recs.append("Watchdog stopped %d run(s) for zero checkbox progress — work units may be too large or the worker is stuck re-reading context; check task granularity in tasks.md." % taxonomy["watchdog_no_progress"])
    timeouts = sum(1 for e in events if "timeout" in str(e.get("detail", "")).lower())
    if timeouts:
        recs.append("%d timeout event(s) — if legitimate long tasks, raise loop.iteration_timeout; if hangs, inspect the iteration transcripts." % timeouts)
    if taxonomy.get("budget_stop"):
        recs.append("%d budget stop(s) — runs are hitting the USD cap before finishing; either raise --max-budget-usd or shrink the per-run scope." % taxonomy["budget_stop"])
    if taxonomy.get("interrupted"):
        recs.append("%d interrupted run(s) never finished — check for crashes/SIGKILL; loop-state.json + /speckit.pro.resume recovers them." % taxonomy["interrupted"])
    for f, d in sorted(features.items()):
        if d["scored"] >= 3:
            s = d["scores"]
            h = len(s) // 2
            if h and avg(s[h:]) is not None and avg(s[:h]) is not None and avg(s[h:]) < avg(s[:h]) - 5:
                recs.append("Feature %s eval scores trending DOWN (%.1f → %.1f) — review its recent sprint evaluations." % (f, avg(s[:h]), avg(s[h:])))
    if eff and len(eff) >= 4:
        h = len(eff) // 2
        if avg(eff[h:]) < avg(eff[:h]) * 0.7:
            recs.append("Tasks-per-iteration efficiency dropped %.2f → %.2f — later iterations are converging slower; consider richer handoff.md or smaller work units." % (avg(eff[:h]), avg(eff[h:])))
    if cost_per_task is not None and cost_per_task > 2.0:
        recs.append("Cost per completed task is %s — high for routine work; consider a lighter --subagent-model for mechanical tasks." % fmtusd(cost_per_task))
    if not recs:
        recs.append("Healthy across the board. No systemic changes recommended.")
    return recs

# ── Machine summary (shared by --json and export) ─────────────────────────────
def summary_payload():
    score, grade, comp = health()
    return {
        "runs_in_window": len(runs),
        "feature_filter": FEATURE,
        "features": {f: {
            "runs": d["runs"], "passes": d["passes"], "scored": d["scored"],
            "avg_score": avg(d["scores"]), "avg_iterations": avg(d["iters"]),
            "avg_duration_s": avg(d["durs"]), "total_cost_usd": sum(d["costs"]) if d["costs"] else None,
            "tasks_done": d["tasks_done"], "tasks_total": d["tasks_total"],
        } for f, d in features.items()},
        "taxonomy": taxonomy,
        "cost": {"total_usd": total_cost, "avg_per_run_usd": avg(all_costs),
                 "per_completed_task_usd": cost_per_task},
        "health": {"score": score, "grade": grade, "components": comp},
        "recommendations": recommendations(),
    }

# ── Render ────────────────────────────────────────────────────────────────────
def render_summary(out):
    out.append("═══ SpecKit Pro — analytics (last %d run%s%s) ═══" % (
        len(runs), "" if len(runs) == 1 else "s",
        ", feature %s" % FEATURE if FEATURE else ""))
    out.append("")
    out.append("── Per-feature rollup ──")
    if features:
        out.append("%-34s %-5s %-9s %-7s %-7s %-9s %-9s" % ("feature", "runs", "pass", "avg⋆", "iters", "tasks", "cost"))
        for f, d in sorted(features.items()):
            out.append("%-34s %-5d %-9s %-7s %-7s %-9s %-9s" % (
                f[:34], d["runs"],
                "%d/%d" % (d["passes"], d["scored"]) if d["scored"] else "—",
                fmt(avg(d["scores"])), fmt(avg(d["iters"])),
                "%d/%d" % (d["tasks_done"], d["tasks_total"]) if d["tasks_total"] else "—",
                fmtusd(sum(d["costs"])) if d["costs"] else "n/a"))
    else:
        out.append("  (no finished runs in window)")
    out.append("")
    out.append("── Failure taxonomy ──")
    if taxonomy:
        for k, v in sorted(taxonomy.items(), key=lambda kv: -kv[1]):
            out.append("  %-26s %d" % (k, v))
    else:
        out.append("  no failures recorded in window ✓")
    out.append("")
    out.append("── Cost ──")
    out.append("  total spend     : %s" % fmtusd(total_cost))
    out.append("  avg per run     : %s" % fmtusd(avg(all_costs)))
    out.append("  per completed task: %s" % fmtusd(cost_per_task))
    out.append("")
    score, grade, comp = health()
    out.append("── Health ──")
    out.append("  composite: %.1f/100 (grade %s)  [pass %.1f/40 · completion %.1f/20 · failure-free %.1f/20 · trend %.1f/20]" % (
        score, grade, comp["pass_rate"], comp["completion"], comp["failure_free"], comp["trend"]))
    out.append("")
    out.append("── Recommendations ──")
    for r in recommendations():
        out.append("  • " + r)
    out.append("")
    out.append("Cross-run score trend: `pro-report.sh aggregate` · failure detail: `pro-analytics.sh failures`")
    return out

def render_failures(out):
    fail_events = [e for e in events if e.get("event") in FAILURE_EVENTS]
    out.append("═══ SpecKit Pro — failure ledger (last %d event%s) ═══" % (
        len(fail_events), "" if len(fail_events) == 1 else "s"))
    if not fail_events:
        out.append("  no failure events recorded ✓")
        return out
    out.append("")
    out.append("%-21s %-22s %-26s %-5s %s" % ("ts", "event", "feature", "iter", "detail"))
    for e in fail_events:
        out.append("%-21s %-22s %-26s %-5s %s" % (
            str(e.get("ts", "?"))[:21], str(e.get("event", "?"))[:22],
            str(e.get("feature", "?"))[:26], str(e.get("iteration", "?"))[:5],
            str(e.get("detail", ""))[:80]))
    out.append("")
    out.append("Transcripts for any iteration: .knowledge/features/<feature>/logs/iter-N.log")
    return out

# ── export: one portable insights bundle ─────────────────────────────────────
if CMD == "export":
    fail_events = [e for e in events if e.get("event") in FAILURE_EVENTS][-100:]
    promoted, proposed = parse_ledger(IMPROVE_FILE)
    repo = os.environ.get("REPO_NAME") or "unknown"
    feat_names = set(features.keys()) | {str(e["feature"]) for e in fail_events if e.get("feature")}
    if FEATURE:
        feat_names.add(FEATURE)  # a filter matching no runs must still be masked
    feat_map = {}
    if ANON:
        import hashlib
        feat_map = {f: "feature-" + hashlib.sha1(f.encode()).hexdigest()[:6] for f in feat_names}
        repo = "repo-" + hashlib.sha1(repo.encode()).hexdigest()[:8]
        if promoted or proposed:
            print("[pro-analytics] ⚠ --anonymize masks repo/feature identity in metrics; "
                  "learnings text ships verbatim — review it for sensitive paths before sharing.",
                  file=sys.stderr)
    def anon_feat(f):
        return feat_map.get(f, f)
    payload = summary_payload()
    if ANON:
        payload["features"] = {anon_feat(f): v for f, v in payload["features"].items()}
        payload["feature_filter"] = anon_feat(FEATURE) if FEATURE else None
        recs = []
        for r in payload["recommendations"]:
            for orig, masked in feat_map.items():
                r = r.replace(orig, masked)
            recs.append(r)
        payload["recommendations"] = recs
    failures_out = []
    for e in fail_events:
        row = {"ts": e.get("ts"), "event": e.get("event"),
               "feature": anon_feat(str(e["feature"])) if e.get("feature") else None,
               "iteration": e.get("iteration")}
        if not ANON:
            row["detail"] = e.get("detail")
        failures_out.append(row)
    bundle = {
        "schema": "speckit-pro/insights-bundle",
        "schema_version": 1,
        "generated_at": os.environ.get("GENERATED_AT"),
        "source": {"repo": repo,
                   "branch": None if ANON else (os.environ.get("BRANCH") or None),
                   "pro_version": os.environ.get("PRO_VERSION") or None,
                   "anonymized": ANON},
        "window": {"last": LAST, "feature": (anon_feat(FEATURE) if FEATURE else None),
                   "runs": len(runs)},
        "analytics": payload,
        "failures": failures_out,
        "learnings": {"promoted": promoted, "proposed": proposed},
    }
    blob = json.dumps(bundle, indent=2)
    if TO_STDOUT:
        print(blob)
        sys.exit(0)
    out = OUT or os.path.join(METRICS_DIR, "insights-%s-%s.json" % (
        repo, (os.environ.get("GENERATED_AT") or "")[:10].replace("-", "")))
    d = os.path.dirname(out)
    if d:
        os.makedirs(d, exist_ok=True)
    with open(out, "w", encoding="utf-8") as fh:
        fh.write(blob + "\n")
    print("insights bundle written: %s" % out)
    print("  runs=%d  failures=%d  learnings=%d (promoted %d / proposed %d)" % (
        len(runs), len(failures_out), len(promoted) + len(proposed), len(promoted), len(proposed)))
    print("share the file, then in the target repo: pro-analytics.sh import %s [--to-ledger]"
          % os.path.basename(out))
    sys.exit(0)

# ── import: cross-repo rollup (+ optional ledger feed) ───────────────────────
if CMD == "import":
    files = [p for p in (os.environ.get("IMPORT_FILES") or "").splitlines() if p.strip()]
    bundles = []
    for p in files:
        try:
            with open(p, encoding="utf-8") as fh:
                b = json.load(fh)
        except Exception as ex:
            print("[pro-analytics] ⚠ skipping %s: %s" % (p, ex), file=sys.stderr)
            continue
        if not isinstance(b, dict) or b.get("schema") != "speckit-pro/insights-bundle":
            print("[pro-analytics] ⚠ skipping %s: not a speckit-pro insights bundle" % p, file=sys.stderr)
            continue
        bundles.append(b)
    if not bundles:
        print("[pro-analytics] ✗ no valid bundles to import", file=sys.stderr)
        sys.exit(1)

    # A bundle is foreign input: nested fields may carry wrong TYPES, not just
    # be missing (`or {}` only covers null). Extraction is all-or-nothing per
    # bundle — parse into locals first, merge into the shared rollup only on
    # success — so one malformed bundle is skipped loudly and can never abort
    # the batch or half-merge.
    def obj(v, name):
        if v is None:
            return {}
        if not isinstance(v, dict):
            raise TypeError("%s must be an object, got %s" % (name, type(v).__name__))
        return v
    def lst(v, name):
        if v is None:
            return []
        if not isinstance(v, list):
            raise TypeError("%s must be a list, got %s" % (name, type(v).__name__))
        return v

    sources, merged_tax, rec_count, learnings = [], {}, {}, []
    for b in bundles:
        try:
            src   = obj(b.get("source"), "source")
            an    = obj(b.get("analytics"), "analytics")
            h     = obj(an.get("health"), "analytics.health")
            cost  = obj(an.get("cost"), "analytics.cost")
            feats = obj(an.get("features"), "analytics.features")
            tax   = obj(an.get("taxonomy"), "analytics.taxonomy")
            recs  = lst(an.get("recommendations"), "analytics.recommendations")
            lr    = obj(b.get("learnings"), "learnings")
            window = obj(b.get("window"), "window")
            scored = sum((v.get("scored") or 0) for v in feats.values() if isinstance(v, dict))
            passes = sum((v.get("passes") or 0) for v in feats.values() if isinstance(v, dict))
            src_row = {
                "repo": src.get("repo") or "?", "pro_version": src.get("pro_version"),
                "generated_at": b.get("generated_at"),
                "runs": window.get("runs"),
                "health_score": h.get("score"), "health_grade": h.get("grade"),
                "total_cost_usd": cost.get("total_usd"),
                "pass_rate": (passes / scored) if scored else None,
            }
            l_rows = []
            for status in ("promoted", "proposed"):
                for entry in lst(lr.get(status), "learnings.%s" % status):
                    if isinstance(entry, str) and entry.strip():
                        l_rows.append({"source": src.get("repo") or "?", "status": status,
                                       "generated_at": b.get("generated_at") or "?",
                                       "entry": entry})
        except (TypeError, AttributeError, ValueError) as ex:
            name = "?"
            s = b.get("source")
            if isinstance(s, dict):
                name = s.get("repo") or "?"
            print("[pro-analytics] ⚠ skipping malformed bundle (repo %s): %s" % (name, ex),
                  file=sys.stderr)
            continue
        sources.append(src_row)
        for k, v in tax.items():
            t = merged_tax.setdefault(k, {"total": 0, "repos": 0})
            t["total"] += v if isinstance(v, int) else 0
            t["repos"] += 1
        for r in recs:
            if isinstance(r, str) and not r.startswith("Healthy across the board"):
                rec_count[r] = rec_count.get(r, 0) + 1
        learnings.extend(l_rows)
    if not sources:
        print("[pro-analytics] ✗ no valid bundles to import", file=sys.stderr)
        sys.exit(1)

    ledger_added, ledger_skipped = [], 0
    if TO_LEDGER:
        ledger_added, ledger_skipped = append_to_ledger(IMPROVE_FILE, learnings)

    if AS_JSON:
        print(json.dumps({
            "bundles": len(sources),
            "sources": sources,
            "taxonomy": merged_tax,
            "recommendations": [{"text": t, "repos": n}
                                for t, n in sorted(rec_count.items(), key=lambda kv: -kv[1])],
            "learnings": learnings,
            "ledger": ({"appended": ledger_added, "skipped_duplicates": ledger_skipped}
                       if TO_LEDGER else None),
        }, indent=2))
        sys.exit(0)

    out = []
    out.append("═══ SpecKit Pro — imported insights (%d bundle%s) ═══" % (
        len(sources), "" if len(sources) == 1 else "s"))
    out.append("")
    out.append("── Sources ──")
    out.append("%-26s %-9s %-11s %-5s %-12s %-6s %s" % ("repo", "pro", "exported", "runs", "health", "pass", "cost"))
    for s in sources:
        out.append("%-26s %-9s %-11s %-5s %-12s %-6s %s" % (
            str(s["repo"])[:26], str(s["pro_version"] or "?")[:9],
            str(s["generated_at"] or "?")[:10],
            str(s["runs"]) if s["runs"] is not None else "?",
            ("%.1f (%s)" % (s["health_score"], s["health_grade"]))
                if isinstance(s["health_score"], (int, float)) else "n/a",
            ("%d%%" % round(s["pass_rate"] * 100))
                if isinstance(s["pass_rate"], (int, float)) else "—",
            fmtusd(s["total_cost_usd"])))
    out.append("")
    out.append("── Failure taxonomy (merged) ──")
    if merged_tax:
        for k, t in sorted(merged_tax.items(), key=lambda kv: -kv[1]["total"]):
            out.append("  %-26s %-5d across %d repo%s" % (
                k, t["total"], t["repos"], "" if t["repos"] == 1 else "s"))
    else:
        out.append("  no failures recorded in any bundle ✓")
    out.append("")
    out.append("── Recurring recommendations ──")
    if rec_count:
        for t, n in sorted(rec_count.items(), key=lambda kv: -kv[1])[:10]:
            out.append("  • [%d repo%s] %s" % (n, "" if n == 1 else "s", t))
    else:
        out.append("  none — every source reports healthy")
    out.append("")
    out.append("── Collected learnings (%d) ──" % len(learnings))
    if learnings:
        for l in learnings:
            first = l["entry"].splitlines()[0]
            out.append("  [%s · %s] %s" % (l["source"], l["status"], first[:110]))
    else:
        out.append("  none in any bundle")
    out.append("")
    if TO_LEDGER:
        out.append("── Ledger ──")
        out.append("  appended %d entr%s to %s under ## Proposed (human promotion still required); %d duplicate%s skipped" % (
            len(ledger_added), "y" if len(ledger_added) == 1 else "ies", IMPROVE_FILE,
            ledger_skipped, "" if ledger_skipped == 1 else "s"))
    else:
        out.append("Feed the collected learnings into this repo's improvements ledger as proposals: re-run with --to-ledger")
    text = "\n".join(out)
    print(text)
    if WRITE:
        dest = os.path.join(METRICS_DIR, "insights-imported.md")
        try:
            d = os.path.dirname(dest)
            if d:
                os.makedirs(d, exist_ok=True)
            with open(dest, "w", encoding="utf-8") as fh:
                fh.write("# SpecKit Pro — imported insights\n\n```\n" + text + "\n```\n")
            print("\n[written: %s]" % dest)
        except OSError as e:
            print("\n[write failed: %s]" % e, file=sys.stderr)
    sys.exit(0)

if CMD == "health":
    score, grade, comp = health()
    if AS_JSON:
        print(json.dumps({"score": score, "grade": grade, "components": comp,
                          "runs_in_window": len(runs), "taxonomy": taxonomy}, indent=2))
    else:
        print("health: %.1f/100 (grade %s) over %d run(s)" % (score, grade, len(runs)))
        for k, v in comp.items():
            print("  %-13s %.1f" % (k, v))
    if GATE:
        try:
            if score < float(GATE):
                print("GATE FAILED: %.1f < %s" % (score, GATE))
                sys.exit(1)
        except ValueError:
            pass
    sys.exit(0)

if AS_JSON:
    print(json.dumps(summary_payload(), indent=2))
    sys.exit(0)

lines = []
if CMD == "failures":
    render_failures(lines)
else:
    render_summary(lines)
text = "\n".join(lines)
print(text)
if WRITE:
    try:
        with open(os.environ["REPORT_OUT"], "w", encoding="utf-8") as fh:
            fh.write("# SpecKit Pro — analytics report\n\n```\n" + text + "\n```\n")
        print("\n[written: %s]" % os.environ["REPORT_OUT"])
    except OSError as e:
        print("\n[write failed: %s]" % e, file=sys.stderr)
PY
