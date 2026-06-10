#!/usr/bin/env bash
# =============================================================================
# pro-report.sh — run-report engine for the SpecKit Pro pipeline (`/pro.go`).
#
# Answers the three questions a `/pro.go` run could never answer before:
#   1. How long did it take?          (wall-clock from start marker to finish)
#   2. What did it produce?           (files +/-, lines +/-, commits, tasks, iterations)
#   3. How did it go / where improve? (eval verdict+score, parallel speedup, heuristic notes)
#
# It also closes the self-improvement loop: every finished run appends a compact
# summary line to .knowledge/metrics/runs.jsonl, and `aggregate` turns that log
# into cross-run trends + concrete recommendations the NEXT run reads.
#
# Subcommands:
#   start     [--feature <slug>] [--run-id <id>]
#               Stamp a run-start marker (epoch, git HEAD, branch). Echoes RUN_ID.
#   phase     <start|stop> <run_id> <phase_name>
#               Append a {phase,event,ts,ts_s} marker to the per-run manifest's
#               phases[] array. Self-no-ops (warn, exit 0) when the manifest is absent.
#   call      <run_id> [--phase P] [--status continue|complete|blocked|error]
#             [--cost-usd N] [--input-tokens N] [--output-tokens N]
#             [--cache-read-tokens N] [--cache-creation-tokens N] [--turns N]
#             [--duration-ms N] [--session-id S] [--source json|text-fallback]
#             [--rework] [--intervention] [--cb-trip]
#               Append one entry to the per-run manifest's calls[] array. Flags NOT
#               passed are stored as JSON null (never 0). Self-no-ops if manifest absent.
#   finish    [--feature <slug>] [--run-id <id>] [--eval-verdict V] [--eval-score N]
#             [--iterations N] [--max-iterations N] [--parallel <on|off>]
#             [--progress-file <path>] [--no-stdout]
#               Compute the delta, roll up phases[]/calls[] into cost/token/per-phase
#               telemetry, write specs/<feature>/run-report.md, append to runs.jsonl.
#               --progress-file extracts <pro-uncertainty> blocks → uncertainties.md.
#               When reporting.otel.enabled resolves true, hands the manifest to
#               pro-otel-emit.sh (failures warn-only, never abort).
#   aggregate [--last N] [--json]
#               Cross-run dashboard + recommendations + eval-score regression flag.
#   event <event> <run_id> <portion> <substrate> [duration_ms] [error]
#               Append one fan-out telemetry line (the in-harness loop's logger).
#
# Design rules (match pro-fanout-common.sh / pro-local-common.sh):
#   - bash 3.2 compatible (macOS default): no associative arrays, no mapfile, no ${x^^}.
#   - python3 is a hard engine dependency — used for all JSON read/write + report assembly.
#   - Never abort the pipeline: every failure degrades to a partial report + a warning.
#   - All state lives under gitignored .knowledge/metrics/ — PR-safe.
#     SPECKIT_PRO_METRICS_DIR overrides the metrics root (hermetic tests / sandboxes).
#   - Run lifecycle: start writes status:"open"; finish closes it to "finished"; a later
#     start's orphan sweep closes abandoned "open" records as "interrupted". Manifest
#     mutations are flock-guarded read-modify-writes (concurrent writers lose nothing).
#   - .current is a single-run convenience fallback; concurrent runs pass --run-id.
# =============================================================================

set -uo pipefail

# ── Locate self + shared helpers ────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/pro-fanout-common.sh
if [[ -f "$SCRIPT_DIR/lib/pro-fanout-common.sh" ]]; then
  . "$SCRIPT_DIR/lib/pro-fanout-common.sh"
else
  # Minimal fallbacks if the shared lib is unavailable (installed-snapshot drift).
  fanout_now_iso() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
  fanout_now_s()   { date -u +%s; }
  fanout_log()  { printf "[report] %s\n"      "$*" >&2; }
  fanout_warn() { printf "[report WARN] %s\n" "$*" >&2; }
  fanout_err()  { printf "[report ERR] %s\n"  "$*" >&2; }
  fanout_ok()   { printf "[report OK] %s\n"   "$*" >&2; }
  fanout_telemetry() { :; }
fi

PROJECT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
# SPECKIT_PRO_METRICS_DIR overrides the metrics root (hermetic tests / sandboxes).
METRICS_DIR="${SPECKIT_PRO_METRICS_DIR:-$PROJECT_ROOT/.knowledge/metrics}"
RUNS_DIR="$METRICS_DIR/runs"
RUNS_LOG="$METRICS_DIR/runs.jsonl"
FANOUT_METRICS="$METRICS_DIR/fanout-metrics.jsonl"
LOCAL_METRICS="$METRICS_DIR/local-metrics.jsonl"
EMPTY_TREE="4b825dc642cb6eb9a060e54bf8d69288fbee4904"  # git's canonical empty tree

have_py() { command -v python3 >/dev/null 2>&1; }

# ── Config walker (COPIED from pro-local-common.sh::local_config_get) ────────
# Indentation-based YAML reader for a dotted key path. No yq dependency.
# Returns the scalar value, or "" if not found / python3 unavailable.
report_config_get() {
  local key="$1" cfg="$2"
  [[ -f "$cfg" ]] || { echo ""; return 0; }
  have_py || { echo ""; return 0; }
  python3 - "$key" "$cfg" <<'PY'
import sys
key, cfg_path = sys.argv[1], sys.argv[2]
parts = key.split(".")
try:
    with open(cfg_path, encoding="utf-8") as f:
        lines = f.readlines()
except Exception:
    print(""); sys.exit(0)

def strip_comment(s):
    in_str = False
    for i, ch in enumerate(s):
        if ch in ("'", '"'):
            in_str = not in_str
        elif ch == "#" and not in_str:
            return s[:i]
    return s

stack = []
target_value = None
for raw in lines:
    line = strip_comment(raw).rstrip()
    if not line.strip():
        continue
    stripped = line.lstrip(" ")
    indent = len(line) - len(stripped)
    while stack and stack[-1][0] >= indent:
        stack.pop()
    if ":" not in stripped:
        continue
    k, _, v = stripped.partition(":")
    k = k.strip()
    v = v.strip()
    stack.append((indent, k))
    cur_path = [s[1] for s in stack]
    if cur_path == parts:
        target_value = v
        break

if target_value is None:
    print("")
else:
    if (target_value.startswith('"') and target_value.endswith('"')) or \
       (target_value.startswith("'") and target_value.endswith("'")):
        target_value = target_value[1:-1]
    print(target_value)
PY
}

# Resolve the pro-config.yml location (mirrors pro-local-common.sh::local_resolve_config).
report_resolve_config() {
  local root="$1" candidate
  for candidate in \
      "$root/.specify/extensions/pro/pro-config.local.yml" \
      "$root/.specify/extensions/pro/pro-config.yml" \
      "$root/pro-config.yml"; do
    [[ -f "$candidate" ]] && { echo "$candidate"; return 0; }
  done
  # Fall back to the bundled template alongside this script's extension root.
  local ext_root; ext_root="$(cd "$SCRIPT_DIR/.." && pwd 2>/dev/null)"
  if [[ -f "$ext_root/pro-config.template.yml" ]]; then
    echo "$ext_root/pro-config.template.yml"; return 0
  fi
  echo ""
}

PRO_CONFIG_PATH="$(report_resolve_config "$PROJECT_ROOT")"

# ── Eval-score regression knobs (reporting.regression.*; defaults 5/10/70/3) ──
_v="$(report_config_get reporting.regression.window "$PRO_CONFIG_PATH")"
export REGR_WINDOW="${_v:-5}"
_v="$(report_config_get reporting.regression.margin "$PRO_CONFIG_PATH")"
export REGR_MARGIN="${_v:-10}"
_v="$(report_config_get reporting.regression.pass_threshold "$PRO_CONFIG_PATH")"
export REGR_PASS_THRESHOLD="${_v:-70}"
_v="$(report_config_get reporting.regression.min_prior_scored "$PRO_CONFIG_PATH")"
export REGR_MIN_PRIOR="${_v:-3}"
unset _v

