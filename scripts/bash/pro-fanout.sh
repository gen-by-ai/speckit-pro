#!/usr/bin/env bash
# =============================================================================
# pro-fanout.sh — shared fan-out engine entrypoint for the CLI/terminal substrate.
#
# Reads a portions.json (from partition.py), dispatches one worker per portion
# across a bounded slot pool (pro-fanout-common.sh), and collects each worker's
# Partial Result JSON into <out-dir>/<portion_id>.json. The merge + report
# assembly is done by the caller (pro-scan.sh → scan_report.py).
#
# Each worker is a headless agent-CLI process (per-CLI map reused from
# pro-orchestrate.sh:249-308). For testing without burning real LLM calls, set
#   SPECKIT_FANOUT_WORKER_CMD="<cmd>"
# and it is invoked as: <cmd> <portion_id> <files_file> <out_file>
#
# Usage:
#   pro-fanout.sh --portions <portions.json> --work-dir <dir> --out-dir <dir>
#                 [--substrate cli|sequential] [--workers N] [--timeout S]
#                 [--cli <bin>] [--model <m>] [--metrics-file <f>] [--run-id <id>]
#                 [--worker-prompt <file>] [--agent-def <file>]
#
# Never aborts the parent on a worker failure — a missing result file is recorded
# by scan_report.py's Coverage Ledger as `failed`.
# =============================================================================
set -u

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
# shellcheck source=lib/pro-fanout-common.sh
source "$SCRIPT_DIR/lib/pro-fanout-common.sh"

PORTIONS="" WORK_DIR="" OUT_DIR="" SUBSTRATE="cli" WORKERS="0" TIMEOUT="300"
CLI_BIN="" MODEL="" METRICS_FILE="" RUN_ID="scan-run"
WORKER_PROMPT="templates/scan/worker.prompt.md" AGENT_DEF=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --portions)      PORTIONS="$2"; shift 2 ;;
    --work-dir)      WORK_DIR="$2"; shift 2 ;;
    --out-dir)       OUT_DIR="$2"; shift 2 ;;
    --substrate)     SUBSTRATE="$2"; shift 2 ;;
    --workers)       WORKERS="$2"; shift 2 ;;
    --timeout)       TIMEOUT="$2"; shift 2 ;;
    --cli)           CLI_BIN="$2"; shift 2 ;;
    --model)         MODEL="$2"; shift 2 ;;
    --metrics-file)  METRICS_FILE="$2"; shift 2 ;;
    --run-id)        RUN_ID="$2"; shift 2 ;;
    --worker-prompt) WORKER_PROMPT="$2"; shift 2 ;;
    --agent-def)     AGENT_DEF="$2"; shift 2 ;;
    -h|--help)       sed -n '2,28p' "$0"; exit 0 ;;
    *)               fanout_err "unknown arg: $1"; exit 1 ;;
  esac
done

[[ -f "$PORTIONS" ]] || { fanout_err "portions file not found: $PORTIONS"; exit 1; }
[[ -n "$OUT_DIR" ]]  || { fanout_err "--out-dir required"; exit 1; }
[[ -n "$WORK_DIR" ]] || WORK_DIR="$(dirname "$OUT_DIR")"
mkdir -p "$OUT_DIR" "$WORK_DIR/portions"

# ── Expand portions.json → per-portion file lists; echo the portion-id list ───
PIDS="$(python3 - "$PORTIONS" "$WORK_DIR/portions" <<'PY'
import json, os, sys
doc = json.load(open(sys.argv[1])); outdir = sys.argv[2]
portions = doc.get("portions", doc if isinstance(doc, list) else [])
ids = []
for p in portions:
    pid = p["portion_id"]; ids.append(pid)
    with open(os.path.join(outdir, pid + ".files"), "w") as fh:
        fh.write("\n".join(p.get("files", [])) + "\n")
print(" ".join(ids))
PY
)"
[[ -z "$PIDS" ]] && { fanout_warn "no portions to dispatch"; exit 0; }

# ── Resolve worker command ────────────────────────────────────────────────────
# Default agent def: same cascade as pro-orchestrate.sh resolve_agent_file —
# the old `.github/agents/` default ships in NEITHER the dev repo NOR installed
# consumers (.extensionignore excludes .github/), and the bare `agents/`
# fallback only exists in the dev repo. First readable candidate wins.
if [[ -z "$AGENT_DEF" ]]; then
  _fanout_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
  for _cand in "${SPECKIT_PRO_AGENTS_DIR:-}/speckit.pro.scan-worker.agent.md" \
               "$SCRIPT_DIR/../../agents/speckit.pro.scan-worker.agent.md" \
               "$_fanout_root/.specify/extensions/pro/agents/speckit.pro.scan-worker.agent.md" \
               "$_fanout_root/agents/speckit.pro.scan-worker.agent.md" \
               "$_fanout_root/.github/agents/speckit.pro.scan-worker.agent.md"; do
    if [[ -r "$_cand" ]]; then AGENT_DEF="$_cand"; break; fi
  done
  [[ -z "$AGENT_DEF" ]] && AGENT_DEF="agents/speckit.pro.scan-worker.agent.md"  # last resort (recorded as failed by the ledger)
