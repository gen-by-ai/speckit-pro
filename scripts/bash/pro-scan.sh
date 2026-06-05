#!/usr/bin/env bash
# =============================================================================
# pro-scan.sh — terminal entrypoint for SpecKit Pro parallel deep-analysis.
#
# The terminal twin of the /pro.scan command. Partitions the repo, fans workers
# out across the cli substrate (or sequential fallback), assembles the merged
# report under .knowledge/scan/. Never aborts: degrades to sequential and warns.
#
# Usage:
#   pro-scan.sh [--root <path>] [--workers <N>] [--substrate cli|sequential]
#               [--strategy dependency-cluster|size-bucket] [--timeout <sec>]
#               [--dry-run] [--json] [--no-knowledge]
#
# Exit: 0 complete (incl. degraded-to-sequential / self-skip); 3 circuit-broken.
# =============================================================================
set -u

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
source "$SCRIPT_DIR/lib/pro-fanout-common.sh"

ROOT="" WORKERS="" SUBSTRATE="auto" STRATEGY="dependency-cluster"
TIMEOUT="" DRY_RUN=false JSON=false NO_KNOWLEDGE=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --root)        ROOT="$2"; shift 2 ;;
    --workers)     WORKERS="$2"; shift 2 ;;
    --substrate)   SUBSTRATE="$2"; shift 2 ;;
    --strategy)    STRATEGY="$2"; shift 2 ;;
    --timeout)     TIMEOUT="$2"; shift 2 ;;
    --dry-run)     DRY_RUN=true; shift ;;
    --json)        JSON=true; shift ;;
    --no-knowledge) NO_KNOWLEDGE=true; shift ;;
    -h|--help)     sed -n '2,20p' "$0"; exit 0 ;;
    *)             fanout_err "unknown arg: $1"; exit 1 ;;
  esac
done

PROJECT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
[[ -z "$ROOT" ]] && ROOT="$PROJECT_ROOT"
cd "$PROJECT_ROOT" || exit 1

# ── Config (best-effort; CLI args win) ────────────────────────────────────────
read_cfg() {  # read_cfg <dotted.key> <default>
  local key="$1" def="$2"
  python3 - "$key" "$def" <<'PY' 2>/dev/null || echo "$2"
import sys
key, default = sys.argv[1], sys.argv[2]
val = None
try:
    import yaml
    for p in (".specify/extensions/pro/pro-config.yml",
              ".specify/extensions/pro/pro-config.local.yml", "pro-config.yml"):
        try:
            d = yaml.safe_load(open(p)) or {}
        except OSError:
            continue
        cur = d
        for part in key.split("."):
            cur = cur.get(part) if isinstance(cur, dict) else None
            if cur is None: break
        if cur is not None: val = cur
except Exception:
    pass
print(default if val is None else val)
PY
}

ENABLED="$(read_cfg parallel.enabled true)"
if [[ "$ENABLED" == "false" || "$ENABLED" == "False" ]]; then
  fanout_log "parallel.enabled is false — skipping scan."
  exit 0
fi
[[ "$SUBSTRATE" == "auto" ]] && SUBSTRATE="$(read_cfg parallel.substrate auto)"
[[ -z "$TIMEOUT" ]] && TIMEOUT="$(read_cfg parallel.worker_timeout_seconds 300)"
METRICS_FILE="$(read_cfg parallel.metrics_file .knowledge/metrics/fanout-metrics.jsonl)"
MAX_TOKENS="$(read_cfg parallel.max_tokens 0)"

# ── Resolve substrate ─────────────────────────────────────────────────────────
RESOLVED="$(fanout_detect_substrate "$SUBSTRATE" "")"
if [[ "$RESOLVED" == "in-harness" ]]; then
  # pro-scan.sh is the terminal path; in-harness means "no terminal CLI" here → cli if available else sequential
  RESOLVED="$(fanout_detect_substrate auto "")"