# Resolve a feature slug → spec dir. Accepts slug or empty (auto-detect single).
resolve_spec_dir() {
  local feat="$1"
  if [[ -n "$feat" && -d "$PROJECT_ROOT/specs/$feat" ]]; then
    echo "$PROJECT_ROOT/specs/$feat"; return 0
  fi
  if [[ -n "$feat" ]]; then
    # tolerate a full path or a fuzzy match
    [[ -d "$feat" ]] && { echo "$feat"; return 0; }
    local hit; hit="$(ls -d "$PROJECT_ROOT/specs/"*"$feat"* 2>/dev/null | head -1)"
    [[ -n "$hit" ]] && { echo "$hit"; return 0; }
  fi
  # auto-detect: exactly one spec dir with a tasks.md
  local cands; cands="$(ls -d "$PROJECT_ROOT/specs/"*/ 2>/dev/null)"
  local only="" n=0 d
  for d in $cands; do [[ -f "${d}tasks.md" ]] && { only="$d"; n=$(( n + 1 )); }; done
  [[ "$n" -eq 1 ]] && { echo "${only%/}"; return 0; }
  echo ""; return 1
}

# Human-readable duration from seconds.
human_dur() {
  local s="$1" h m
  [[ "$s" =~ ^[0-9]+$ ]] || { echo "unknown"; return; }
  h=$(( s / 3600 )); m=$(( (s % 3600) / 60 )); s=$(( s % 60 ))
  if   [[ "$h" -gt 0 ]]; then printf "%dh %dm %ds" "$h" "$m" "$s"
  elif [[ "$m" -gt 0 ]]; then printf "%dm %ds" "$m" "$s"
  else printf "%ds" "$s"; fi
}

# =============================================================================
# start
# =============================================================================
cmd_start() {
  local feat="" run_id=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --feature) feat="${2:-}"; shift 2 ;;
      --run-id)  run_id="${2:-}"; shift 2 ;;
      *) shift ;;
    esac
  done
  mkdir -p "$RUNS_DIR" 2>/dev/null
  local stamp; stamp="$(date -u +"%Y%m%d-%H%M%S")"
  [[ -z "$run_id" ]] && run_id="run-${stamp}-$(printf '%04x' $(( RANDOM )))"

  # ── Orphan sweep: close prior runs left "open" as "interrupted" (FR-003) ──
  # flock CAS per manifest: only an open record transitions — exactly one closer
  # wins; finished and legacy status-less records are never touched.
  if have_py; then
    NEWRUN="$run_id" NOW_ISO="$(fanout_now_iso)" python3 - "$RUNS_DIR" <<'PY' || fanout_warn "start: orphan sweep failed (continuing)"
import fcntl, glob, json, os, sys
runs_dir = sys.argv[1]
for p in glob.glob(os.path.join(runs_dir, "*.json")):
    try:
        with open(p, "r+", encoding="utf-8") as fh:
            fcntl.flock(fh.fileno(), fcntl.LOCK_EX)
            try:
                d = json.load(fh)
            except Exception:
                continue
            if d.get("status") == "open":
                d["status"] = "interrupted"
                d["interrupted_at"] = os.environ.get("NOW_ISO")
                d["interrupted_by"] = os.environ.get("NEWRUN")
                fh.seek(0)
                fh.truncate()
                json.dump(d, fh, indent=2)
                print("[report] orphan sweep: closed %s as interrupted" % os.path.basename(p), file=sys.stderr)
    except Exception:
        continue
PY
  fi

  local started_s started_iso branch head
  started_s="$(fanout_now_s)"; started_iso="$(fanout_now_iso)"
  branch="$(git -C "$PROJECT_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
  head="$(git -C "$PROJECT_ROOT" rev-parse HEAD 2>/dev/null || echo '')"

  if have_py; then
    RUN="$run_id" FEAT="$feat" SS="$started_s" SI="$started_iso" BR="$branch" HD="$head" \
      python3 - "$RUNS_DIR/$run_id.json" <<'PY'
import json, os, sys
rec = {
  "run_id": os.environ["RUN"],
  "feature": os.environ.get("FEAT") or None,
  "status": "open",
  "started_at": os.environ["SI"],
  "started_at_s": int(os.environ["SS"]),
  "start_branch": os.environ["BR"],
  "start_head": os.environ.get("HD") or None,
}
with open(sys.argv[1], "w", encoding="utf-8") as fh:
    json.dump(rec, fh, indent=2)
PY
  else
    printf '{"run_id":"%s","status":"open","started_at":"%s","started_at_s":%s,"start_head":"%s"}\n' \
      "$run_id" "$started_iso" "$started_s" "$head" > "$RUNS_DIR/$run_id.json"
  fi
  # .current is a single-run convenience fallback ONLY — concurrent runs must pass
  # run-ids explicitly (both /pro.go and the orchestrator do). Written atomically.
  printf '%s\n' "$run_id" > "$RUNS_DIR/.current.$$" && mv "$RUNS_DIR/.current.$$" "$RUNS_DIR/.current"

  # ── Adopt skip events spooled before this run existed (pending-skips.jsonl) ──
  if [[ -f "$RUNS_DIR/pending-skips.jsonl" ]] && have_py; then
    python3 - "$RUNS_DIR/$run_id.json" "$RUNS_DIR/pending-skips.jsonl" <<'PY' || fanout_warn "start: pending-skips adoption failed (spool kept)"
import fcntl, json, os, sys
mf, spool = sys.argv[1], sys.argv[2]
events, dropped = [], 0
for ln in open(spool, encoding="utf-8"):
    ln = ln.strip()
    if not ln:
        continue
    try:
        events.append(json.loads(ln))
    except Exception:
        dropped += 1
with open(mf, "r+", encoding="utf-8") as fh:
    fcntl.flock(fh.fileno(), fcntl.LOCK_EX)
    d = json.load(fh)
    for ev in events:
        # Route by shape: decision events carry "gate"; everything else is a skip.
        key = "decisions" if "gate" in ev else "skips"
        if not isinstance(d.get(key), list):
            d[key] = []
        d[key].append(ev)
    fh.seek(0)
    fh.truncate()
    json.dump(d, fh, indent=2)
os.unlink(spool)
if events or dropped:
    print("[report] adopted %d pending skip(s)%s" % (
        len(events), (", dropped %d malformed" % dropped) if dropped else ""), file=sys.stderr)
PY
  fi

  fanout_log "run-report: started run ${run_id} on branch ${branch} at ${started_iso}"
  # stdout = the run id, so the caller can capture it cleanly.
  printf '%s\n' "$run_id"
}

# =============================================================================
# phase — append a {phase,event,ts,ts_s} marker to the manifest's phases[] array
# =============================================================================
cmd_phase() {
  local event="${1:-}" run_id="${2:-}" phase_name="${3:-}"
  if [[ -z "$event" || -z "$run_id" || -z "$phase_name" ]]; then
    fanout_err "usage: pro-report.sh phase <start|stop> <run_id> <phase_name>"; return 2
  fi
  case "$event" in
    start|stop) ;;
    *) fanout_err "phase: event must be 'start' or 'stop' (got '$event')"; return 2 ;;
  esac
  local manifest="$RUNS_DIR/$run_id.json"
  if [[ ! -f "$manifest" ]]; then
    fanout_warn "phase: no manifest for run '$run_id' — skipping ($event $phase_name)"; return 0
  fi
  have_py || { fanout_warn "phase: python3 unavailable — skipping"; return 0; }

  local now_iso now_s
  now_iso="$(fanout_now_iso)"; now_s="$(fanout_now_s)"
  PH="$phase_name" EV="$event" TI="$now_iso" TS="$now_s" \
    python3 - "$manifest" <<'PY' || { fanout_warn "phase: read-modify-write failed for $run_id"; exit 0; }
import fcntl, json, os, sys
mf = sys.argv[1]
# flock-guarded read-modify-write: concurrent phase/call writers must never lose entries.
with open(mf, "r+", encoding="utf-8") as fh:
    fcntl.flock(fh.fileno(), fcntl.LOCK_EX)
    try:
        d = json.load(fh)
    except Exception:
        d = {}
    if not isinstance(d.get("phases"), list):
        d["phases"] = []
    d["phases"].append({
        "phase": os.environ["PH"],
        "event": os.environ["EV"],
        "ts": os.environ["TI"],
        "ts_s": int(os.environ["TS"]),
    })
    fh.seek(0)
    fh.truncate()
    json.dump(d, fh, indent=2)
PY
  fanout_log "phase: $event $phase_name (run $run_id)"
}