fi
[[ -z "$CLI_BIN" ]] && CLI_BIN="$(fanout_detect_substrate cli "" >/dev/null 2>&1; for b in copilot claude gemini codex; do command -v "$b" >/dev/null 2>&1 && { echo "$b"; break; }; done)"

# fanout_dispatch_one <portion_id> — runs one worker, writes <out_dir>/<pid>.json
fanout_dispatch_one() {
  local pid="$1"
  local files_file="$WORK_DIR/portions/$pid.files"
  local out="$OUT_DIR/$pid.json"

  # Test seam: a caller-supplied worker command (used by the test harness).
  if [[ -n "${SPECKIT_FANOUT_WORKER_CMD:-}" ]]; then
    "$SPECKIT_FANOUT_WORKER_CMD" "$pid" "$files_file" "$out"
    return $?
  fi

  local files; files="$(tr '\n' ',' < "$files_file")"
  local prompt; prompt="$(cat "$WORKER_PROMPT" 2>/dev/null)
PORTION_ID=$pid
FILES=$files
out=$out
Write ONLY the JSON Partial Result to stdout."
  local output exit_rc=0
  case "$CLI_BIN" in
    copilot) output="$("$CLI_BIN" agent ${MODEL:+--model "$MODEL"} "$AGENT_DEF" "$prompt" 2>/dev/null)" || exit_rc=$? ;;
    claude)  output="$("$CLI_BIN" ${MODEL:+--model "$MODEL"} --print --system-prompt "$AGENT_DEF" "$prompt" 2>/dev/null)" || exit_rc=$? ;;
    gemini)  output="$("$CLI_BIN" run ${MODEL:+--model "$MODEL"} "$AGENT_DEF" "$prompt" 2>/dev/null)" || exit_rc=$? ;;
    "")      fanout_err "no agent CLI available for cli substrate"; return 1 ;;
    *)       output="$("$CLI_BIN" "$AGENT_DEF" "$prompt" 2>/dev/null)" || exit_rc=$? ;;
  esac
  [[ "$exit_rc" -ne 0 ]] && return "$exit_rc"
  # Extract the JSON object from the worker's stdout and write it.
  printf '%s' "$output" | python3 -c '
import json,re,sys
s=sys.stdin.read()
m=re.search(r"\{.*\}", s, re.S)
if not m: sys.exit(2)
obj=json.loads(m.group(0))
open(sys.argv[1],"w").write(json.dumps(obj))
' "$out" || return 3
  return 0
}

# ── Run ───────────────────────────────────────────────────────────────────────
# shellcheck disable=SC2086
set -- $PIDS
N="$#"
POOL_RC=0
if [[ "$SUBSTRATE" == "sequential" || "$WORKERS" -le 1 ]]; then
  fanout_log "sequential: $N portion(s)"
  FANOUT_OK_COUNT=0; FANOUT_FAIL_COUNT=0; FANOUT_TIMEOUT_COUNT=0
  for pid in "$@"; do
    fanout_telemetry "$METRICS_FILE" dispatch "$RUN_ID" "$pid" sequential
    if fanout_dispatch_one "$pid"; then
      FANOUT_OK_COUNT=$(( FANOUT_OK_COUNT + 1 ))
      fanout_telemetry "$METRICS_FILE" complete "$RUN_ID" "$pid" sequential
    else
      FANOUT_FAIL_COUNT=$(( FANOUT_FAIL_COUNT + 1 ))
      fanout_telemetry "$METRICS_FILE" fail "$RUN_ID" "$pid" sequential "" "worker error"
    fi
  done
else
  fanout_run_pool "$WORKERS" "$TIMEOUT" "$METRICS_FILE" "$RUN_ID" "$SUBSTRATE" 3 "$@"
  POOL_RC=$?
fi

fanout_ok "dispatch done — ok=$FANOUT_OK_COUNT fail=$FANOUT_FAIL_COUNT timeout=$FANOUT_TIMEOUT_COUNT"
exit "$POOL_RC"