fi
if [[ "$RESOLVED" == "sequential" ]]; then
  fanout_warn "no agent CLI found (copilot|claude|gemini|codex) — concurrency unavailable; running sequential."
fi

# ── Workers ───────────────────────────────────────────────────────────────────
[[ -z "$WORKERS" ]] && WORKERS="$(read_cfg parallel.workers.cli 0)"
[[ "$WORKERS" =~ ^[0-9]+$ ]] || WORKERS=0
if [[ "$WORKERS" -eq 0 ]]; then WORKERS="$(fanout_default_workers "$RESOLVED")"; fi
WORKERS="$(fanout_clamp "$WORKERS" "$RESOLVED")"
[[ "$RESOLVED" == "sequential" ]] && WORKERS=1

# ── Run context ───────────────────────────────────────────────────────────────
STAMP="$(date -u +%Y%m%d-%H%M%S)"
RUN_ID="scan-${STAMP}-$$"
WORK="$PROJECT_ROOT/.knowledge/scan/.work/$RUN_ID"
mkdir -p "$WORK/results"

# ── Partition ─────────────────────────────────────────────────────────────────
python3 scripts/local/partition.py --root "$ROOT" --workers "$WORKERS" \
  --strategy "$STRATEGY" --max-tokens "$MAX_TOKENS" --out "$WORK/portions.json" || {
    fanout_err "partition failed"; exit 1; }

PCOUNT="$(python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get('portion_count',0))" "$WORK/portions.json")"

if [[ "$DRY_RUN" == true ]]; then
  fanout_log "DRY RUN — substrate=$RESOLVED workers=$WORKERS strategy=$STRATEGY portions=$PCOUNT"
  python3 -c "
import json,sys
d=json.load(open(sys.argv[1]))
for p in d['portions']:
    print('  %-6s %-18s %3d files  ~%d tok' % (p['portion_id'], p['cluster_label'], len(p['files']), p['est_tokens']))
" "$WORK/portions.json"
  fanout_log "would dispatch $PCOUNT worker(s) via $RESOLVED; no workers spawned."
  rm -rf "$WORK"
  exit 0
fi

# ── Dispatch ──────────────────────────────────────────────────────────────────
START="$(fanout_now_s)"
bash "$SCRIPT_DIR/pro-fanout.sh" --portions "$WORK/portions.json" --work-dir "$WORK" \
  --out-dir "$WORK/results" --substrate "$RESOLVED" --workers "$WORKERS" \
  --timeout "$TIMEOUT" --metrics-file "$METRICS_FILE" --run-id "$RUN_ID"
RC=$?
WALL_MS=$(( ( $(fanout_now_s) - START ) * 1000 ))

# ── Assemble report ───────────────────────────────────────────────────────────
python3 scripts/local/scan_report.py --portions "$WORK/portions.json" \
  --results-dir "$WORK/results" --out-dir "$PROJECT_ROOT/.knowledge/scan" \
  --run-id "$RUN_ID" --substrate "$RESOLVED" --workers-eff "$WORKERS" --workers-req "$WORKERS" \
  --repo "$(basename "$PROJECT_ROOT")" --wall-ms "$WALL_MS"

REPORT="$PROJECT_ROOT/.knowledge/scan/latest.md"
if [[ "$NO_KNOWLEDGE" != true ]]; then
  fanout_log "findings ready in $REPORT — run /pro.knowledge-sync to graduate durable findings into .knowledge/ (additive/proposal only)."
fi

if [[ "$JSON" == true ]]; then
  python3 -c "
import json
print(json.dumps({'run_id':'$RUN_ID','substrate':'$RESOLVED','workers':$WORKERS,
                  'portions':$PCOUNT,'wall_ms':$WALL_MS,'report':'$REPORT','rc':$RC}))"
fi

[[ "$RC" -eq 3 ]] && { fanout_err "circuit breaker tripped"; exit 3; }
fanout_ok "scan complete → $REPORT"
exit 0