# =============================================================================
# call — append one entry to the manifest's calls[] array
#        Flags NOT passed are stored as JSON null (NEVER 0).
# =============================================================================
cmd_call() {
  local run_id="${1:-}"; shift || true
  if [[ -z "$run_id" || "$run_id" == --* ]]; then
    fanout_err "usage: pro-report.sh call <run_id> [--phase P] [--status S] [--cost-usd N] ..."; return 2
  fi
  # Unset sentinels stay empty → emitted as JSON null. Boolean flags default false.
  local f_phase="" f_status="" f_cost="" f_in="" f_out="" f_cread="" f_ccreate=""
  local f_turns="" f_dur="" f_session="" f_source="" f_rework=0 f_intervention=0 f_cbtrip=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --phase)                 f_phase="${2:-}"; shift 2 ;;
      --status)                f_status="${2:-}"; shift 2 ;;
      --cost-usd)              f_cost="${2:-}"; shift 2 ;;
      --input-tokens)          f_in="${2:-}"; shift 2 ;;
      --output-tokens)         f_out="${2:-}"; shift 2 ;;
      --cache-read-tokens)     f_cread="${2:-}"; shift 2 ;;
      --cache-creation-tokens) f_ccreate="${2:-}"; shift 2 ;;
      --turns)                 f_turns="${2:-}"; shift 2 ;;
      --duration-ms)           f_dur="${2:-}"; shift 2 ;;
      --session-id)            f_session="${2:-}"; shift 2 ;;
      --source)                f_source="${2:-}"; shift 2 ;;
      --rework)                f_rework=1; shift ;;
      --intervention)          f_intervention=1; shift ;;
      --cb-trip)               f_cbtrip=1; shift ;;
      *) shift ;;
    esac
  done
  local manifest="$RUNS_DIR/$run_id.json"
  if [[ ! -f "$manifest" ]]; then
    fanout_warn "call: no manifest for run '$run_id' — skipping"; return 0
  fi
  have_py || { fanout_warn "call: python3 unavailable — skipping"; return 0; }

  local now_iso; now_iso="$(fanout_now_iso)"
  TI="$now_iso" PHASE="$f_phase" STATUS="$f_status" COST="$f_cost" \
  INTOK="$f_in" OUTTOK="$f_out" CREAD="$f_cread" CCREATE="$f_ccreate" \
  TURNS="$f_turns" DUR="$f_dur" SESSION="$f_session" SOURCE="$f_source" \
  REWORK="$f_rework" INTERVENTION="$f_intervention" CBTRIP="$f_cbtrip" \
    python3 - "$manifest" <<'PY' || { fanout_warn "call: read-modify-write failed for $run_id"; exit 0; }
import fcntl, json, os, sys
mf = sys.argv[1]
g = os.environ.get
def s_or_null(k):
    v = g(k)
    return v if (v is not None and v != "") else None
def num_or_null(k):
    v = g(k)
    if v is None or v == "":
        return None
    try:
        if "." in v or "e" in v.lower():
            return float(v)
        return int(v)
    except Exception:
        try:
            return float(v)
        except Exception:
            return None
entry = {
    "ts": g("TI"),
    "phase": s_or_null("PHASE"),
    "status": s_or_null("STATUS"),
    "cost_usd": num_or_null("COST"),
    "input_tokens": num_or_null("INTOK"),
    "output_tokens": num_or_null("OUTTOK"),
    "cache_read_tokens": num_or_null("CREAD"),
    "cache_creation_tokens": num_or_null("CCREATE"),
    "turns": num_or_null("TURNS"),
    "duration_ms": num_or_null("DUR"),
    "session_id": s_or_null("SESSION"),
    "source": s_or_null("SOURCE"),
    "rework": (g("REWORK") == "1"),
    "intervention": (g("INTERVENTION") == "1"),
    "cb_trip": (g("CBTRIP") == "1"),
}
# flock-guarded read-modify-write (same rule as cmd_phase): no lost entries.
with open(mf, "r+", encoding="utf-8") as fh:
    fcntl.flock(fh.fileno(), fcntl.LOCK_EX)
    try:
        d = json.load(fh)
    except Exception:
        d = {}
    if not isinstance(d.get("calls"), list):
        d["calls"] = []
    d["calls"].append(entry)
    fh.seek(0)
    fh.truncate()
    json.dump(d, fh, indent=2)
PY
  fanout_log "call: recorded call for run $run_id (phase ${f_phase:-?}, status ${f_status:-?})"
}

# =============================================================================
# finish
# =============================================================================
cmd_finish() {
  local feat="" run_id="" eval_verdict="" eval_score="" iterations="" max_iter="" parallel="" to_stdout=1 progress_file=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --feature)        feat="${2:-}"; shift 2 ;;
      --run-id)         run_id="${2:-}"; shift 2 ;;
      --eval-verdict)   eval_verdict="${2:-}"; shift 2 ;;
      --eval-score)     eval_score="${2:-}"; shift 2 ;;
      --iterations)     iterations="${2:-}"; shift 2 ;;
      --max-iterations) max_iter="${2:-}"; shift 2 ;;
      --parallel)       parallel="${2:-}"; shift 2 ;;
      --progress-file)  progress_file="${2:-}"; shift 2 ;;
      --no-stdout)      to_stdout=0; shift ;;
      *) shift ;;
    esac
  done

  [[ -z "$run_id" && -f "$RUNS_DIR/.current" ]] && run_id="$(cat "$RUNS_DIR/.current" 2>/dev/null)"
  local manifest="$RUNS_DIR/$run_id.json"

  # ── Read start manifest (degrade gracefully if missing) ──
  local started_s started_iso start_head start_branch man_feat
  if [[ -n "$run_id" && -f "$manifest" ]] && have_py; then
    eval "$(python3 - "$manifest" <<'PY'
import json, sys, shlex
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    d = {}
def emit(k, v):
    print("%s=%s" % (k, shlex.quote("" if v is None else str(v))))
emit("started_s", d.get("started_at_s", ""))
emit("started_iso", d.get("started_at", ""))
emit("start_head", d.get("start_head", ""))
emit("start_branch", d.get("start_branch", ""))
emit("man_feat", d.get("feature", ""))
PY
)"
  else
    fanout_warn "run-report: no start manifest for run '${run_id:-<none>}' — emitting partial report"
    started_s=""; started_iso=""; start_head=""; start_branch=""; man_feat=""
  fi
  [[ -z "$feat" && -n "$man_feat" ]] && feat="$man_feat"

  local spec_dir; spec_dir="$(resolve_spec_dir "$feat")"
  [[ -z "$feat" && -n "$spec_dir" ]] && feat="$(basename "$spec_dir")"

  # ── Duration ──
  local now_s dur_s dur_h
  now_s="$(fanout_now_s)"
  if [[ "$started_s" =~ ^[0-9]+$ ]]; then dur_s=$(( now_s - started_s )); else dur_s=""; fi
  dur_h="$(human_dur "${dur_s:-x}")"

  # ── Git delta since start ──
  local base="$start_head"
  [[ -z "$base" ]] && base="$EMPTY_TREE"
  git -C "$PROJECT_ROOT" cat-file -e "$base^{commit}" 2>/dev/null || \
    git -C "$PROJECT_ROOT" cat-file -e "$base^{tree}" 2>/dev/null || base="$EMPTY_TREE"

  local added=0 modified=0 deleted=0 renamed=0 ins=0 del=0 commits=0
  local namestatus numstat commitlog
  namestatus="$(git -C "$PROJECT_ROOT" diff --name-status "$base" 2>/dev/null)"
  numstat="$(git -C "$PROJECT_ROOT" diff --numstat "$base" 2>/dev/null)"
  if [[ -n "$start_head" ]]; then
    commits="$(git -C "$PROJECT_ROOT" rev-list --count "$start_head"..HEAD 2>/dev/null || echo 0)"
    commitlog="$(git -C "$PROJECT_ROOT" log --format='%h %s' "$start_head"..HEAD 2>/dev/null)"
  else
    commits="$(git -C "$PROJECT_ROOT" rev-list --count HEAD 2>/dev/null || echo 0)"
    commitlog="$(git -C "$PROJECT_ROOT" log --format='%h %s' -n 20 2>/dev/null)"
  fi

  if [[ -n "$namestatus" ]]; then
    local st rest
    while IFS=$'\t' read -r st rest; do
      case "$st" in
        A*) added=$(( added + 1 )) ;;
        M*) modified=$(( modified + 1 )) ;;
        D*) deleted=$(( deleted + 1 )) ;;
        R*) renamed=$(( renamed + 1 )) ;;
      esac
    done <<< "$namestatus"
  fi
  if [[ -n "$numstat" ]]; then
    local a d _f
    while read -r a d _f; do
      [[ "$a" =~ ^[0-9]+$ ]] && ins=$(( ins + a ))
      [[ "$d" =~ ^[0-9]+$ ]] && del=$(( del + d ))
    done <<< "$numstat"
  fi

  # Untracked, never-committed files: `git diff <base>` can't see them. Count them
  # as additions (respecting .gitignore, so our own report/metrics aren't self-counted).
  local untracked_list untracked_n=0
  untracked_list="$(git -C "$PROJECT_ROOT" ls-files --others --exclude-standard 2>/dev/null)"
  if [[ -n "$untracked_list" ]]; then
    local uf l
    while IFS= read -r uf; do
      [[ -z "$uf" ]] && continue
      untracked_n=$(( untracked_n + 1 ))
      if [[ -f "$PROJECT_ROOT/$uf" ]]; then
        l="$(wc -l < "$PROJECT_ROOT/$uf" 2>/dev/null | tr -d ' ')"
        [[ "$l" =~ ^[0-9]+$ ]] && ins=$(( ins + l ))
      fi
    done <<< "$untracked_list"
    added=$(( added + untracked_n ))
  fi
  local files_changed=$(( added + modified + deleted + renamed ))

  # ── Tasks + iterations ──
  # NOTE: `grep -c` prints a number AND exits 1 when zero matches — capturing the
  # output and defaulting is correct; `|| echo 0` would append a SECOND "0".
  local tasks_done=0 tasks_total=0 iters="$iterations"
  if [[ -n "$spec_dir" && -f "$spec_dir/tasks.md" ]]; then
    tasks_done="$(grep -cE '^[[:space:]]*- \[[xX]\]' "$spec_dir/tasks.md" 2>/dev/null)"; tasks_done="${tasks_done:-0}"
    local tasks_open; tasks_open="$(grep -cE '^[[:space:]]*- \[ \]' "$spec_dir/tasks.md" 2>/dev/null)"; tasks_open="${tasks_open:-0}"
    tasks_total=$(( tasks_done + tasks_open ))
  fi
  local prog="$PROJECT_ROOT/.knowledge/features/$feat/progress.md"
  if [[ -z "$iters" && -f "$prog" ]]; then
    iters="$(grep -cE '^## Iteration ' "$prog" 2>/dev/null)"; iters="${iters:-0}"
  fi
  [[ -z "$iters" ]] && iters=0

  # ── Evaluation verdict/score (args override; else parse latest sprint eval) ──
  if [[ -z "$eval_verdict" || -z "$eval_score" ]]; then
    local evaldir="$PROJECT_ROOT/.knowledge/features/$feat/evaluations"
    local latest_eval; latest_eval="$(ls -t "$evaldir"/sprint-*.md 2>/dev/null | head -1)"
    if [[ -n "$latest_eval" ]]; then
      local tag; tag="$(grep -oE '<pro-eval>[^<]*</pro-eval>' "$latest_eval" 2>/dev/null | head -1 | sed -E 's/<\/?pro-eval>//g')"
      if [[ -n "$tag" ]]; then
        [[ -z "$eval_verdict" ]] && eval_verdict="${tag%%:*}"
        [[ -z "$eval_score"   ]] && eval_score="$(echo "$tag" | sed -E 's/[^0-9]//g')"
      fi
    fi
  fi
  [[ -z "$eval_verdict" ]] && eval_verdict="n/a"
  [[ -z "$eval_score"   ]] && eval_score=""

  # ── Parallelism + local-model telemetry within this run's window ──
  local par_dispatch=0 par_complete=0 par_fail=0 par_timeout=0 par_subs="" par_workms=0 par_maxms=0
  local loc_calls=0 loc_fail=0 loc_skips=0
  if have_py; then
    eval "$(SI="${started_iso:-}" FO="$FANOUT_METRICS" LM="$LOCAL_METRICS" python3 - <<'PY'
import json, os
def lines(p):
    try:
        return open(p, encoding="utf-8").read().splitlines()
    except Exception:
        return []
since = os.environ.get("SI") or ""
disp=comp=fail=tmo=workms=maxms=0; subs=set()
for ln in lines(os.environ["FO"]):
    try: r=json.loads(ln)
    except Exception: continue
    if since and r.get("ts","") < since: continue
    e=r.get("event");
    if e=="dispatch": disp+=1
    elif e=="complete":
        comp+=1; d=int(r.get("duration_ms",0) or 0); workms+=d
        if d>maxms: maxms=d
    elif e=="fail": fail+=1
    elif e=="timeout": tmo+=1
    if r.get("substrate"): subs.add(r["substrate"])
calls=lfail=skips=0
for ln in lines(os.environ["LM"]):
    try: r=json.loads(ln)
    except Exception: continue
    if since and r.get("ts","") < since: continue
    t=r.get("type")
    if t=="call":
        calls+=1
        if r.get("ok") is False or r.get("error"): lfail+=1
    elif t=="skip": skips+=1
print("par_dispatch=%d" % disp)
print("par_complete=%d" % comp)
print("par_fail=%d" % fail)
print("par_timeout=%d" % tmo)
print("par_workms=%d" % workms)
print("par_maxms=%d" % maxms)
print("par_subs=%s" % ("+".join(sorted(subs)) or ""))
print("loc_calls=%d" % calls)
print("loc_fail=%d" % lfail)
print("loc_skips=%d" % skips)
PY
)"
  fi
  # Parallelization factor of the fanned-out work: serial worker-time ÷ longest worker.
  # Honest measure of overlap (ideal ≈ #workers); avoids comparing to total run wall-clock.
  local speedup=""
  if [[ "$par_complete" -gt 1 && "$par_maxms" -gt 0 ]]; then
    speedup="$(awk -v w="$par_workms" -v m="$par_maxms" 'BEGIN{ printf "%.2f", w/m }')"
  fi
  [[ -z "$parallel" ]] && { [[ "$par_dispatch" -gt 0 ]] && parallel="on" || parallel="off"; }

  # ── Uncertainty digest (FR-015): extract <pro-uncertainty> blocks from the
  #    progress log into <spec-dir>/uncertainties.md with iteration context ──
  local unc_count=0
  if [[ -z "$progress_file" && -n "$feat" ]]; then
    # default: the feature's progress log, when present
    [[ -f "$PROJECT_ROOT/.knowledge/features/$feat/progress.md" ]] && \
      progress_file="$PROJECT_ROOT/.knowledge/features/$feat/progress.md"
  fi
  if [[ -n "$progress_file" && -f "$progress_file" && -n "$spec_dir" ]] && have_py; then
    unc_count="$(RUN="$run_id" python3 - "$progress_file" "$spec_dir/uncertainties.md" <<'PY'
import os, re, sys
src, dst = sys.argv[1], sys.argv[2]
text = open(src, encoding="utf-8").read()
out = ["# Uncertainty Digest", "",
       "> Aggregated from `%s` by pro-report.sh finish (run %s)." % (os.path.basename(src), os.environ.get("RUN") or "?"), ""]
count = 0
# Walk iteration sections; capture <pro-uncertainty> blocks with their heading context.
cur = "（no iteration heading）"
for chunk in re.split(r"(^## Iteration [^\n]*$)", text, flags=re.M):
    if chunk.startswith("## Iteration"):
        cur = chunk.strip("# ").strip()
        continue
    for m in re.finditer(r"<pro-uncertainty>(.*?)</pro-uncertainty>", chunk, flags=re.S):
        count += 1
        out.append("## %d. %s" % (count, cur))
        out.append("")
        out.append(m.group(1).strip())
        out.append("")
if count == 0:
    out.append("_No uncertainties raised during this run._")
with open(dst, "w", encoding="utf-8") as fh:
    fh.write("\n".join(out) + "\n")
print(count)
PY
)" || unc_count=0
    [[ "$unc_count" =~ ^[0-9]+$ ]] || unc_count=0
    fanout_log "uncertainty digest: $unc_count flag(s) → ${spec_dir}/uncertainties.md"
  fi

  # ── Heuristic "where to improve" notes ──
  local notes_file; notes_file="$(mktemp "${TMPDIR:-/tmp}/proreport.XXXXXX")"
  {
    [[ "$eval_verdict" != "PASS" && "$eval_verdict" != "n/a" ]] && \
      echo "- Evaluator returned **$eval_verdict** — strengthen the weakest contract criterion before the next run (see the sprint evaluation)."
    if [[ -n "$max_iter" && "$iters" -ge "$max_iter" && "$max_iter" -gt 0 ]]; then
      echo "- Hit the iteration ceiling ($iters/$max_iter) — tasks may be too coarse; split work-units or raise loop.max_iterations."
    fi
    if [[ "$tasks_total" -gt 0 && "$tasks_done" -lt "$tasks_total" ]]; then
      echo "- $(( tasks_total - tasks_done )) of $tasks_total tasks still open — the run stopped before full completion."
    fi
    if [[ "$parallel" == "off" && "$tasks_total" -ge 6 ]]; then
      echo "- Ran fully serial across $tasks_total tasks — enable \`parallel.phases.implement\` to fan out independent [P] tasks."
    fi
    if [[ -n "$speedup" ]] && awk -v s="$speedup" 'BEGIN{exit !(s<1.3)}'; then
      echo "- Parallelization factor was only ${speedup}× — one worker dominated (imbalanced partition or coupled tasks); review work-unit granularity."
    fi
    [[ "$par_fail" -gt 0 || "$par_timeout" -gt 0 ]] && \
      echo "- $par_fail parallel worker failure(s) / $par_timeout timeout(s) — inspect fan-out telemetry; consider raising worker_timeout_seconds."
    [[ "$loc_fail" -gt 0 ]] && \
      echo "- $loc_fail local-model call failure(s) — Ollama may be flaky or under-resourced; the premium verifier absorbed the slack."
    [[ "$loc_skips" -gt 0 ]] && \
      echo "- Local sidecar self-skipped $loc_skips time(s) (Ollama unreachable) — prep/review ran on the premium model only."
  } > "$notes_file"
  [[ ! -s "$notes_file" ]] && echo "- Clean run — no anomalies detected. Keep current settings." > "$notes_file"

  # ── Roll up phases[]/calls[] from the manifest into a telemetry JSON blob ──
  # Read-only over the manifest; produces a temp JSON file consumed by the
  # report-assembly block below. Absent/empty manifest ⇒ all-null telemetry.
  local telem_file; telem_file="$(mktemp "${TMPDIR:-/tmp}/protelem.XXXXXX")"
  echo '{}' > "$telem_file"
  if have_py; then
    MANIFEST="${manifest:-}" AGENT_CLI="$(report_config_get agent_cli "$PRO_CONFIG_PATH")" \
    GEN_MODEL_CFG="$(report_config_get orchestration.fallback_model "$PRO_CONFIG_PATH")" \
    EVAL_MODEL_CFG="$(report_config_get evaluation.evaluator_model "$PRO_CONFIG_PATH")" \
      python3 - "$telem_file" <<'PY' || true
import json, os, sys
out_path = sys.argv[1]
g = os.environ.get
mf = g("MANIFEST") or ""
d = {}
if mf:
    try:
        with open(mf, encoding="utf-8") as fh:
            d = json.load(fh)
    except Exception:
        d = {}
phases = d.get("phases") if isinstance(d.get("phases"), list) else []
calls  = d.get("calls")  if isinstance(d.get("calls"),  list) else []

# ── Per-phase wall-clock: sum of positive (stop_s − start_s) per phase ──
# Pair each stop with the most recent unmatched start of the same phase name.
per_phase = {}        # phase -> accumulated positive seconds
phase_order = []      # preserve first-seen order
open_starts = {}      # phase -> list of start ts_s awaiting a stop
for ev in phases:
    name = ev.get("phase")
    kind = ev.get("event")
    ts_s = ev.get("ts_s")
    if name is None or not isinstance(ts_s, (int, float)):
        continue
    if name not in per_phase:
        per_phase[name] = 0
        phase_order.append(name)
        open_starts[name] = []
    if kind == "start":
        open_starts[name].append(ts_s)
    elif kind == "stop":
        if open_starts[name]:
            start_s = open_starts[name].pop()
            delta = ts_s - start_s
            if delta > 0:
                per_phase[name] += delta
        # unpaired stop ⇒ contributes 0 (never fabricated)
per_phase_durations_s = [{"phase": p, "seconds": per_phase[p]} for p in phase_order]

# ── Cost / tokens: null when EVERY call lacks the field (genuine 0 stays 0) ──
def sum_field(field):
    seen = False
    total = 0
    for c in calls:
        v = c.get(field)
        if isinstance(v, (int, float)):
            seen = True
            total += v
    return (total if seen else None)

total_cost_usd = sum_field("cost_usd")
tok_in    = sum_field("input_tokens")
tok_out   = sum_field("output_tokens")
tok_cread = sum_field("cache_read_tokens")
tok_ccrt  = sum_field("cache_creation_tokens")
all_tok_null = all(x is None for x in (tok_in, tok_out, tok_cread, tok_ccrt))
tokens = None if all_tok_null else {
    "input": tok_in, "output": tok_out,
    "cache_read": tok_cread, "cache_creation": tok_ccrt,
}

# ── turns = max reported; session = last non-null; session_ids = distinct ──
turns = None
for c in calls:
    v = c.get("turns")
    if isinstance(v, (int, float)):
        turns = v if (turns is None or v > turns) else turns
session_id = None
session_ids = []
for c in calls:
    sid = c.get("session_id")
    if sid:
        session_id = sid
        if sid not in session_ids:
            session_ids.append(sid)

# ── flag counts ──
human_interventions = sum(1 for c in calls if c.get("intervention") is True)
rework_count        = sum(1 for c in calls if c.get("rework") is True)
cb_trips            = sum(1 for c in calls if c.get("cb_trip") is True)

# ── cli / models / completion_state: manifest-first, config fallback ──
cli = d.get("cli") or (g("AGENT_CLI") or None)
models = d.get("models")
if not isinstance(models, dict):
    models = {
        "generator": (d.get("generator_model") or g("GEN_MODEL_CFG") or None),
        "evaluator": (d.get("evaluator_model") or g("EVAL_MODEL_CFG") or None),
    }
completion_state = d.get("completion_state") or None

# ── telemetry_complete: false if any expected rollup field is unavailable ──
expected = [total_cost_usd, tokens, turns, session_id, completion_state]
telemetry_complete = bool(calls) and all(x is not None for x in expected) and bool(per_phase_durations_s)

skips     = d.get("skips")     if isinstance(d.get("skips"),     list) else []
decisions = d.get("decisions") if isinstance(d.get("decisions"), list) else []

blob = {
    "skips": skips,
    "decisions": decisions,
    "per_phase_durations_s": per_phase_durations_s,
    "total_cost_usd": total_cost_usd,
    "tokens": tokens,
    "turns": turns,
    "session_id": session_id,
    "session_ids": session_ids,
    "human_interventions": human_interventions,
    "rework_count": rework_count,
    "circuit_breaker_trips": cb_trips,
    "cli": cli,
    "models": models,
    "completion_state": completion_state,
    "telemetry_complete": telemetry_complete,
}
with open(out_path, "w", encoding="utf-8") as fh:
    json.dump(blob, fh)
PY
  fi

  # ── Assemble the report (python: markdown + jsonl summary) ──
  local report_path="${spec_dir:-$METRICS_DIR}/run-report.md"
  if have_py; then
    RUN="$run_id" FEAT="${feat:-unknown}" BR="${start_branch:-unknown}" \
    SI="${started_iso:-unknown}" FI="$(fanout_now_iso)" DURS="${dur_s:-}" DURH="$dur_h" \
    ADD="$added" MOD="$modified" DEL="$deleted" REN="$renamed" FC="$files_changed" \
    INS="$ins" DELLINES="$del" COMMITS="$commits" COMMITLOG="$commitlog" \
    TDONE="$tasks_done" TTOTAL="$tasks_total" ITERS="$iters" MAXITER="${max_iter:-}" \
    EV="$eval_verdict" ES="$eval_score" PAR="$parallel" PSUBS="$par_subs" \
    PDISP="$par_dispatch" PCOMP="$par_complete" PFAIL="$par_fail" PTMO="$par_timeout" \
    SPEEDUP="$speedup" LCALLS="$loc_calls" LFAIL="$loc_fail" LSKIP="$loc_skips" \
    NOTES_FILE="$notes_file" REPORT="$report_path" RUNSLOG="$RUNS_LOG" \
    TELEM_FILE="$telem_file" UNC_COUNT="$unc_count" \
      python3 - <<'PY'
import json, os
g = os.environ.get
def i(k):
    try: return int(g(k) or 0)
    except Exception: return 0
# ── Telemetry rollup (phases[]/calls[]) computed upstream ──
telem = {}
try:
    with open(g("TELEM_FILE"), encoding="utf-8") as _tf:
        telem = json.load(_tf)
except Exception:
    telem = {}
def fmt_or_unavail(v):
    # Renders JSON null as "unavailable" — NEVER 0.
    return "unavailable" if v is None else str(v)
def fmt_dur_s(v):
    if v is None: return "unavailable"
    try: s = int(v)
    except Exception: return str(v)
    h = s // 3600; m = (s % 3600) // 60; sec = s % 60
    if h: return "%dh %dm %ds" % (h, m, sec)
    if m: return "%dm %ds" % (m, sec)
    return "%ds" % sec
notes = ""
try:
    notes = open(g("NOTES_FILE")).read().strip()
except Exception:
    notes = "- (no notes)"
pct = (i("TDONE")*100//i("TTOTAL")) if i("TTOTAL") else 0
score = g("ES") or ""
verdict = g("EV")
verdict_badge = {"PASS":"✅ PASS","NEEDS_REVISION":"⚠️ NEEDS_REVISION","FAIL":"❌ FAIL"}.get(verdict, verdict)
speed = g("SPEEDUP") or ""
parline = "off (serial)"
if g("PAR") == "on":
    parline = "on — %s worker(s) dispatched / %s completed / %s failed / %s timed out (substrate: %s)" % (
        g("PDISP"), g("PCOMP"), g("PFAIL"), g("PTMO"), g("PSUBS") or "n/a")
    if speed: parline += "; ~%s× parallelization (serial worker-time ÷ longest worker)" % speed

# ── Markdown report ──
lines = []
lines.append("# Run Report — %s" % g("FEAT"))
lines.append("")
lines.append("> Generated by `pro-report.sh` for run `%s`. This is workspace state (gitignored under specs/ when commit_artifacts:false)." % g("RUN"))
lines.append("")
lines.append("## ⏱  Duration")
lines.append("")
lines.append("- **Wall-clock**: %s" % g("DURH"))
lines.append("- **Started**: %s" % g("SI"))
lines.append("- **Finished**: %s" % g("FI"))
lines.append("- **Branch**: %s" % g("BR"))
lines.append("")
lines.append("## 📦  What it produced")
lines.append("")
lines.append("| Metric | Count |")
lines.append("|---|---|")
lines.append("| Files changed | %d |" % i("FC"))
lines.append("| ↳ added / modified / deleted / renamed | %d / %d / %d / %d |" % (i("ADD"), i("MOD"), i("DEL"), i("REN")))
lines.append("| Lines | +%d / -%d |" % (i("INS"), i("DELLINES")))
lines.append("| Commits | %d |" % i("COMMITS"))
lines.append("| Loop iterations | %s%s |" % (g("ITERS"), ("/%s" % g("MAXITER")) if g("MAXITER") else ""))
lines.append("| Tasks completed | %d/%d (%d%%) |" % (i("TDONE"), i("TTOTAL"), pct))
lines.append("| Parallel workers | %s |" % (g("PCOMP") if g("PAR")=="on" else "0"))
lines.append("| Local-model calls | %s (%s failed, %s skips) |" % (g("LCALLS"), g("LFAIL"), g("LSKIP")))
lines.append("")
cl = (g("COMMITLOG") or "").strip()
if cl:
    lines.append("### Commits this run")
    lines.append("")
    for c in cl.splitlines():
        lines.append("- `%s`" % c)
    lines.append("")
# ── 💰 Cost & tokens ──
_tokens = telem.get("tokens") or {}
lines.append("## 💰  Cost & tokens")
lines.append("")
lines.append("| Metric | Value |")
lines.append("|---|---|")
lines.append("| Total cost (USD) | %s |" % fmt_or_unavail(telem.get("total_cost_usd")))
lines.append("| Input tokens | %s |" % fmt_or_unavail(_tokens.get("input") if isinstance(_tokens, dict) else None))
lines.append("| Output tokens | %s |" % fmt_or_unavail(_tokens.get("output") if isinstance(_tokens, dict) else None))
lines.append("| Cache-read tokens | %s |" % fmt_or_unavail(_tokens.get("cache_read") if isinstance(_tokens, dict) else None))
lines.append("| Cache-creation tokens | %s |" % fmt_or_unavail(_tokens.get("cache_creation") if isinstance(_tokens, dict) else None))
lines.append("| Turns | %s |" % fmt_or_unavail(telem.get("turns")))
lines.append("| CLI | %s |" % fmt_or_unavail(telem.get("cli")))
_models = telem.get("models") or {}
if isinstance(_models, dict):
    lines.append("| Generator model | %s |" % fmt_or_unavail(_models.get("generator")))
    lines.append("| Evaluator model | %s |" % fmt_or_unavail(_models.get("evaluator")))
lines.append("| Session id | %s |" % fmt_or_unavail(telem.get("session_id")))
lines.append("| Completion state | %s |" % fmt_or_unavail(telem.get("completion_state")))
lines.append("| Telemetry complete | %s |" % ("yes" if telem.get("telemetry_complete") else "no"))
lines.append("")

# ── ⏱ Per-phase wall-clock ──
_pp = telem.get("per_phase_durations_s")
lines.append("## ⏱  Per-phase wall-clock")
lines.append("")
if isinstance(_pp, list) and _pp:
    lines.append("| Phase | Wall-clock |")
    lines.append("|---|---|")
    for row in _pp:
        if isinstance(row, dict):
            lines.append("| %s | %s |" % (fmt_or_unavail(row.get("phase")), fmt_dur_s(row.get("seconds"))))
else:
    lines.append("_No phase markers recorded for this run._")
lines.append("")

lines.append("## 🧪  How it went")
lines.append("")
lines.append("- **Evaluation**: %s%s" % (verdict_badge, (" (score %s)" % score) if score else ""))
lines.append("- **Parallelism**: %s" % parline)
lines.append("- **Task completion**: %d/%d (%d%%)" % (i("TDONE"), i("TTOTAL"), pct))
lines.append("- **Human interventions**: %s · **rework**: %s · **circuit-breaker trips**: %s" % (
    fmt_or_unavail(telem.get("human_interventions")),
    fmt_or_unavail(telem.get("rework_count")),
    fmt_or_unavail(telem.get("circuit_breaker_trips"))))
lines.append("- **Uncertainty flags**: %s (digest: `uncertainties.md` in the feature dir)" % (g("UNC_COUNT") or "0"))
lines.append("")
# ── 🚦 Capability skips + auto-decisions (FR-005/FR-014: zero silent skips) ──
_skips = telem.get("skips") or []
_decisions = telem.get("decisions") or []
lines.append("## 🚦  Capability skips")
lines.append("")
if _skips:
    lines.append("| When | Capability | Phase | Reason | Detail |")
    lines.append("|---|---|---|---|---|")
    for s in _skips:
        if isinstance(s, dict):
            lines.append("| %s | %s | %s | %s | %s |" % (
                s.get("ts", "?"), s.get("capability", "?"), s.get("phase") or "—",
                s.get("reason_class", "?"), (s.get("detail") or "").replace("|", "\\|")))
else:
    lines.append("_none — every enabled capability ran._")
lines.append("")
lines.append("## 🤖  Decisions (auto-applied)")
lines.append("")
if _decisions:
    lines.append("| When | Gate | Action | Detail |")
    lines.append("|---|---|---|---|")
    for s in _decisions:
        if isinstance(s, dict):
            lines.append("| %s | %s | %s | %s |" % (
                s.get("ts", "?"), s.get("gate", "?"), s.get("action", "?"),
                (s.get("detail") or "").replace("|", "\\|")))
else:
    lines.append("_none — no unattended defaults were applied._")
lines.append("")
lines.append("## 🔧  Where to improve")
lines.append("")
lines.append(notes)
lines.append("")
lines.append("---")
lines.append("_Cross-run trends:_ `pro-report.sh aggregate` · _per-feature status:_ `/pro.status %s`" % g("FEAT"))
lines.append("")
with open(g("REPORT"), "w", encoding="utf-8") as fh:
    fh.write("\n".join(lines))

# ── Machine summary line (one per finished run) ──
summary = {
  "run_id": g("RUN"), "feature": g("FEAT"), "finished_at": g("FI"),
  "duration_s": (int(g("DURS")) if (g("DURS") or "").isdigit() else None),
  "files_changed": i("FC"), "lines_added": i("INS"), "lines_deleted": i("DELLINES"),
  "commits": i("COMMITS"), "iterations": (int(g("ITERS")) if (g("ITERS") or "").isdigit() else 0),
  "tasks_done": i("TDONE"), "tasks_total": i("TTOTAL"),
  "eval_verdict": verdict, "eval_score": (int(score) if score.isdigit() else None),
  "parallel": g("PAR"), "parallel_workers": i("PCOMP"), "parallel_fail": i("PFAIL"),
  "speedup": (float(speed) if speed else None),
  "local_calls": i("LCALLS"), "local_fail": i("LFAIL"),
}
# ── Additive v1.23 telemetry keys (existing keys above keep identical names/order) ──
_tk = telem.get("tokens") or {}
if not isinstance(_tk, dict): _tk = {}
summary["total_cost_usd"]        = telem.get("total_cost_usd")
summary["input_tokens"]          = _tk.get("input")
summary["output_tokens"]         = _tk.get("output")
summary["cache_read_tokens"]     = _tk.get("cache_read")
summary["cache_creation_tokens"] = _tk.get("cache_creation")
summary["turns"]                 = telem.get("turns")
summary["session_id"]            = telem.get("session_id")
summary["session_ids"]           = telem.get("session_ids") or []
summary["per_phase_durations_s"] = telem.get("per_phase_durations_s") or []
summary["human_interventions"]   = telem.get("human_interventions")
summary["rework_count"]          = telem.get("rework_count")
summary["circuit_breaker_trips"] = telem.get("circuit_breaker_trips")
summary["cli"]                   = telem.get("cli")
summary["models"]                = telem.get("models")
summary["completion_state"]      = telem.get("completion_state")
summary["telemetry_complete"]    = bool(telem.get("telemetry_complete"))
summary["skip_count"]            = len(telem.get("skips") or [])
summary["decision_count"]        = len(telem.get("decisions") or [])
summary["uncertainty_count"]     = int(g("UNC_COUNT") or 0)
os.makedirs(os.path.dirname(g("RUNSLOG")), exist_ok=True)
# flock-guarded append: concurrent finishers must never interleave lines.
import fcntl
with open(g("RUNSLOG"), "a", encoding="utf-8") as fh:
    fcntl.flock(fh.fileno(), fcntl.LOCK_EX)
    fh.write(json.dumps(summary) + "\n")
print(g("REPORT"))
PY
  fi
  rm -f "$notes_file" 2>/dev/null
  rm -f "$telem_file" 2>/dev/null

  # ── Close the run record: open → finished (flock CAS; legacy manifests tolerated) ──
  if [[ -n "$run_id" && -f "$manifest" ]] && have_py; then
    FI_TS="$(fanout_now_iso)" python3 - "$manifest" <<'PY' || fanout_warn "finish: could not set status=finished for $run_id"
import fcntl, json, os, sys
mf = sys.argv[1]
with open(mf, "r+", encoding="utf-8") as fh:
    fcntl.flock(fh.fileno(), fcntl.LOCK_EX)
    try:
        d = json.load(fh)
    except Exception:
        sys.exit(1)
    # finish always wins: "interrupted" is a sweep's presumption of death; a run
    # that actually finishes proves it wrong and overrides it. Only "finished"
    # itself is terminal.
    if d.get("status") in (None, "open", "interrupted"):
        d["status"] = "finished"
        d["finished_at"] = os.environ.get("FI_TS")
        fh.seek(0)
        fh.truncate()
        json.dump(d, fh, indent=2)
PY
  fi

  fanout_ok "run-report: wrote $report_path  (duration $dur_h · ${files_changed} files · ${commits} commits · ${tasks_done}/${tasks_total} tasks · eval ${eval_verdict}${eval_score:+ $eval_score})"

  # ── Opt-in OTel export (never aborts; warn-only on failure) ──
  local otel_enabled; otel_enabled="$(report_config_get reporting.otel.enabled "$PRO_CONFIG_PATH")"
  case "$otel_enabled" in
    true|True|TRUE|1|yes|on)
      if [[ -n "$run_id" && -f "$manifest" && -f "$SCRIPT_DIR/pro-otel-emit.sh" ]]; then
        bash "$SCRIPT_DIR/pro-otel-emit.sh" \
          --run-id "$run_id" --manifest "$manifest" --runs-log "$RUNS_LOG" \
          || fanout_warn "run-report: pro-otel-emit.sh exited non-zero — OTel export skipped (not fatal)"
      elif [[ ! -f "$SCRIPT_DIR/pro-otel-emit.sh" ]]; then
        fanout_warn "run-report: reporting.otel.enabled=true but pro-otel-emit.sh is missing — export skipped"
      fi
      ;;
  esac

  if [[ "$to_stdout" -eq 1 && -f "$report_path" ]]; then
    echo; cat "$report_path"
  fi
}

# =============================================================================
# aggregate
# =============================================================================
cmd_aggregate() {
  local last=10 as_json=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --last) last="${2:-10}"; shift 2 ;;
      --json) as_json=1; shift ;;
      *) shift ;;
    esac
  done
  if [[ ! -f "$RUNS_LOG" ]]; then
    fanout_warn "no runs logged yet ($RUNS_LOG) — finish at least one /pro.go run first."
    return 0
  fi
  have_py || { fanout_err "python3 required for aggregate"; return 1; }
  LAST="$last" ASJSON="$as_json" RUNSDIR="$RUNS_DIR" python3 - "$RUNS_LOG" <<'PY'
import json, sys
rows = []
for ln in open(sys.argv[1], encoding="utf-8"):
    ln = ln.strip()
    if not ln: continue
    try: rows.append(json.loads(ln))
    except Exception: pass
import os
last = int(os.environ.get("LAST", "10"))
rows = rows[-last:]
if os.environ.get("ASJSON") == "1":
    print(json.dumps(rows, indent=2)); sys.exit(0)
if not rows:
    print("No runs to aggregate."); sys.exit(0)

def avg(xs):
    xs = [x for x in xs if isinstance(x, (int, float))]
    return sum(xs)/len(xs) if xs else None
def fmtdur(s):
    if s is None: return "?"
    s=int(s); h=s//3600; m=(s%3600)//60; sec=s%60
    return ("%dh %dm" % (h,m)) if h else (("%dm %ds" % (m,sec)) if m else "%ds" % sec)

print("═══ SpecKit Pro — cross-run trends (last %d) ═══\n" % len(rows))
print("%-26s %-8s %-7s %-6s %-6s %-9s %-6s" % ("run","dur","files","iters","tasks","eval","par"))
for r in rows:
    tasks = "%s/%s" % (r.get("tasks_done","?"), r.get("tasks_total","?"))
    ev = r.get("eval_verdict","?")
    if r.get("eval_score") is not None: ev += "·%s" % r["eval_score"]
    print("%-26s %-8s %-7s %-6s %-6s %-9s %-6s" % (
        (r.get("run_id","?"))[:26], fmtdur(r.get("duration_s")),
        r.get("files_changed","?"), r.get("iterations","?"),
        tasks, ev, r.get("parallel","?")))

scores = [r["eval_score"] for r in rows if r.get("eval_score") is not None]
durs   = [r["duration_s"] for r in rows if r.get("duration_s") is not None]
iters  = [r["iterations"] for r in rows if isinstance(r.get("iterations"), int)]
passes = sum(1 for r in rows if r.get("eval_verdict") == "PASS")
par_on = sum(1 for r in rows if r.get("parallel") == "on")
spds   = [r["speedup"] for r in rows if isinstance(r.get("speedup"), (int,float))]
lfails = sum(r.get("local_fail",0) or 0 for r in rows)

# Interrupted-run count (orphan sweep closures; manifests never reach runs.jsonl)
import glob
_interrupted = 0
for _p in glob.glob(os.path.join(os.environ.get("RUNSDIR", ""), "*.json")):
    try:
        if json.load(open(_p, encoding="utf-8")).get("status") == "interrupted":
            _interrupted += 1
    except Exception:
        pass

print("\n── Averages ──")
print("  avg duration : %s" % fmtdur(avg(durs)))
print("  avg eval     : %s" % ("%.1f" % avg(scores) if scores else "n/a"))
print("  avg iters    : %s" % ("%.1f" % avg(iters) if iters else "n/a"))
print("  PASS rate    : %d/%d" % (passes, len(rows)))
print("  parallel used: %d/%d runs" % (par_on, len(rows)))
if _interrupted:
    print("  interrupted  : %d run(s) closed by the orphan sweep (never finished)" % _interrupted)
if spds: print("  avg speedup  : %.2fx" % avg(spds))

# Trend on eval score (first half vs second half).
def half_avg(xs):
    if len(xs) < 4: return None, None
    h=len(xs)//2; return avg(xs[:h]), avg(xs[h:])
a,b = half_avg(scores)
recs = []
if a is not None and b is not None:
    if b > a + 2: recs.append("Eval scores are trending UP (%.1f → %.1f) — current changes are working; keep going." % (a,b))
    elif b < a - 2: recs.append("Eval scores are trending DOWN (%.1f → %.1f) — recent changes regressed quality; review the last improvements." % (a,b))
if passes < len(rows): recs.append("%d/%d runs did not PASS — inspect the failing sprint evaluations for the recurring weak criterion." % (len(rows)-passes, len(rows)))
if par_on < len(rows): recs.append("Only %d/%d runs used parallelism — enable parallel.phases.implement for multi-task work-units." % (par_on, len(rows)))
if spds and avg(spds) < 1.3: recs.append("Average parallel speedup is low (%.2fx) — work-units may be too coupled to fan out; revisit task granularity." % avg(spds))
if iters and avg(iters) > 12: recs.append("Runs average %.1f iterations — consider larger work-units or richer task-packets to converge faster." % avg(iters))
if lfails > 0: recs.append("%d local-model failures across runs — check Ollama health / model sizing." % lfails)

# ── Eval-score trend + regression flag (reporting.regression.* knobs) ──
def _num_env(name, default):
    try: return float(os.environ.get(name, "") or default)
    except Exception: return float(default)
REGR_WINDOW       = int(_num_env("REGR_WINDOW", 5))
REGR_MARGIN       = _num_env("REGR_MARGIN", 10)
REGR_PASS_THRESH  = _num_env("REGR_PASS_THRESHOLD", 70)
REGR_MIN_PRIOR    = int(_num_env("REGR_MIN_PRIOR", 3))

# scored runs in chronological order (rows already trimmed to --last)
scored_seq = [r["eval_score"] for r in rows if r.get("eval_score") is not None]
print("\n── Eval-score trend ──")
regression_flagged = False
if len(scored_seq) < 1:
    print("  trend: no scored runs yet")
elif len(scored_seq) - 1 < REGR_MIN_PRIOR:
    print("  trend: insufficient baseline (%d scored run%s)" % (
        len(scored_seq), "" if len(scored_seq) == 1 else "s"))
    if len(scored_seq) > 1:
        print("  %s" % " → ".join(str(int(s)) if float(s).is_integer() else str(s) for s in scored_seq))
else:
    latest = scored_seq[-1]
    prior = scored_seq[:-1]
    trailing_window = prior[-REGR_WINDOW:]
    trailing = sum(trailing_window) / len(trailing_window)
    regression_flagged = (latest < (trailing - REGR_MARGIN)) or (latest < REGR_PASS_THRESH)
    seq_str = " → ".join(str(int(s)) if float(s).is_integer() else str(s) for s in scored_seq)
    if regression_flagged:
        seq_str += " ⚠ REGRESSION"
    print("  %s" % seq_str)
    print("  latest %s vs trailing mean %.1f (window %d, margin %g, floor %g)" % (
        (str(int(latest)) if float(latest).is_integer() else str(latest)),
        trailing, REGR_WINDOW, REGR_MARGIN, REGR_PASS_THRESH))
if regression_flagged:
    recs.append("⚠ Eval-score regression — latest score dropped below the trailing baseline (mean−%g) or the %g floor; review the most recent changes before promoting." % (REGR_MARGIN, REGR_PASS_THRESH))

print("\n── Recommendations ──")
if not recs: recs.append("Healthy across the board. No systemic changes recommended.")
for r in recs: print("  • " + r)
print("\nFeed durable learnings into .knowledge/improvements.md so the NEXT /pro.go reads them at Phase 0.")
PY
}

# =============================================================================
# event — thin telemetry logger for the in-harness loop, plus structured
#         skip/decision events (FR-004/FR-014):
#   event skip     <run_id|-> <capability> <phase> <reason_class> [detail]
#   event decision <run_id|-> <gate> <action> [detail]
# Empty/"-" run-id falls back to .current; with neither, the event spools to
# pending-skips.jsonl (adopted by the next start) — never lost, never fatal.
# =============================================================================
_event_record() { # _event_record <kind> <run_id> <json-payload-via-EV_JSON>
  local kind="$1" run_id="$2"
  [[ -z "$run_id" || "$run_id" == "-" ]] && run_id="$(cat "$RUNS_DIR/.current" 2>/dev/null)"
  local manifest="$RUNS_DIR/$run_id.json"
  mkdir -p "$RUNS_DIR" 2>/dev/null
  have_py || { fanout_warn "event $kind: python3 unavailable — dropped"; return 0; }
  if [[ -n "$run_id" && -f "$manifest" ]]; then
    KIND="$kind" python3 - "$manifest" <<'PY' || fanout_warn "event: manifest append failed"
import fcntl, json, os, sys
mf = sys.argv[1]
entry = json.loads(os.environ["EV_JSON"])
key = "decisions" if os.environ.get("KIND") == "decision" else "skips"
with open(mf, "r+", encoding="utf-8") as fh:
    fcntl.flock(fh.fileno(), fcntl.LOCK_EX)
    try:
        d = json.load(fh)
    except Exception:
        d = {}
    if not isinstance(d.get(key), list):
        d[key] = []
    d[key].append(entry)
    fh.seek(0)
    fh.truncate()
    json.dump(d, fh, indent=2)
PY
  else
    # Pre-run (or unknown-run) event: spool; the next start adopts it.
    python3 - "$RUNS_DIR/pending-skips.jsonl" <<'PY' || fanout_warn "event: spool append failed"
import fcntl, json, os, sys
entry = json.loads(os.environ["EV_JSON"])
with open(sys.argv[1], "a", encoding="utf-8") as fh:
    fcntl.flock(fh.fileno(), fcntl.LOCK_EX)
    fh.write(json.dumps(entry) + "\n")
PY
  fi
}

cmd_event() {
  local event="${1:-}"
  case "$event" in
    skip)
      local run_id="${2:-}" cap="${3:-}" phase="${4:-}" rclass="${5:-}" detail="${6:-}"
      [[ -z "$cap" || -z "$rclass" ]] && { fanout_err "usage: pro-report.sh event skip <run_id|-> <capability> <phase> <reason_class> [detail]"; return 2; }
      case "$rclass" in
        disabled-by-config|environment-unavailable|error) ;;
        *) fanout_warn "event skip: unknown reason_class '$rclass' (recording anyway)" ;;
      esac
      EV_JSON="$(TS="$(fanout_now_iso)" CAP="$cap" PH="$phase" RC="$rclass" DT="$detail" python3 -c '
import json, os
print(json.dumps({"ts": os.environ["TS"], "capability": os.environ["CAP"],
  "phase": os.environ.get("PH") or None, "reason_class": os.environ["RC"],
  "detail": (os.environ.get("DT") or "")[:200]}))')" || return 0
      export EV_JSON
      _event_record skip "$run_id"
      unset EV_JSON
      fanout_log "skip event: $cap ($rclass)${detail:+ — $detail}"
      ;;
    decision)
      local run_id="${2:-}" gate="${3:-}" action="${4:-}" detail="${5:-}"
      [[ -z "$gate" || -z "$action" ]] && { fanout_err "usage: pro-report.sh event decision <run_id|-> <gate> <action> [detail]"; return 2; }
      EV_JSON="$(TS="$(fanout_now_iso)" GA="$gate" AC="$action" DT="$detail" python3 -c '
import json, os
print(json.dumps({"ts": os.environ["TS"], "gate": os.environ["GA"],
  "action": os.environ["AC"], "detail": (os.environ.get("DT") or "")[:200]}))')" || return 0
      export EV_JSON
      _event_record decision "$run_id"
      unset EV_JSON
      fanout_log "decision event: $gate → $action"
      ;;
    *)
      local run_id="${2:-}" portion="${3:-}" substrate="${4:-in-harness}" dur="${5:-}" err="${6:-}"
      [[ -z "$event" || -z "$run_id" ]] && { fanout_err "usage: pro-report.sh event <event> <run_id> <portion> <substrate> [dur_ms] [err]"; return 2; }
      fanout_telemetry "$FANOUT_METRICS" "$event" "$run_id" "$portion" "$substrate" "$dur" "$err"
      ;;
  esac
}

# =============================================================================
# dispatch
# =============================================================================
usage() {
  sed -n '4,42p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}
case "${1:-}" in
  start)     shift; cmd_start "$@" ;;
  phase)     shift; cmd_phase "$@" ;;
  call)      shift; cmd_call "$@" ;;
  finish)    shift; cmd_finish "$@" ;;
  aggregate) shift; cmd_aggregate "$@" ;;
  event)     shift; cmd_event "$@" ;;
  -h|--help|help|"") usage ;;
  *) fanout_err "unknown subcommand: $1"; usage; exit 2 ;;
esac
